-- Family board: organiser updates, polls (private votes), and house rules per exchange.

alter table public.kk_events add column rules text check (rules is null or length(rules) <= 1000);

create table public.family_posts (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  author_id uuid references public.people(id) on delete set null,
  body text not null check (length(trim(body)) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index family_posts_family on public.family_posts (family_id, created_at desc);
create index family_posts_author on public.family_posts (author_id);

create table public.polls (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  created_by uuid references public.people(id) on delete set null,
  question text not null check (length(trim(question)) between 1 and 200),
  options jsonb not null check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 8),
  status text not null default 'open' check (status in ('open', 'closed')),
  decision integer,
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
create index polls_family on public.polls (family_id, created_at desc);
create index polls_created_by on public.polls (created_by);

-- Votes are private: only counts ever leave the database, never who chose what.
create table public.poll_votes (
  poll_id uuid not null references public.polls(id) on delete cascade,
  person_id uuid not null references public.people(id) on delete cascade,
  option integer not null,
  primary key (poll_id, person_id)
);
create index poll_votes_person on public.poll_votes (person_id);

alter table public.family_posts enable row level security;
alter table public.polls enable row level security;
alter table public.poll_votes enable row level security;
revoke all on public.family_posts, public.polls, public.poll_votes from anon, authenticated;

-- ---------- Helpers ----------
create function private.polls_json(p_family uuid, p_viewer uuid) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', pl.id, 'question', pl.question, 'options', pl.options, 'status', pl.status, 'decision', pl.decision,
    'created_at', pl.created_at,
    'my_vote', (select option from public.poll_votes v where v.poll_id = pl.id and v.person_id = p_viewer),
    'counts', (select coalesce(jsonb_agg(
                 (select count(*) from public.poll_votes v where v.poll_id = pl.id and v.option = i - 1) order by i), '[]'::jsonb)
               from generate_series(1, jsonb_array_length(pl.options)) i),
    'voters', (select count(*) from public.poll_votes v where v.poll_id = pl.id)
  ) order by (pl.status = 'open') desc, pl.created_at desc), '[]'::jsonb)
  from (select * from public.polls where family_id = p_family
        order by (status = 'open') desc, created_at desc limit 10) pl
$$;

create function private.posts_json(p_family uuid, p_limit integer) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', fp.id, 'body', fp.body, 'at', fp.created_at,
    'author', (select name from public.people where id = fp.author_id)
  ) order by fp.created_at desc), '[]'::jsonb)
  from (select * from public.family_posts where family_id = p_family order by created_at desc limit p_limit) fp
$$;

revoke all on all functions in schema private from public, anon, authenticated;

-- ---------- Everyone ----------
create function public.get_board(p_family uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_me uuid := private.member(p_family);
begin
  return jsonb_build_object(
    'member_count', (select count(*) from public.people where family_id = p_family),
    'posts', private.posts_json(p_family, 10),
    'polls', private.polls_json(p_family, v_me),
    -- House rules and details of the family's current exchange (not secret).
    'exchange', (select jsonb_build_object('name', e.name, 'exchange_date', e.exchange_date, 'budget_cents', e.budget_cents, 'rules', e.rules)
                 from public.kk_events e where e.family_id = p_family
                 order by (e.status = 'drawn') desc, e.exchange_date desc nulls last, e.created_at desc limit 1)
  );
end $$;

create function public.vote(p_family uuid, p_poll uuid, p_option integer) returns void
language plpgsql security definer set search_path = '' as $$
declare v_me uuid := private.member(p_family); v_poll public.polls;
begin
  select * into v_poll from public.polls where id = p_poll and family_id = p_family;
  if v_poll.id is null then raise exception 'not_found'; end if;
  if v_poll.status <> 'open' then raise exception 'poll_closed'; end if;
  if p_option < 0 or p_option >= jsonb_array_length(v_poll.options) then raise exception 'bad_request'; end if;
  insert into public.poll_votes (poll_id, person_id, option) values (p_poll, v_me, p_option)
  on conflict (poll_id, person_id) do update set option = excluded.option;
end $$;

-- ---------- Organisers ----------
create function public.admin_post_update(p_family uuid, p_body text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_family); v_id uuid;
begin
  if (select count(*) from public.family_posts where family_id = p_family and created_at > now() - interval '1 day') >= 20 then
    raise exception 'too_many_posts';
  end if;
  insert into public.family_posts (family_id, author_id, body) values (p_family, v_admin, trim(p_body)) returning id into v_id;
  return v_id;
end $$;

create function public.admin_delete_post(p_family uuid, p_post uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.admin(p_family);
  delete from public.family_posts where id = p_post and family_id = p_family;
end $$;

create function public.admin_create_poll(p_family uuid, p_question text, p_options jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_family); v_id uuid; v_opts jsonb;
begin
  -- Trim options, drop blanks, cap each at 100 characters.
  select coalesce(jsonb_agg(left(trim(o), 100)), '[]'::jsonb) into v_opts
  from jsonb_array_elements_text(coalesce(p_options, '[]'::jsonb)) o where trim(o) <> '';
  if jsonb_array_length(v_opts) not between 2 and 8 then raise exception 'poll_options'; end if;
  if (select count(*) from public.polls where family_id = p_family and status = 'open') >= 10 then raise exception 'too_many_polls'; end if;
  insert into public.polls (family_id, created_by, question, options) values (p_family, v_admin, trim(p_question), v_opts) returning id into v_id;
  return v_id;
end $$;

create function public.admin_close_poll(p_family uuid, p_poll uuid, p_decision integer default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.admin(p_family);
  update public.polls set status = 'closed', closed_at = now(),
    decision = case when p_decision >= 0 and p_decision < jsonb_array_length(options) then p_decision end
  where id = p_poll and family_id = p_family;
  if not found then raise exception 'not_found'; end if;
end $$;

create function public.admin_reopen_poll(p_family uuid, p_poll uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.admin(p_family);
  update public.polls set status = 'open', closed_at = null, decision = null where id = p_poll and family_id = p_family;
  if not found then raise exception 'not_found'; end if;
end $$;

create function public.admin_delete_poll(p_family uuid, p_poll uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.admin(p_family);
  delete from public.polls where id = p_poll and family_id = p_family;
end $$;

create function public.admin_set_rules(p_family uuid, p_event uuid, p_rules text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.admin(p_family);
  perform private.check_event(p_event, p_family);
  update public.kk_events set rules = nullif(trim(p_rules), '') where id = p_event;
end $$;

-- Who to email about a new update or poll (used by the notify-family edge function).
create function public.admin_broadcast_info(p_family uuid, p_kind text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_admin uuid := private.admin(p_family); v_content jsonb;
begin
  if p_kind = 'post' then
    select jsonb_build_object('body', body) into v_content from public.family_posts where id = p_id and family_id = p_family;
  elsif p_kind = 'poll' then
    select jsonb_build_object('question', question, 'options', options) into v_content from public.polls where id = p_id and family_id = p_family;
  end if;
  if v_content is null then raise exception 'not_found'; end if;
  return jsonb_build_object(
    'family', (select name from public.families where id = p_family),
    'author', (select name from public.people where id = v_admin),
    'kind', p_kind, 'content', v_content,
    'recipients', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'email', email, 'has_account', user_id is not null)), '[]'::jsonb)
                   from public.people where family_id = p_family and email is not null and id <> v_admin)
  );
end $$;

revoke all on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
grant execute on function public.ping() to anon;
revoke execute on function public.claim_due_reminders() from authenticated;
grant execute on function public.claim_due_reminders() to service_role;

