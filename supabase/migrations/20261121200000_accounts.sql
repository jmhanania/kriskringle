-- Switch from secret link codes to real accounts (Supabase Auth, email one-time codes).
-- People are linked to an auth user by email: when someone signs in, any family member
-- rows with their (verified) email are claimed. Every function now takes the family id
-- and checks the signed-in user's membership/role in that family. Only signed-in users
-- can call anything; the anon role has no access at all.

-- ---------- Schema ----------
alter table public.people add column user_id uuid references auth.users(id) on delete set null;
create unique index people_family_user on public.people (family_id, user_id) where user_id is not null;
create index people_user on public.people (user_id);
create index people_email on public.people (lower(email));

-- One account can't be two people in the same family, and emails are unique within a family.
create unique index people_family_email on public.people (family_id, lower(email)) where email is not null;

alter table public.families add column created_by uuid references auth.users(id) on delete set null;

-- Super admins are identified by account email (works before they first sign in).
create table private.super_admins (email text primary key);
revoke all on private.super_admins from public, anon, authenticated;

-- Link codes are gone.
drop function public.get_my_page(text);
drop function public.save_wish(text, text, text, text, integer, uuid);
drop function public.delete_wish(text, uuid);
drop function public.admin_get_state(text);
drop function public.admin_rename_family(text, text);
drop function public.admin_save_person(text, text, text, text, uuid);
drop function public.admin_delete_person(text, uuid);
drop function public.admin_regenerate_code(text, uuid);
drop function public.admin_save_event(text, text, date, integer, uuid);
drop function public.admin_delete_event(text, uuid);
drop function public.admin_set_event_setup(text, uuid, uuid[], jsonb);
drop function public.admin_save_draw(text, uuid, jsonb);
drop function public.admin_clear_draw(text, uuid);
drop function public.admin_set_admin(text, uuid, boolean);
drop function public.create_family(text, text, text, text);
drop function public.super_get_state(text);
drop function public.super_set_invite(text, text);
drop function public.super_regenerate_admin_link(text, uuid);
drop function public.super_delete_family(text, uuid);
drop function private.me(text);
drop function private.admin(text);
drop function private.super(text);
drop table private.settings;
alter table public.people drop column access_code;
alter table public.people drop column is_super_admin;

-- ---------- Helpers ----------
create function private.uid() returns uuid
language plpgsql stable set search_path = '' as $$
declare v uuid := auth.uid();
begin
  if v is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  return v;
end $$;

-- The signed-in user's verified email (lower-case), or null.
create function private.verified_email() returns text
language sql stable set search_path = '' as $$
  select lower(email) from auth.users where id = auth.uid() and email_confirmed_at is not null
$$;

create function private.member(p_family uuid) returns uuid
language plpgsql stable set search_path = '' as $$
declare v uuid;
begin
  select id into v from public.people where family_id = p_family and user_id = private.uid();
  if v is null then raise exception 'not_member' using errcode = '42501'; end if;
  return v;
end $$;

create function private.admin(p_family uuid) returns uuid
language plpgsql stable set search_path = '' as $$
declare v uuid;
begin
  select id into v from public.people where family_id = p_family and user_id = private.uid() and is_admin;
  if v is null then raise exception 'not_admin' using errcode = '42501'; end if;
  return v;
end $$;

create function private.is_super() returns boolean
language sql stable set search_path = '' as $$
  select exists (select 1 from private.super_admins where email = private.verified_email())
$$;

create function private.require_super() returns void
language plpgsql stable set search_path = '' as $$
begin
  if not private.is_super() then raise exception 'not_super_admin' using errcode = '42501'; end if;
end $$;

-- Claims any unclaimed family-member rows that carry the signed-in user's verified email.
create function private.claim() returns void
language plpgsql set search_path = '' as $$
declare v_email text := private.verified_email();
begin
  if v_email is null then return; end if;
  update public.people p set user_id = auth.uid()
  where p.user_id is null and lower(p.email) = v_email
    and not exists (select 1 from public.people q where q.family_id = p.family_id and q.user_id = auth.uid());
end $$;

revoke all on all functions in schema private from public, anon, authenticated;

-- ---------- Account ----------
-- Called after sign-in: links pending invitations and lists the user's families.
create function public.my_account() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.uid();
  perform private.claim();
  return jsonb_build_object(
    'email', (select email from auth.users where id = auth.uid()),
    'is_super_admin', private.is_super(),
    'families', (select coalesce(jsonb_agg(jsonb_build_object(
        'family_id', f.id, 'family', f.name, 'person_id', p.id, 'name', p.name, 'is_admin', p.is_admin
      ) order by f.name), '[]'::jsonb)
      from public.people p join public.families f on f.id = p.family_id
      where p.user_id = auth.uid())
  );
end $$;

