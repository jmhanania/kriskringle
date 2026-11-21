-- Mark as bought (private to the giver), reveal day, and automatic reminder emails.

-- ---------- Mark as bought ----------
create table public.kk_bought (
  event_id uuid not null references public.kk_events(id) on delete cascade,
  giver_id uuid not null references public.people(id) on delete cascade,
  item_id uuid not null references public.wishlist_items(id) on delete cascade,
  primary key (event_id, giver_id, item_id)
);
create index kk_bought_item on public.kk_bought (item_id);
create index kk_bought_giver on public.kk_bought (giver_id);
alter table public.kk_bought enable row level security;
revoke all on public.kk_bought from anon, authenticated;

-- ---------- Reveal + reminder settings ----------
alter table public.kk_events
  add column reveal_mode text not null default 'after_date' check (reveal_mode in ('after_date', 'manual')),
  add column revealed boolean not null default false,
  add column reminders boolean not null default true;

create table public.kk_reminders_sent (
  event_id uuid not null references public.kk_events(id) on delete cascade,
  kind text not null check (kind in ('wishlist_week', 'gift_day_soon')),
  sent_at timestamptz not null default now(),
  primary key (event_id, kind)
);
alter table public.kk_reminders_sent enable row level security;
revoke all on public.kk_reminders_sent from anon, authenticated;

-- Dates are judged in Toronto time.
create function private.today() returns date
language sql stable set search_path = '' as $$ select (now() at time zone 'America/Toronto')::date $$;

create function private.is_revealed(e public.kk_events) returns boolean
language sql stable set search_path = '' as $$
  select e.status = 'drawn' and (e.revealed or (e.reveal_mode = 'after_date' and e.exchange_date is not null and private.today() > e.exchange_date))
$$;

-- A draw reset also clears purchases and the reveal.
create or replace function private.reset_draw(p_event uuid) returns void
language sql set search_path = '' as $$
  delete from public.kk_messages where event_id = p_event;
  delete from public.kk_bought where event_id = p_event;
  delete from public.kk_assignments where event_id = p_event;
  update public.kk_events set status = 'draft', revealed = false where id = p_event;
$$;

-- The giftee's wish list as seen by their giver, with the giver's private "bought" ticks.
create function private.wishlist_for_giver(p_event uuid, p_giver uuid, p_receiver uuid) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', w.id, 'title', w.title, 'url', w.url, 'notes', w.notes, 'price_cents', w.price_cents,
    'bought', exists (select 1 from public.kk_bought b where b.event_id = p_event and b.giver_id = p_giver and b.item_id = w.id)
  ) order by w.created_at), '[]'::jsonb)
  from public.wishlist_items w where w.person_id = p_receiver
$$;

revoke all on all functions in schema private from public, anon, authenticated;

