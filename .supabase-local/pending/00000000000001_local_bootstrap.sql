-- LOCAL-ONLY bootstrap. Not part of Atlas's migration history; lives in an
-- untracked copy of the migration set under helix/.supabase-local/.
--
-- Why it exists: several Atlas migrations call the BARE form
--     SELECT cron.unschedule('<job>');
-- which ERRORS when the job is absent. In the hosted project those jobs were
-- created out of band, so they are not reproducible from the migration files —
-- migration 20260615222833 dies on 'rehost-atlas-images' and aborts the run.
--
-- Pre-creating each job makes every one of those calls succeed, so the real
-- migrations apply completely unmodified. Each bare unschedule is immediately
-- followed by a cron.schedule that recreates the job, so this only supplies the
-- missing initial state.
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

DO $bootstrap$
DECLARE
  j TEXT;
  names TEXT[] := ARRAY[
    'rehost-atlas-images',
    'poll-pending-reviews',
    'atlas-backfill-geocoding-daily',
    'drain-reviews-sync',
    'drain-gbp-sync',
    'webpage-captures-cleanup',
    'atlas-media-url-health-nightly'
  ];
BEGIN
  FOREACH j IN ARRAY names LOOP
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = j) THEN
      -- Harmless placeholder body; the real migrations replace the schedule.
      PERFORM cron.schedule(j, '0 0 1 1 *', 'SELECT 1');
    END IF;
  END LOOP;
END
$bootstrap$;
