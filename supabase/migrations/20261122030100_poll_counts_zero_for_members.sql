-- Members get an all-zero counts array (never real totals) instead of null, so pages that
-- still expect an array keep working. Organisers get the real counts.
create or replace function private.polls_json(p_family uuid, p_viewer uuid) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', pl.id, 'question', pl.question, 'options', pl.options, 'status', pl.status, 'decision', pl.decision,
    'created_at', pl.created_at,
    'my_vote', (select option from public.poll_votes v where v.poll_id = pl.id and v.person_id = p_viewer),
    'counts', (select coalesce(jsonb_agg(
                 case when (select is_admin from public.people where id = p_viewer)
                      then (select count(*) from public.poll_votes v where v.poll_id = pl.id and v.option = i - 1)
                      else 0 end order by i), '[]'::jsonb)
               from generate_series(1, jsonb_array_length(pl.options)) i),
    'voters', (select count(*) from public.poll_votes v where v.poll_id = pl.id)
  ) order by (pl.status = 'open') desc, pl.created_at desc), '[]'::jsonb)
  from (select * from public.polls where family_id = p_family
        order by (status = 'open') desc, created_at desc limit 10) pl
$$;
revoke all on function private.polls_json(uuid, uuid) from public, anon, authenticated;