create or replace function public.get_my_page(p_family uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_me uuid := private.member(p_family);
  v_give public.kk_assignments := private.pair_as_giver(v_me);
  v_recv public.kk_assignments := private.pair_as_receiver(v_me);
  v_event public.kk_events;
  v_recv_event public.kk_events;
begin
  if v_give.event_id is not null then select * into v_event from public.kk_events where id = v_give.event_id; end if;
  if v_recv.event_id is not null then select * into v_recv_event from public.kk_events where id = v_recv.event_id; end if;

  return jsonb_build_object(
    'family', (select name from public.families where id = p_family),
    'me', (select jsonb_build_object('id', id, 'name', name, 'is_admin', is_admin) from public.people where id = v_me),
    'wishlist', private.wishlist_json(v_me),
    'event', case when v_event.id is null then null else jsonb_build_object(
      'name', v_event.name, 'exchange_date', v_event.exchange_date, 'budget_cents', v_event.budget_cents,
      'revealed', private.is_revealed(v_event)) end,
    'recipient', case when v_give.receiver_id is null then null else jsonb_build_object(
      'name', (select name from public.people where id = v_give.receiver_id),
      'can_message', (select email is not null from public.people where id = v_give.receiver_id),
      'wishlist', private.wishlist_for_giver(v_give.event_id, v_me, v_give.receiver_id),
      'thread', private.thread_json(v_give.event_id, v_me, v_give.receiver_id, true)) end,
    'santa_thread', case when v_recv.giver_id is null then '[]'::jsonb
      else private.thread_json(v_recv.event_id, v_recv.giver_id, v_me, false) end,
    -- Only once the exchange is revealed: who was buying for me.
    'my_santa', case when v_recv_event.id is not null and private.is_revealed(v_recv_event)
      then (select name from public.people where id = v_recv.giver_id) else null end
  );
end $$;

create function public.set_bought(p_family uuid, p_item uuid, p_bought boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_me uuid := private.member(p_family); v_pair public.kk_assignments := private.pair_as_giver(v_me);
begin
  if v_pair.event_id is null
     or not exists (select 1 from public.wishlist_items where id = p_item and person_id = v_pair.receiver_id) then
    raise exception 'not_found';
  end if;
  if p_bought then
    insert into public.kk_bought (event_id, giver_id, item_id) values (v_pair.event_id, v_me, p_item) on conflict do nothing;
  else
    delete from public.kk_bought where event_id = v_pair.event_id and giver_id = v_me and item_id = p_item;
  end if;
end $$;

-- ---------- Organiser: event settings + reveal ----------
drop function public.admin_save_event(uuid, text, date, integer, uuid);
create function public.admin_save_event(
  p_family uuid, p_name text, p_exchange_date date default null, p_budget_cents integer default null,
  p_id uuid default null, p_reveal_mode text default 'after_date', p_reminders boolean default true
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  perform private.admin(p_family);
  if p_reveal_mode not in ('after_date', 'manual') then raise exception 'bad_request'; end if;
  if p_id is null then
    if (select count(*) from public.kk_events where family_id = p_family) >= 100 then raise exception 'too_many_events'; end if;
    insert into public.kk_events (family_id, name, exchange_date, budget_cents, reveal_mode, reminders)
    values (p_family, trim(p_name), p_exchange_date, p_budget_cents, p_reveal_mode, p_reminders) returning id into v_id;
  else
    update public.kk_events set name = trim(p_name), exchange_date = p_exchange_date, budget_cents = p_budget_cents,
      reveal_mode = p_reveal_mode, reminders = p_reminders
    where id = p_id and family_id = p_family returning id into v_id;
    if v_id is null then raise exception 'not_found'; end if;
  end if;
  return v_id;
end $$;

create function public.admin_set_revealed(p_family uuid, p_event uuid, p_revealed boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.admin(p_family);
  perform private.check_event(p_event, p_family);
  update public.kk_events set revealed = p_revealed where id = p_event and status = 'drawn';
  if not found then raise exception 'no_draw_yet'; end if;
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

-- ---------- Reminders ----------
-- Claims and returns every reminder that's due today, marking each as sent so it goes out once.
-- Only the send-reminders edge function (service role) may call this.
create function public.claim_due_reminders() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_out jsonb := '[]'::jsonb; r record; v_today date := private.today();
begin
  for r in
    select e.*, k.kind from public.kk_events e
    cross join (values ('wishlist_week'), ('gift_day_soon')) as k(kind)
    where e.status = 'drawn' and e.reminders and e.exchange_date is not null
      and v_today < e.exchange_date
      and v_today >= e.exchange_date - case k.kind when 'wishlist_week' then 7 else 2 end
      -- Don't send the wish-list nudge if we're already inside the 2-day window.
      and not (k.kind = 'wishlist_week' and v_today >= e.exchange_date - 2)
      and not exists (select 1 from public.kk_reminders_sent s where s.event_id = e.id and s.kind = k.kind)
  loop
    insert into public.kk_reminders_sent (event_id, kind) values (r.id, r.kind) on conflict do nothing;
    if not found then continue; end if;
    v_out := v_out || jsonb_build_object(
      'kind', r.kind,
      'family', (select name from public.families where id = r.family_id),
      'event', jsonb_build_object('name', r.name, 'exchange_date', r.exchange_date, 'budget_cents', r.budget_cents),
      'recipients', (select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'email', p.email, 'has_account', p.user_id is not null)), '[]'::jsonb)
                     from public.kk_participants kp join public.people p on p.id = kp.person_id
                     where kp.event_id = r.id and p.email is not null
                       and (r.kind = 'gift_day_soon' or not exists (select 1 from public.wishlist_items w where w.person_id = p.id))));
  end loop;
  return v_out;
end $$;

revoke all on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
grant execute on function public.ping() to anon;
revoke execute on function public.claim_due_reminders() from authenticated;
grant execute on function public.claim_due_reminders() to service_role;
