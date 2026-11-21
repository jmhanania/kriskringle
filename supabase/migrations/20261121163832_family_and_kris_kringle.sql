-- Hanania Family database: shared family tables + Kris Kringle.
-- Security model: RLS is on with no policies, and anon/authenticated have no table grants,
-- so the API cannot touch tables directly. All access goes through the SECURITY DEFINER
-- functions below, each of which first checks a person's secret link code (access_code).

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create extension if not exists pgcrypto with schema extensions;

-- ---------- Family (shared) ----------
create table public.people (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 80),
  email text check (email is null or length(email) <= 200),
  phone text check (phone is null or length(phone) <= 40),
  access_code text not null unique default encode(extensions.gen_random_bytes(12), 'hex'),
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index people_name_unique on public.people (lower(trim(name)));

create table public.wishlist_items (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.people(id) on delete cascade,
  title text not null check (length(trim(title)) between 1 and 200),
  url text check (url is null or (length(url) <= 1000 and url ~* '^https?://')),
  notes text check (notes is null or length(notes) <= 1000),
  price_cents integer check (price_cents is null or price_cents between 0 and 100000000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index wishlist_items_person on public.wishlist_items (person_id);

-- ---------- Kris Kringle ----------
create table public.kk_events (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 100),
  exchange_date date,
  budget_cents integer check (budget_cents is null or budget_cents >= 0),
  status text not null default 'draft' check (status in ('draft', 'drawn')),
  created_at timestamptz not null default now()
);

create table public.kk_participants (
  event_id uuid not null references public.kk_events(id) on delete cascade,
  person_id uuid not null references public.people(id) on delete cascade,
  primary key (event_id, person_id)
);

create table public.kk_exclusions (
  event_id uuid not null references public.kk_events(id) on delete cascade,
  giver_id uuid not null references public.people(id) on delete cascade,
  receiver_id uuid not null references public.people(id) on delete cascade,
  primary key (event_id, giver_id, receiver_id),
  check (giver_id <> receiver_id)
);

create table public.kk_assignments (
  event_id uuid not null references public.kk_events(id) on delete cascade,
  giver_id uuid not null references public.people(id) on delete cascade,
  receiver_id uuid not null references public.people(id) on delete cascade,
  primary key (event_id, giver_id),
  unique (event_id, receiver_id),
  check (giver_id <> receiver_id)
);
create index kk_assignments_receiver on public.kk_assignments (receiver_id);
create index kk_exclusions_receiver on public.kk_exclusions (receiver_id);
create index kk_participants_person on public.kk_participants (person_id);

alter table public.people enable row level security;
alter table public.wishlist_items enable row level security;
alter table public.kk_events enable row level security;
alter table public.kk_participants enable row level security;
alter table public.kk_exclusions enable row level security;
alter table public.kk_assignments enable row level security;
revoke all on all tables in schema public from anon, authenticated;

-- ---------- Private helpers ----------
create function private.me(p_code text) returns uuid
language plpgsql stable set search_path = '' as $$
declare v uuid;
begin
  select id into v from public.people where access_code = p_code;
  if v is null then raise exception 'invalid_code' using errcode = '28000'; end if;
  return v;
end $$;

create function private.admin(p_code text) returns uuid
language plpgsql stable set search_path = '' as $$
declare v uuid;
begin
  select id into v from public.people where access_code = p_code and is_admin;
  if v is null then raise exception 'not_admin' using errcode = '42501'; end if;
  return v;
end $$;

create function private.wishlist_json(p_person uuid) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'title', title, 'url', url, 'notes', notes, 'price_cents', price_cents
  ) order by created_at), '[]'::jsonb)
  from public.wishlist_items where person_id = p_person
$$;

create function private.reset_draw(p_event uuid) returns void
language sql set search_path = '' as $$
  delete from public.kk_assignments where event_id = p_event;
  update public.kk_events set status = 'draft' where id = p_event;
$$;

revoke all on all functions in schema private from public, anon, authenticated;

-- ---------- Personal page ----------
create function public.get_my_page(p_code text) returns jsonb
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
    'me', (select jsonb_build_object('id', id, 'name', name, 'is_admin', is_admin) from public.people where id = v_me),
    'wishlist', private.wishlist_json(v_me),
    'event', case when v_event.id is null then null else jsonb_build_object(
      'name', v_event.name, 'exchange_date', v_event.exchange_date, 'budget_cents', v_event.budget_cents) end,
    'recipient', case when v_recv is null then null else jsonb_build_object(
      'name', (select name from public.people where id = v_recv),
      'wishlist', private.wishlist_json(v_recv)) end
  );
end $$;