create function public.create_family(p_family_name text, p_my_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.uid(); v_family uuid;
begin
  if (select count(*) from public.families where created_by = v_uid) >= 5 then
    raise exception 'too_many_families';
  end if;
  if (select count(*) from public.families where created_at > now() - interval '1 hour') >= 30 then
    raise exception 'too_many_signups';
  end if;
  insert into public.families (name, created_by) values (trim(p_family_name), v_uid) returning id into v_family;
  insert into public.people (family_id, name, email, user_id, is_admin)
  values (v_family, trim(p_my_name), private.verified_email(), v_uid, true);
  return v_family;
end $$;

-- ---------- Personal page ----------
create function public.get_my_page(p_family uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_me uuid := private.member(p_family);
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
    'family', (select name from public.families where id = p_family),
    'me', (select jsonb_build_object('id', id, 'name', name, 'is_admin', is_admin) from public.people where id = v_me),
    'wishlist', private.wishlist_json(v_me),
    'event', case when v_event.id is null then null else jsonb_build_object(
      'name', v_event.name, 'exchange_date', v_event.exchange_date, 'budget_cents', v_event.budget_cents) end,
    'recipient', case when v_recv is null then null else jsonb_build_object(
      'name', (select name from public.people where id = v_recv),
      'wishlist', private.wishlist_json(v_recv)) end
  );
end $$;

-- Saves a wish for yourself, or (admins only) for a family member who has no account.
create function public.save_wish(
  p_family uuid, p_title text, p_url text default null, p_notes text default null,
  p_price_cents integer default null, p_id uuid default null, p_for_person uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_owner uuid; v_id uuid;
begin
  if p_for_person is null then
    v_owner := private.member(p_family);
  else
    perform private.admin(p_family);
    select id into v_owner from public.people where id = p_for_person and family_id = p_family and user_id is null;
    if v_owner is null then raise exception 'not_managed_member'; end if;
  end if;

  if p_id is null then
    if (select count(*) from public.wishlist_items where person_id = v_owner) >= 50 then
      raise exception 'wishlist_full';
    end if;
    insert into public.wishlist_items (person_id, title, url, notes, price_cents)
    values (v_owner, trim(p_title), nullif(trim(p_url), ''), nullif(trim(p_notes), ''), p_price_cents)
    returning id into v_id;
  else
    update public.wishlist_items
    set title = trim(p_title), url = nullif(trim(p_url), ''), notes = nullif(trim(p_notes), ''),
        price_cents = p_price_cents, updated_at = now()
    where id = p_id and person_id = v_owner
    returning id into v_id;
    if v_id is null then raise exception 'not_found'; end if;
  end if;
  return v_id;
end $$;

create function public.delete_wish(p_family uuid, p_id uuid, p_for_person uuid default null) returns void
language plpgsql security definer set search_path = '' as $$
declare v_owner uuid;
begin
  if p_for_person is null then
    v_owner := private.member(p_family);
  else
    perform private.admin(p_family);
    select id into v_owner from public.people where id = p_for_person and family_id = p_family and user_id is null;
    if v_owner is null then raise exception 'not_managed_member'; end if;
  end if;
  delete from public.wishlist_items where id = p_id and person_id = v_owner;
end $$;

-- Wish list of a member without an account, for the admin to manage.
create function public.admin_get_wishlist(p_family uuid, p_person uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.admin(p_family);
  if not exists (select 1 from public.people where id = p_person and family_id = p_family and user_id is null) then
    raise exception 'not_managed_member';
  end if;
  return private.wishlist_json(p_person);
end $$;

-- ---------- Family admin ----------
create function public.admin_get_state(p_family uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_family);
begin
  return jsonb_build_object(
    'admin_id', v_admin,
    'family', (select name from public.families where id = p_family),
    'people', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', id, 'name', name, 'email', email, 'phone', phone, 'is_admin', is_admin,
        'has_account', user_id is not null,
        'wish_count', (select count(*) from public.wishlist_items w where w.person_id = p.id)
      ) order by lower(name)), '[]'::jsonb) from public.people p where p.family_id = p_family),
    'events', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', e.id, 'name', e.name, 'exchange_date', e.exchange_date,
        'budget_cents', e.budget_cents, 'status', e.status, 'created_at', e.created_at,
        'participants', (select coalesce(jsonb_agg(person_id), '[]'::jsonb) from public.kk_participants where event_id = e.id),
        'exclusions', (select coalesce(jsonb_agg(jsonb_build_object('giver', giver_id, 'receiver', receiver_id)), '[]'::jsonb)
                       from public.kk_exclusions where event_id = e.id),
        'assignments', (select coalesce(jsonb_agg(jsonb_build_object('giver', giver_id, 'receiver', receiver_id)), '[]'::jsonb)
                        from public.kk_assignments where event_id = e.id)
      ) order by e.exchange_date desc nulls last, e.created_at desc), '[]'::jsonb)
      from public.kk_events e where e.family_id = p_family)
  );
end $$;

