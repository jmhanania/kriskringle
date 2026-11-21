-- Per-option vote counts are only returned to organisers; members see just their own vote
-- and how many people have voted.
create or replace function private.polls_json(p_family uuid, p_viewer uuid) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', pl.id, 'question', pl.question, 'options', pl.options, 'status', pl.status, 'decision', pl.decision,
    'created_at', pl.created_at,
    'my_vote', (select option from public.poll_votes v where v.poll_id = pl.id and v.person_id = p_viewer),
    'counts', case when (select is_admin from public.people where id = p_viewer) then
               (select coalesce(jsonb_agg(
                  (select count(*) from public.poll_votes v where v.poll_id = pl.id and v.option = i - 1) order by i), '[]'::jsonb)
                from generate_series(1, jsonb_array_length(pl.options)) i)
             else null end,
    'voters', (select count(*) from public.poll_votes v where v.poll_id = pl.id)
  ) order by (pl.status = 'open') desc, pl.created_at desc), '[]'::jsonb)
  from (select * from public.polls where family_id = p_family
        order by (status = 'open') desc, created_at desc limit 10) pl
$$;
revoke all on function private.polls_json(uuid, uuid) from public, anon, authenticated;
