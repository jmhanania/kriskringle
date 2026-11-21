-- Organiser state now includes each exchange's house rules.
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
        'reveal_mode', e.reveal_mode, 'revealed', private.is_revealed(e), 'reminders', e.reminders, 'rules', e.rules,
        'participants', (select coalesce(jsonb_agg(person_id), '[]'::jsonb) from public.kk_participants where event_id = e.id),
        'exclusions', (select coalesce(jsonb_agg(jsonb_build_object('giver', giver_id, 'receiver', receiver_id)), '[]'::jsonb)
                       from public.kk_exclusions where event_id = e.id),
        'assignments', (select coalesce(jsonb_agg(jsonb_build_object('giver', giver_id, 'receiver', receiver_id)), '[]'::jsonb)
                        from public.kk_assignments where event_id = e.id)
      ) order by e.exchange_date desc nulls last, e.created_at desc), '[]'::jsonb)
      from public.kk_events e where e.family_id = p_family)
  );
end $$;
