-- Run the send-reminders edge function every morning (9:00am Toronto in winter).
-- The function is safe to call repeatedly: each reminder is claimed and sent only once.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

select cron.schedule(
  'kk-send-reminders',
  '0 14 * * *',
  $$ select net.http_post(
       url := 'https://lsjqvbochnoewzwgcygg.supabase.co/functions/v1/send-reminders',
       headers := '{"Content-Type": "application/json"}'::jsonb,
       body := '{}'::jsonb
     ) $$
);
