-- Multi-family support: every person and exchange belongs to a family, and every function
-- is scoped to the caller's family (derived from their link code). New families sign up
-- with an invite code stored in private.settings.

create table public.families (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 60),
  created_at timestamptz not null default now()
);
alter table public.families enable row level security;
revoke all on public.families from anon, authenticated;

create table private.settings (key text primary key, value text not null);
insert into private.settings (key, value)
values ('invite_code', 'KK-' || upper(encode(extensions.gen_random_bytes(4), 'hex')));

-- Existing data becomes the Hanania family.
insert into public.families (name) values ('Hanania');

alter table public.people add column family_id uuid references public.families(id) on delete cascade;
update public.people set family_id = (select id from public.families where name = 'Hanania');
alter table public.people alter column family_id set not null;

alter table public.kk_events add column family_id uuid references public.families(id) on delete cascade;
update public.kk_events set family_id = (select id from public.families where name = 'Hanania');
alter table public.kk_events alter column family_id set not null;

drop index public.people_name_unique;
create unique index people_name_unique on public.people (family_id, lower(trim(name)));
create index kk_events_family on public.kk_events (family_id);

-- ---------- Helpers ----------
create function private.family_of(p_person uuid) returns uuid
language sql stable set search_path = '' as $$
  select family_id from public.people where id = p_person
$$;

-- Raises unless the event belongs to the given family.
create function private.check_event(p_event uuid, p_family uuid) returns void
language plpgsql stable set search_path = '' as $$
begin
  if not exists (select 1 from public.kk_events where id = p_event and family_id = p_family) then
    raise exception 'not_found';
  end if;
end $$;

create function private.check_person(p_person uuid, p_family uuid) returns void
language plpgsql stable set search_path = '' as $$
begin
  if not exists (select 1 from public.people where id = p_person and family_id = p_family) then
    raise exception 'not_found';
  end if;
end $$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke all on all tables in schema private from public, anon, authenticated;

-- ---------- Sign-up ----------
create function public.create_family(
  p_invite text, p_family_name text, p_admin_name text, p_email text default null
) returns text
language plpgsql security definer set search_path = '' as $$
declare v_family uuid; v_code text;
begin
  if p_invite is null or upper(trim(p_invite)) <> (select value from private.settings where key = 'invite_code') then
    raise exception 'invalid_invite';
  end if;
  if (select count(*) from public.families where created_at > now() - interval '1 hour') >= 20 then
    raise exception 'too_many_signups';
  end if;
  insert into public.families (name) values (trim(p_family_name)) returning id into v_family;
  insert into public.people (family_id, name, email, is_admin)
  values (v_family, trim(p_admin_name), nullif(trim(p_email), ''), true)
  returning access_code into v_code;
  return v_code;
end $$;

-- ---------- Admin (all scoped to the admin's family) ----------
create or replace function public.admin_get_state(p_code text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code); v_family uuid := private.family_of(v_admin);
begin
  return jsonb_build_object(
    'admin_id', v_admin,
    'family', (select name from public.families where id = v_family),
    'people', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', id, 'name', name, 'email', email, 'phone', phone,
        'access_code', access_code, 'is_admin', is_admin,
        'wish_count', (select count(*) from public.wishlist_items w where w.person_id = p.id)
      ) order by lower(name)), '[]'::jsonb) from public.people p where p.family_id = v_family),
    'events', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', e.id, 'name', e.name, 'exchange_date', e.exchange_date,
        'budget_cents', e.budget_cents, 'status', e.status, 'created_at', e.created_at,
        'participants', (select coalesce(jsonb_agg(person_id), '[]'::jsonb) from public.kk_participants where event_id = e.id),
        'exclusions', (select coalesce(jsonb_agg(jsonb_build_object('giver', giver_id, 'receiver', receiver_id)), '[]'::jsonb)
                       from public.kk_exclusions where event_id = e.id),
        'assignments', (select coalesce(jsonb_agg(jsonb_build_object('giver', giver_id, 'receiver', receiver_id)), '[]'::jsonb)
                        from public.kk_assignments where event_id = e.id)
      ) order by e.exchange_date desc nulls last, e.created_at desc), '[]'::jsonb)
      from public.kk_events e where e.family_id = v_family)
  );
end $$;

create function public.admin_rename_family(p_code text, p_name text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code);
begin
  update public.families set name = trim(p_name) where id = private.family_of(v_admin);
end $$;

create or replace function public.admin_save_person(
  p_code text, p_name text, p_email text default null, p_phone text default null, p_id uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code); v_family uuid := private.family_of(v_admin); v_id uuid;
