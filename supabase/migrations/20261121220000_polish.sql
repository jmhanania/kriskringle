-- Polish pass: keep-awake ping, account self-service (rename, leave family, delete account),
-- super-admin tools (assign organiser, full backup export), draw-notification recipients,
-- drop the unused phone column, and indexes suggested by the advisor.

-- ---------- Keep-awake ----------
-- Called daily by a GitHub Action so the free project never pauses for inactivity.
create function public.ping() returns integer
language sql stable security definer set search_path = '' as $$
  select coalesce((select 1 from public.families limit 1), 1)
$$;

-- ---------- Indexes ----------
create index families_created_by on public.families (created_by);
create index kk_assignments_giver on public.kk_assignments (giver_id);
create index kk_exclusions_giver on public.kk_exclusions (giver_id);

-- ---------- Drop phone (no longer collected) ----------
drop function public.admin_save_person(uuid, text, text, text, uuid);
alter table public.people drop column phone;

create function public.admin_save_person(
  p_family uuid, p_name text, p_email text default null, p_id uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_family); v_id uuid; v_email text := lower(nullif(trim(p_email), ''));
begin
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'invalid_email'; end if;
  if p_id is null then
    if (select count(*) from public.people where family_id = p_family) >= 200 then raise exception 'family_full'; end if;
    insert into public.people (family_id, name, email) values (p_family, trim(p_name), v_email)
    returning id into v_id;
  else
    -- Changing the email of someone who already has an account would hand their spot to another account.
    if exists (select 1 from public.people where id = p_id and family_id = p_family and user_id is not null
               and coalesce(lower(email), '') <> coalesce(v_email, '')) then
      raise exception 'email_locked';
    end if;
    update public.people set name = trim(p_name), email = v_email
    where id = p_id and family_id = p_family returning id into v_id;
    if v_id is null then raise exception 'not_found'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.admin_get_state(p_family uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_family);
begin
  return jsonb_build_object(
    'admin_id', v_admin,
    'family', (select name from public.families where id = p_family),
    'people', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', id, 'name', name, 'email', email, 'is_admin', is_admin,
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

-- ---------- Account self-service ----------
-- Removes a person from their family, resetting any draw they were part of.
-- Deletes the whole family if they were its only member.
create function private.remove_person(p_person uuid) returns void
language plpgsql set search_path = '' as $$
declare v_family uuid := private.family_of(p_person); v_event uuid;
begin
  if (select count(*) from public.people where family_id = v_family) = 1 then
    delete from public.families where id = v_family;
    return;
  end if;
  for v_event in
    select distinct event_id from public.kk_assignments where giver_id = p_person or receiver_id = p_person
  loop
    perform private.reset_draw(v_event);
  end loop;
  delete from public.people where id = p_person;
end $$;

-- True when this person is the family's only organiser and other people remain.
create function private.is_last_organiser(p_person uuid) returns boolean
language sql stable set search_path = '' as $$
  select p.is_admin
     and not exists (select 1 from public.people o where o.family_id = p.family_id and o.id <> p.id and o.is_admin)
     and exists (select 1 from public.people o where o.family_id = p.family_id and o.id <> p.id)
  from public.people p where p.id = p_person
$$;

revoke all on all functions in schema private from public, anon, authenticated;

create function public.update_my_name(p_family uuid, p_name text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_me uuid := private.member(p_family);
begin
  update public.people set name = trim(p_name) where id = v_me;
end $$;

create function public.leave_family(p_family uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_me uuid := private.member(p_family);
begin
  if private.is_last_organiser(v_me) then raise exception 'last_organiser'; end if;
  perform private.remove_person(v_me);
end $$;

create function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.uid(); v_person uuid;
begin
  if exists (select 1 from public.people where user_id = v_uid and private.is_last_organiser(id)) then
    raise exception 'last_organiser';
  end if;
  for v_person in select id from public.people where user_id = v_uid loop
    perform private.remove_person(v_person);
  end loop;
  delete from auth.users where id = v_uid;
end $$;

-- ---------- Draw notification ----------
-- Who to email after a draw (used by the notify-draw edge function with the organiser's session).
create function public.admin_draw_recipients(p_family uuid, p_event uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.admin(p_family);
  perform private.check_event(p_event, p_family);
  return jsonb_build_object(
    'family', (select name from public.families where id = p_family),
    'event', (select jsonb_build_object('name', name, 'exchange_date', exchange_date, 'budget_cents', budget_cents, 'status', status)
              from public.kk_events where id = p_event),
    'recipients', (select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'email', p.email, 'has_account', p.user_id is not null)), '[]'::jsonb)
                   from public.kk_participants kp join public.people p on p.id = kp.person_id
                   where kp.event_id = p_event and p.email is not null)
  );
end $$;

-- ---------- Super admin ----------
create or replace function public.super_get_state() returns jsonb
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
                   from public.people p where p.family_id = f.id and p.is_admin),
        -- Members with accounts, so a family left without an organiser can be given one.
        'candidates', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) order by p.name), '[]'::jsonb)
                       from public.people p where p.family_id = f.id and p.user_id is not null and not p.is_admin)
      ) order by f.created_at), '[]'::jsonb) from public.families f)
  );
end $$;

create function public.super_set_organiser(p_family uuid, p_person uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_super();
  update public.people set is_admin = true where id = p_person and family_id = p_family and user_id is not null;
  if not found then raise exception 'not_found'; end if;
end $$;

-- Everything needed to restore the site by hand. Includes draws and wish lists, so the file must be kept private.
create function public.super_export() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_super();
  return jsonb_build_object(
    'exported_at', now(),
    'families', (select coalesce(jsonb_agg(to_jsonb(f) - 'created_by'), '[]'::jsonb) from public.families f),
    'people', (select coalesce(jsonb_agg(to_jsonb(p) - 'user_id'), '[]'::jsonb) from public.people p),
    'wishlist_items', (select coalesce(jsonb_agg(to_jsonb(w)), '[]'::jsonb) from public.wishlist_items w),
    'kk_events', (select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb) from public.kk_events e),
    'kk_participants', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.kk_participants x),
    'kk_exclusions', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.kk_exclusions x),
    'kk_assignments', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.kk_assignments x),
    'super_admins', (select coalesce(jsonb_agg(email), '[]'::jsonb) from private.super_admins)
  );
end $$;

-- ---------- Permissions ----------
revoke all on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
grant execute on function public.ping() to anon;
