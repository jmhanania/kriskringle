-- Anonymous messages between a giver and their giftee ("Ask a question", replies, and nudges).
-- The giftee never learns who the giver is: nothing returned to them identifies the giver.

create table public.kk_messages (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.kk_events(id) on delete cascade,
  giver_id uuid not null references public.people(id) on delete cascade,
  receiver_id uuid not null references public.people(id) on delete cascade,
  from_giver boolean not null,
  kind text not null default 'message' check (kind in ('message', 'nudge')),
  body text not null check (length(trim(body)) between 1 and 500),
  created_at timestamptz not null default now()
);
create index kk_messages_pair on public.kk_messages (event_id, giver_id, receiver_id, created_at);
create index kk_messages_giver on public.kk_messages (giver_id);
create index kk_messages_receiver on public.kk_messages (receiver_id);
alter table public.kk_messages enable row level security;
revoke all on public.kk_messages from anon, authenticated;

-- A draw clears its messages: they belonged to pairs that no longer exist.
create or replace function private.reset_draw(p_event uuid) returns void
language sql set search_path = '' as $$
  delete from public.kk_messages where event_id = p_event;
  delete from public.kk_assignments where event_id = p_event;
  update public.kk_events set status = 'draft' where id = p_event;
$$;

-- The latest drawn assignment in a family where this person is the giver (or receiver).
create function private.pair_as_giver(p_person uuid) returns public.kk_assignments
language sql stable set search_path = '' as $$
  select a.* from public.kk_assignments a join public.kk_events e on e.id = a.event_id
  where a.giver_id = p_person and e.status = 'drawn'
  order by e.exchange_date desc nulls last, e.created_at desc limit 1
$$;
create function private.pair_as_receiver(p_person uuid) returns public.kk_assignments
language sql stable set search_path = '' as $$
  select a.* from public.kk_assignments a join public.kk_events e on e.id = a.event_id
  where a.receiver_id = p_person and e.status = 'drawn'
  order by e.exchange_date desc nulls last, e.created_at desc limit 1
$$;

-- Thread for one pair, from the point of view of `p_viewer_is_giver`. Never includes who the giver is.
create function private.thread_json(p_event uuid, p_giver uuid, p_receiver uuid, p_viewer_is_giver boolean) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'from_me', m.from_giver = p_viewer_is_giver, 'kind', m.kind, 'body', m.body, 'at', m.created_at
  ) order by m.created_at), '[]'::jsonb)
  from public.kk_messages m where m.event_id = p_event and m.giver_id = p_giver and m.receiver_id = p_receiver
$$;

revoke all on all functions in schema private from public, anon, authenticated;

create or replace function public.get_my_page(p_family uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_me uuid := private.member(p_family);
  v_give public.kk_assignments := private.pair_as_giver(v_me);
  v_recv public.kk_assignments := private.pair_as_receiver(v_me);
  v_event public.kk_events;
begin
  if v_give.event_id is not null then
    select * into v_event from public.kk_events where id = v_give.event_id;
  end if;

  return jsonb_build_object(
    'family', (select name from public.families where id = p_family),
    'me', (select jsonb_build_object('id', id, 'name', name, 'is_admin', is_admin) from public.people where id = v_me),
    'wishlist', private.wishlist_json(v_me),
    'event', case when v_event.id is null then null else jsonb_build_object(
      'name', v_event.name, 'exchange_date', v_event.exchange_date, 'budget_cents', v_event.budget_cents) end,
    'recipient', case when v_give.receiver_id is null then null else jsonb_build_object(
      'name', (select name from public.people where id = v_give.receiver_id),
      'can_message', (select email is not null from public.people where id = v_give.receiver_id),
      'wishlist', private.wishlist_json(v_give.receiver_id),
      'thread', private.thread_json(v_give.event_id, v_me, v_give.receiver_id, true)) end,
    -- Messages from whoever is buying for me (anonymous).
    'santa_thread', case when v_recv.giver_id is null then '[]'::jsonb
      else private.thread_json(v_recv.event_id, v_recv.giver_id, v_me, false) end
  );
end $$;

-- p_to: 'giftee' (I'm the giver, writing to the person I'm buying for)
--       'santa'  (I'm the giftee, replying to whoever is buying for me)
create function public.send_message(p_family uuid, p_to text, p_body text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_me uuid := private.member(p_family); v_pair public.kk_assignments; v_id uuid;
begin
  if p_to = 'giftee' then v_pair := private.pair_as_giver(v_me);
  elsif p_to = 'santa' then v_pair := private.pair_as_receiver(v_me);
  else raise exception 'bad_request'; end if;
  if v_pair.event_id is null then raise exception 'no_draw_yet'; end if;
  if (select count(*) from public.kk_messages where event_id = v_pair.event_id and giver_id = v_pair.giver_id
        and receiver_id = v_pair.receiver_id and created_at > now() - interval '1 day') >= 20 then
    raise exception 'too_many_messages';
  end if;
  insert into public.kk_messages (event_id, giver_id, receiver_id, from_giver, body)
  values (v_pair.event_id, v_pair.giver_id, v_pair.receiver_id, p_to = 'giftee', trim(p_body))
  returning id into v_id;
  return v_id;
end $$;

create function public.send_nudge(p_family uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_me uuid := private.member(p_family); v_pair public.kk_assignments := private.pair_as_giver(v_me); v_id uuid;
begin
  if v_pair.event_id is null then raise exception 'no_draw_yet'; end if;
  if exists (select 1 from public.kk_messages where event_id = v_pair.event_id and giver_id = v_me and kind = 'nudge'
             and created_at > now() - interval '1 day') then
    raise exception 'already_nudged';
  end if;
  insert into public.kk_messages (event_id, giver_id, receiver_id, from_giver, kind, body)
  values (v_pair.event_id, v_me, v_pair.receiver_id, true, 'nudge', 'Your Kris Kringle would love some gift ideas! Add a few things to your wish list.')
  returning id into v_id;
  return v_id;
end $$;

-- What the notify-message edge function needs to email the other side. Only the sender may ask,
-- and nothing about the giver is included when the email goes to the giftee.
create function public.message_email(p_message uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare m public.kk_messages; v_to uuid; v_family uuid;
begin
  select * into m from public.kk_messages where id = p_message;
  if m.id is null then raise exception 'not_found'; end if;
  select family_id into v_family from public.kk_events where id = m.event_id;
  if (case when m.from_giver then m.giver_id else m.receiver_id end) <> private.member(v_family) then
    raise exception 'not_found';
  end if;
  if m.created_at < now() - interval '10 minutes' then raise exception 'too_late'; end if;
  v_to := case when m.from_giver then m.receiver_id else m.giver_id end;
  return jsonb_build_object(
    'to_email', (select email from public.people where id = v_to),
    'to_name', (select name from public.people where id = v_to),
    'to_has_account', (select user_id is not null from public.people where id = v_to),
    'to_giftee', m.from_giver,
    'kind', m.kind,
    'body', m.body,
    'family', (select name from public.families where id = v_family),
    -- The giver already knows who their giftee is, so replies can name them.
    'giftee_name', case when m.from_giver then null else (select name from public.people where id = m.receiver_id) end
  );
end $$;

revoke all on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
grant execute on function public.ping() to anon;
