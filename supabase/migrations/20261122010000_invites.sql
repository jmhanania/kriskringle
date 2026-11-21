-- Invitation emails: organisers can email family members an invite (sent by the send-invite
-- edge function). invited_at records the last invite, to show status and limit resends.

alter table public.people add column invited_at timestamptz;

-- Called by the send-invite edge function with the organiser's session.
create function public.admin_invite_info(p_family uuid, p_person uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_family); p public.people;
begin
  select * into p from public.people where id = p_person and family_id = p_family;
  if p.id is null then raise exception 'not_found'; end if;
  if p.email is null then raise exception 'no_email'; end if;
  if p.user_id is not null then raise exception 'already_joined'; end if;
  if p.invited_at > now() - interval '1 hour' then raise exception 'invited_recently'; end if;
  update public.people set invited_at = now() where id = p_person;
  return jsonb_build_object(
    'name', p.name, 'email', p.email,
    'family', (select name from public.families where id = p_family),
    'inviter', (select name from public.people where id = v_admin)
  );
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
        'has_account', user_id is not null, 'invited_at', invited_at,
        'wish_count', (select count(*) from public.wishlist_items w where w.person_id = p.id)
      ) order by lower(name)), '[]'::jsonb) from public.people p where p.family_id = p_family),
    'events', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', e.id, 'name', e.name, 'exchange_date', e.exchange_date,
        'budget_cents', e.budget_cents, 'status', e.status, 'created_at', e.created_at,
        'reveal_mode', e.reveal_mode, 'revealed', private.is_revealed(e), 'reminders', e.reminders,
        'participants', (select coalesce(jsonb_agg(person_id), '[]'::jsonb) from public.kk_participants where event_id = e.id),
        'exclusions', (select coalesce(jsonb_agg(jsonb_build_object('giver', giver_id, 'receiver', receiver_id)), '[]'::jsonb)
                       from public.kk_exclusions where event_id = e.id),
        'assignments', (select coalesce(jsonb_agg(jsonb_build_object('giver', giver_id, 'receiver', receiver_id)), '[]'::jsonb)
                        from public.kk_assignments where event_id = e.id)
      ) order by e.exchange_date desc nulls last, e.created_at desc), '[]'::jsonb)
      from public.kk_events e where e.family_id = p_family)
  );
end $$;

revoke all on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
grant execute on function public.ping() to anon;
revoke execute on function public.claim_due_reminders() from authenticated;
grant execute on function public.claim_due_reminders() to service_role;