create function public.admin_rename_family(p_family uuid, p_name text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.admin(p_family);
  update public.families set name = trim(p_name) where id = p_family;
end $$;

create function public.admin_save_person(
  p_family uuid, p_name text, p_email text default null, p_phone text default null, p_id uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_family); v_id uuid; v_email text := lower(nullif(trim(p_email), ''));
begin
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'invalid_email'; end if;
  if p_id is null then
    if (select count(*) from public.people where family_id = p_family) >= 200 then raise exception 'family_full'; end if;
    insert into public.people (family_id, name, email, phone)
    values (p_family, trim(p_name), v_email, nullif(trim(p_phone), ''))
    returning id into v_id;
  else
    -- Changing the email of someone who already has an account would hand their spot to another account.
    if exists (select 1 from public.people where id = p_id and family_id = p_family and user_id is not null
               and coalesce(lower(email), '') <> coalesce(v_email, '')) then
      raise exception 'email_locked';
    end if;
    update public.people set name = trim(p_name), email = v_email, phone = nullif(trim(p_phone), '')
    where id = p_id and family_id = p_family returning id into v_id;
    if v_id is null then raise exception 'not_found'; end if;
  end if;
  return v_id;
end $$;

create function public.admin_delete_person(p_family uuid, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_family); v_event uuid;
begin
  perform private.check_person(p_id, p_family);
  if p_id = v_admin then raise exception 'cannot_delete_self'; end if;
  for v_event in
    select distinct event_id from public.kk_assignments where giver_id = p_id or receiver_id = p_id
  loop
    perform private.reset_draw(v_event);
  end loop;
  delete from public.people where id = p_id;
end $$;

create function public.admin_set_admin(p_family uuid, p_id uuid, p_is_admin boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_family);
begin
  perform private.check_person(p_id, p_family);
  if p_id = v_admin and not p_is_admin then raise exception 'cannot_demote_self'; end if;
  update public.people set is_admin = p_is_admin where id = p_id;
end $$;

create function public.admin_save_event(
  p_family uuid, p_name text, p_exchange_date date default null, p_budget_cents integer default null, p_id uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  perform private.admin(p_family);
  if p_id is null then
    if (select count(*) from public.kk_events where family_id = p_family) >= 100 then raise exception 'too_many_events'; end if;
    insert into public.kk_events (family_id, name, exchange_date, budget_cents)
    values (p_family, trim(p_name), p_exchange_date, p_budget_cents) returning id into v_id;
  else
    update public.kk_events set name = trim(p_name), exchange_date = p_exchange_date, budget_cents = p_budget_cents
    where id = p_id and family_id = p_family returning id into v_id;
    if v_id is null then raise exception 'not_found'; end if;
  end if;
  return v_id;
end $$;

create function public.admin_delete_event(p_family uuid, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.admin(p_family);
  perform private.check_event(p_id, p_family);
  delete from public.kk_events where id = p_id;
end $$;

create function public.admin_set_event_setup(
  p_family uuid, p_event uuid, p_person_ids uuid[], p_exclusions jsonb
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.admin(p_family);
  perform private.check_event(p_event, p_family);
  perform private.reset_draw(p_event);
  delete from public.kk_exclusions where event_id = p_event;
  delete from public.kk_participants where event_id = p_event;
  insert into public.kk_participants (event_id, person_id)
  select distinct p_event, p.id from public.people p
  where p.family_id = p_family and p.id = any(coalesce(p_person_ids, '{}'));
  insert into public.kk_exclusions (event_id, giver_id, receiver_id)
  select distinct p_event, (x->>'giver')::uuid, (x->>'receiver')::uuid
  from jsonb_array_elements(coalesce(p_exclusions, '[]'::jsonb)) x
  where (x->>'giver')::uuid in (select person_id from public.kk_participants where event_id = p_event)
    and (x->>'receiver')::uuid in (select person_id from public.kk_participants where event_id = p_event)
    and (x->>'giver') <> (x->>'receiver');
end $$;

create function public.admin_save_draw(p_family uuid, p_event uuid, p_pairs jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare v_n integer; v_ok boolean;
begin
  perform private.admin(p_family);
  perform private.check_event(p_event, p_family);
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

create function public.admin_clear_draw(p_family uuid, p_event uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.admin(p_family);
  perform private.check_event(p_event, p_family);
  perform private.reset_draw(p_event);
end $$;

-- ---------- Super admin ----------
create function public.super_get_state() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_super();
  return jsonb_build_object(
    'families', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', f.id, 'name', f.name, 'created_at', f.created_at,
        'people_count', (select count(*) from public.people p where p.family_id = f.id),
        'account_count', (select count(*) from public.people p where p.family_id = f.id and p.user_id is not null),
        'event_count', (select count(*) from public.kk_events e where e.family_id = f.id),
        'mine', exists (select 1 from public.people p where p.family_id = f.id and p.user_id = auth.uid()),
        'admins', (select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'email', p.email) order by p.created_at), '[]'::jsonb)
                   from public.people p where p.family_id = f.id and p.is_admin)
      ) order by f.created_at), '[]'::jsonb) from public.families f)
  );
end $$;

create function public.super_delete_family(p_family uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_super();
  delete from public.families where id = p_family;
end $$;

-- ---------- Permissions: signed-in users only ----------
revoke all on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