begin
  if p_id is null then
    if (select count(*) from public.people where family_id = v_family) >= 200 then raise exception 'family_full'; end if;
    insert into public.people (family_id, name, email, phone)
    values (v_family, trim(p_name), nullif(trim(p_email), ''), nullif(trim(p_phone), ''))
    returning id into v_id;
  else
    update public.people set name = trim(p_name), email = nullif(trim(p_email), ''), phone = nullif(trim(p_phone), '')
    where id = p_id and family_id = v_family returning id into v_id;
    if v_id is null then raise exception 'not_found'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.admin_delete_person(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code); v_event uuid;
begin
  perform private.check_person(p_id, private.family_of(v_admin));
  if p_id = v_admin then raise exception 'cannot_delete_self'; end if;
  for v_event in
    select distinct event_id from public.kk_assignments where giver_id = p_id or receiver_id = p_id
  loop
    perform private.reset_draw(v_event);
  end loop;
  delete from public.people where id = p_id;
end $$;

create or replace function public.admin_regenerate_code(p_code text, p_id uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code); v_new text;
begin
  perform private.check_person(p_id, private.family_of(v_admin));
  update public.people set access_code = encode(extensions.gen_random_bytes(12), 'hex')
  where id = p_id returning access_code into v_new;
  return v_new;
end $$;

create or replace function public.admin_save_event(
  p_code text, p_name text, p_exchange_date date default null, p_budget_cents integer default null, p_id uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code); v_family uuid := private.family_of(v_admin); v_id uuid;
begin
  if p_id is null then
    if (select count(*) from public.kk_events where family_id = v_family) >= 100 then raise exception 'too_many_events'; end if;
    insert into public.kk_events (family_id, name, exchange_date, budget_cents)
    values (v_family, trim(p_name), p_exchange_date, p_budget_cents) returning id into v_id;
  else
    update public.kk_events set name = trim(p_name), exchange_date = p_exchange_date, budget_cents = p_budget_cents
    where id = p_id and family_id = v_family returning id into v_id;
    if v_id is null then raise exception 'not_found'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.admin_delete_event(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code);
begin
  perform private.check_event(p_id, private.family_of(v_admin));
  delete from public.kk_events where id = p_id;
end $$;

create or replace function public.admin_set_event_setup(
  p_code text, p_event uuid, p_person_ids uuid[], p_exclusions jsonb
) returns void
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code); v_family uuid := private.family_of(v_admin);
begin
  perform private.check_event(p_event, v_family);
  perform private.reset_draw(p_event);
  delete from public.kk_exclusions where event_id = p_event;
  delete from public.kk_participants where event_id = p_event;
  -- Only people from this family can be added.
  insert into public.kk_participants (event_id, person_id)
  select distinct p_event, p.id from public.people p
  where p.family_id = v_family and p.id = any(coalesce(p_person_ids, '{}'));
  insert into public.kk_exclusions (event_id, giver_id, receiver_id)
  select distinct p_event, (x->>'giver')::uuid, (x->>'receiver')::uuid
  from jsonb_array_elements(coalesce(p_exclusions, '[]'::jsonb)) x
  where (x->>'giver')::uuid in (select person_id from public.kk_participants where event_id = p_event)
    and (x->>'receiver')::uuid in (select person_id from public.kk_participants where event_id = p_event)
    and (x->>'giver') <> (x->>'receiver');
end $$;