create function public.save_wish(
  p_code text, p_title text, p_url text default null, p_notes text default null,
  p_price_cents integer default null, p_id uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_me uuid := private.me(p_code); v_id uuid;
begin
  if p_id is null then
    if (select count(*) from public.wishlist_items where person_id = v_me) >= 50 then
      raise exception 'wishlist_full';
    end if;
    insert into public.wishlist_items (person_id, title, url, notes, price_cents)
    values (v_me, trim(p_title), nullif(trim(p_url), ''), nullif(trim(p_notes), ''), p_price_cents)
    returning id into v_id;
  else
    update public.wishlist_items
    set title = trim(p_title), url = nullif(trim(p_url), ''), notes = nullif(trim(p_notes), ''),
        price_cents = p_price_cents, updated_at = now()
    where id = p_id and person_id = v_me
    returning id into v_id;
    if v_id is null then raise exception 'not_found'; end if;
  end if;
  return v_id;
end $$;

create function public.delete_wish(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_me uuid := private.me(p_code);
begin
  delete from public.wishlist_items where id = p_id and person_id = v_me;
end $$;

-- ---------- Admin ----------
create function public.admin_get_state(p_code text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code);
begin
  return jsonb_build_object(
    'admin_id', v_admin,
    'people', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', id, 'name', name, 'email', email, 'phone', phone,
        'access_code', access_code, 'is_admin', is_admin,
        'wish_count', (select count(*) from public.wishlist_items w where w.person_id = p.id)
      ) order by lower(name)), '[]'::jsonb) from public.people p),
    'events', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', e.id, 'name', e.name, 'exchange_date', e.exchange_date,
        'budget_cents', e.budget_cents, 'status', e.status, 'created_at', e.created_at,
        'participants', (select coalesce(jsonb_agg(person_id), '[]'::jsonb) from public.kk_participants where event_id = e.id),
        'exclusions', (select coalesce(jsonb_agg(jsonb_build_object('giver', giver_id, 'receiver', receiver_id)), '[]'::jsonb)
                       from public.kk_exclusions where event_id = e.id),
        'assignments', (select coalesce(jsonb_agg(jsonb_build_object('giver', giver_id, 'receiver', receiver_id)), '[]'::jsonb)
                        from public.kk_assignments where event_id = e.id)
      ) order by e.exchange_date desc nulls last, e.created_at desc), '[]'::jsonb) from public.kk_events e)
  );
end $$;

create function public.admin_save_person(
  p_code text, p_name text, p_email text default null, p_phone text default null, p_id uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code); v_id uuid;
begin
  if p_id is null then
    insert into public.people (name, email, phone)
    values (trim(p_name), nullif(trim(p_email), ''), nullif(trim(p_phone), ''))
    returning id into v_id;
  else
    update public.people set name = trim(p_name), email = nullif(trim(p_email), ''), phone = nullif(trim(p_phone), '')
    where id = p_id returning id into v_id;
    if v_id is null then raise exception 'not_found'; end if;
  end if;
  return v_id;
end $$;

create function public.admin_delete_person(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code); v_event uuid;
begin
  if p_id = v_admin then raise exception 'cannot_delete_self'; end if;
  for v_event in
    select distinct event_id from public.kk_assignments where giver_id = p_id or receiver_id = p_id
  loop
    perform private.reset_draw(v_event);
  end loop;
  delete from public.people where id = p_id;
end $$;

create function public.admin_regenerate_code(p_code text, p_id uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code); v_new text;
begin
  update public.people set access_code = encode(extensions.gen_random_bytes(12), 'hex')
  where id = p_id returning access_code into v_new;
  if v_new is null then raise exception 'not_found'; end if;
  return v_new;
end $$;

create function public.admin_save_event(
  p_code text, p_name text, p_exchange_date date default null, p_budget_cents integer default null, p_id uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code); v_id uuid;
begin
  if p_id is null then
    insert into public.kk_events (name, exchange_date, budget_cents)
    values (trim(p_name), p_exchange_date, p_budget_cents) returning id into v_id;
  else
    update public.kk_events set name = trim(p_name), exchange_date = p_exchange_date, budget_cents = p_budget_cents
    where id = p_id returning id into v_id;
    if v_id is null then raise exception 'not_found'; end if;
  end if;
  return v_id;
end $$;

create function public.admin_delete_event(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code);
begin
  delete from public.kk_events where id = p_id;
end $$;

-- Replaces participants + exclusions for an event. Any existing draw is cleared.
create function public.admin_set_event_setup(
  p_code text, p_event uuid, p_person_ids uuid[], p_exclusions jsonb
) returns void
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code);
begin
  if not exists (select 1 from public.kk_events where id = p_event) then raise exception 'not_found'; end if;
  perform private.reset_draw(p_event);
  delete from public.kk_exclusions where event_id = p_event;
  delete from public.kk_participants where event_id = p_event;
  insert into public.kk_participants (event_id, person_id)
  select distinct p_event, pid from unnest(coalesce(p_person_ids, '{}')) pid;
  insert into public.kk_exclusions (event_id, giver_id, receiver_id)
  select distinct p_event, (x->>'giver')::uuid, (x->>'receiver')::uuid
  from jsonb_array_elements(coalesce(p_exclusions, '[]'::jsonb)) x
  where (x->>'giver')::uuid in (select person_id from public.kk_participants where event_id = p_event)
    and (x->>'receiver')::uuid in (select person_id from public.kk_participants where event_id = p_event)
    and (x->>'giver') <> (x->>'receiver');
end $$;

-- Saves a draw after checking it is a valid permutation that respects every exclusion.
create function public.admin_save_draw(p_code text, p_event uuid, p_pairs jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_admin uuid := private.admin(p_code);
  v_n integer;
  v_ok boolean;
begin
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

create function public.admin_clear_draw(p_code text, p_event uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_code);
begin
  perform private.reset_draw(p_event);
end $$;

revoke all on all functions in schema public from public;
grant execute on all functions in schema public to anon, authenticated;
