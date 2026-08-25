# The local Atlas database

Atlas's database is Supabase (Lovable Cloud). Locally it is a throwaway stack in Docker at
`127.0.0.1:54321`, built from the repo's migrations. Everything about it lives under
`helix/.supabase-local/` — an untracked Supabase project, deliberately not `atlas/supabase/`.

```bash
make supabase-help   # status, and how to go local
make supabase-up
make supabase-wire   # write both the server and browser targets
make supabase-down
```

`make down` deliberately leaves the stack running — it has its own lifecycle.

## Why not `supabase db reset`

`atlas/supabase/config.toml` is **one line** (`project_id`). It is a project *link*, not a
local-stack config: no `[db]`, `[api]` or `[auth]` sections. And the migration history is **not
reproducible in order** — an atomic run aborts on at least two independent classes:

1. **Bare `cron.unschedule('job')`** for jobs created out-of-band in the hosted project. Handled
   by `.supabase-local/pending/00000000000001_local_bootstrap.sql`, which creates `pg_cron` /
   `pg_net` and pre-creates the 7 job names those calls expect.
2. **Duplicate object creation** — e.g. two migrations both `CREATE TABLE atlas_import_profiles`,
   an order the hosted database never actually hit.

So `scripts/supabase-apply.sh` applies **per file with `ON_ERROR_STOP=0`**, letting each
statement stand or fall alone, and logs and classifies every error rather than swallowing it.
Real result: **297 of 301 files clean, 4 with errors** — all duplicate-object, none consequential.

This is a governance divergence, not just a setup shortcut: `atlas/CLAUDE.md` states Lovable owns
the Supabase schema and migrations must never be applied directly to the hosted project. Applying
them to a **local throwaway** is the compromise; do not carry it upstream.

## The grant step — omit it and nothing works

Applying migrations as `postgres` via `docker exec` creates every table **without** the
privileges PostgREST's roles need. Result: `42501 permission denied for table …` on 100% of
Atlas's reads, surfacing only in the browser console.

`.supabase-local/grants.sql`, applied by `supabase-apply.sh` after the tables exist:

```sql
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES    IN SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
```

RLS still governs `anon` / `authenticated`; `service_role` bypasses it by design, and that is
the role Atlas's server uses.

**This class of bug hides from `docker exec psql`**, which connects as `postgres` and has every
privilege — so a hand check passes while the app fails. Reproduce it through PostgREST with the
service key instead:

```bash
curl -s "http://127.0.0.1:54321/rest/v1/atlas_locations?select=id&limit=1" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H "authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"
```

## The cron jobs would POST production

The migrations schedule `pg_cron` jobs whose bodies `net.http_post` to **production Lovable
endpoints** — several every 1–2 minutes (`rehost-atlas-images`, `poll-pending-reviews`,
`atlas-backfill-geocoding-daily`, `drain-reviews-sync`, `drain-gbp-sync`,
`webpage-captures-cleanup`, `atlas-media-url-health-nightly`). A local database happily firing
real outbound traffic at production is not acceptable, so `supabase-apply.sh` unschedules **all**
of them as its last step and verifies none remain.

Re-applying migrations re-creates them. The unschedule step must stay last.

## Error detection, and a lesson

The first version of the apply script anchored its check at `grep '^ERROR'`. `psql` prefixes
diagnostics with `psql:<stdin>:NN:`, so **nothing ever matched** and a failing run reported
`301 clean, 0 errors`. Matching `ERROR:|FATAL:` unanchored produced the true numbers.

A grep that can only produce good news is not a check. Feed a detector a known failure before
trusting a pass.

## Known schema gap

`atlas_fms_code_conflicts` **has no `CREATE TABLE` in any of the 301 migrations** — the sole
reference across the whole set is a `DROP POLICY … ON public.atlas_fms_code_conflicts`. It exists
in the hosted project because Lovable created it out of band, and the migration history never
captured it.

Consequence: anything reading it errors locally — `atlas/src/lib/atlas-fms-conflicts.functions.ts`
(the FMS code-conflict scan surface). Not worth hand-creating without the real definition;
treat that one screen as unavailable locally. See [open-items.md](open-items.md).

This is a useful signal about the whole set: the migrations are a **partial** record of the
hosted schema, so a table missing locally does not imply a table missing in production.