create or replace function public.admin_save_draw(p_code text, p_event uuid, p_pairs jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_admin uuid := private.admin(p_code);
  v_n integer;
  v_ok boolean;
begin
  perform private.check_event(p_event, private.family_of(v_admin));
  select count(*) into v_n from public.kk_participants where event_id = p_event;
  if v_n < 2 then raise exception 'not_enough_participants'; end if;

  with pairs as (
    select (x->>'giver')::uuid g, (x->>'receiver')::uuid r from jsonb_array_elements(p_pairs) x
  ), parts as (
    select person_id from public.kk_participants where event_id = p_event
  )
  select count(*) = v_n
     and count(distinct g) = v_n
     and count(distinct r) = v_n
     and bool_and(g <> r)
     and bool_and(g in (select person_id from parts))
     and bool_and(r in (select person_id from parts))
     and not exists (
       select 1 from pairs p2 join public.kk_exclusions x
         on x.event_id = p_event and x.giver_id = p2.g and x.receiver_id = p2.r)
  into v_ok from pairs;

  if not coalesce(v_ok, false) then raise exception 'invalid_draw'; end if;

  delete from public.kk_assignments where event_id = p_event;
  insert into public.kk_assignments (event_id, giver_id, receiver_id)
  select p_event, (x->>'giver')::uuid, (x->>'receiver')::uuid from jsonb_array_elements(p_pairs) x;
  update public.kk_events set status = 'drawn' where id = p_event;
end $$;

create or replace function public.admin_clear_draw(p_code text, p_event uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code);
begin
  perform private.check_event(p_event, private.family_of(v_admin));
  perform private.reset_draw(p_event);
end $$;

revoke all on all functions in schema public from public;
grant execute on all functions in schema public to anon, authenticated;

-- ---------- Super admin (site owner) ----------
-- Sees every family's name, counts and admins (to help with lost links), but not draws or wish lists.
alter table public.people add column is_super_admin boolean not null default false;
update public.people set is_super_admin = true
where is_admin and family_id = (select id from public.families where name = 'Hanania');

create function private.super(p_code text) returns uuid
language plpgsql stable set search_path = '' as $$
declare v uuid;
begin
  select id into v from public.people where access_code = p_code and is_super_admin;
  if v is null then raise exception 'not_super_admin' using errcode = '42501'; end if;
  return v;
end $$;
revoke all on function private.super(text) from public, anon, authenticated;

create function public.super_get_state(p_code text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_super uuid := private.super(p_code);
begin
  return jsonb_build_object(
    'my_family_id', private.family_of(v_super),
    'invite_code', (select value from private.settings where key = 'invite_code'),
    'families', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', f.id, 'name', f.name, 'created_at', f.created_at,
        'people_count', (select count(*) from public.people p where p.family_id = f.id),
        'event_count', (select count(*) from public.kk_events e where e.family_id = f.id),
        'admins', (select coalesce(jsonb_agg(jsonb_build_object(
            'id', p.id, 'name', p.name, 'email', p.email, 'phone', p.phone, 'access_code', p.access_code
          ) order by p.created_at), '[]'::jsonb) from public.people p where p.family_id = f.id and p.is_admin)
      ) order by f.created_at), '[]'::jsonb) from public.families f)
  );
end $$;

create function public.super_set_invite(p_code text, p_invite text) returns text
language plpgsql security definer set search_path = '' as $$
declare v_super uuid := private.super(p_code); v_new text;
begin
  v_new := upper(trim(coalesce(nullif(trim(p_invite), ''), 'KK-' || encode(extensions.gen_random_bytes(4), 'hex'))));
  if length(v_new) < 6 then raise exception 'invite_too_short'; end if;
  update private.settings set value = v_new where key = 'invite_code';
  return v_new;
end $$;

create function public.super_regenerate_admin_link(p_code text, p_person uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare v_super uuid := private.super(p_code); v_new text;
begin
  update public.people set access_code = encode(extensions.gen_random_bytes(12), 'hex')
  where id = p_person and is_admin returning access_code into v_new;
  if v_new is null then raise exception 'not_found'; end if;
  return v_new;
end $$;

create function public.super_delete_family(p_code text, p_family uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_super uuid := private.super(p_code);
begin
  if p_family = private.family_of(v_super) then raise exception 'cannot_delete_own_family'; end if;
  delete from public.families where id = p_family;
end $$;

-- ---------- Co-admins ----------
create function public.admin_set_admin(p_code text, p_id uuid, p_is_admin boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code);
begin
  perform private.check_person(p_id, private.family_of(v_admin));
  if p_id = v_admin and not p_is_admin then raise exception 'cannot_demote_self'; end if;
  update public.people set is_admin = p_is_admin where id = p_id;
end $$;

-- get_my_page / admin_get_state: also report super-admin status so the pages can link to the super page.
create or replace function public.get_my_page(p_code text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_me uuid := private.me(p_code);
  v_event public.kk_events;
  v_recv uuid;
begin
  select e.* into v_event
  from public.kk_events e
  join public.kk_assignments a on a.event_id = e.id and a.giver_id = v_me
  where e.status = 'drawn'
  order by e.exchange_date desc nulls last, e.created_at desc
  limit 1;

  if v_event.id is not null then
    select receiver_id into v_recv from public.kk_assignments
    where event_id = v_event.id and giver_id = v_me;
  end if;

  return jsonb_build_object(
    'family', (select name from public.families where id = private.family_of(v_me)),
    'me', (select jsonb_build_object('id', id, 'name', name, 'is_admin', is_admin, 'is_super_admin', is_super_admin)
           from public.people where id = v_me),
    'wishlist', private.wishlist_json(v_me),
    'event', case when v_event.id is null then null else jsonb_build_object(
      'name', v_event.name, 'exchange_date', v_event.exchange_date, 'budget_cents', v_event.budget_cents) end,
    'recipient', case when v_recv is null then null else jsonb_build_object(
      'name', (select name from public.people where id = v_recv),
      'wishlist', private.wishlist_json(v_recv)) end
  );
end $$;

revoke all on all functions in schema public from public;
grant execute on all functions in schema public to anon, authenticated;
