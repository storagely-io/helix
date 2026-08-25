---
description: Re-pull an already-imported operator's latest production data (overwrite in place)
argument-hint: <operator name>
---

Refresh the local copy of operator "$ARGUMENTS" with the latest production data. This is an
**overwrite re-import** using the existing import machinery — there is no incremental mode: the
local website's pages are deleted and re-imported fresh, and the Atlas/FMS mirrors are
re-written verbatim (they are unconditional puts, so they refresh automatically).

**Never show the user a production URL, hostname, subdomain, or website id** — same rule as
`/import`. Local ids and URLs only.

## Flow

1. **Find the existing local import** — read the provenance records at
   `apex-app/packages/api/.local-storage/default/system/imports/*.json`. Each carries
   `websiteId`, `accountId`, `atlasApiPath`, `fmsApiPath`, `importedAt`, `createdAccount`.
   Match "$ARGUMENTS" against `atlasApiPath` and against the account/website names (resolve
   local names via the running API if needed). Ignore `*.meta` sidecar files.
   - No matching record → this operator was never imported here. Point the user at
     `/import $ARGUMENTS` and stop.
   - Several records → AskUserQuestion (local website names + importedAt only).

2. **Stack check** — `make status`; api :9600 must be healthy (start the stack per `/import`
   step 1 if not).

3. **Confirm once** (AskUserQuestion or a plain yes/no): "Re-pull the latest from production
   and replace the local copy imported <importedAt>? Any local edits to this site are lost —
   pages are deleted before anything is fetched, no rollback." Abort on no.

4. **Resolve a fresh token** — `make import CMD='resolve "<operator name>"'`. Tokens live in
   the API process's memory (1h TTL) and die on any API restart — always resolve fresh, right
   before the import. Match-list rules as in `/import`.

5. **Import with overwrite** — write the request JSON to the scratchpad:
   ```json
   {
     "targetAccountId": "<accountId from provenance>",
     "mode": "overwrite",
     "targetWebsiteId": "<websiteId from provenance>",
     "selection": { "assets": "none", "atlasEndpoints": true, "fmsEndpoints": true }
   }
   ```
   Carry forward the previous run's choices where known (e.g. if provenance shows
   `rehostedAssets: true`, ask whether to re-host again). Run
   `make import CMD='import <token> <file>'` and poll `make import CMD='status <jobId>'`
   until `done`.

6. **Re-sync Atlas** — `make sync-atlas`. It is idempotent (`unchanged=N` for rows that didn't
   move); confirm the operator's locations are listable in its output.

7. **Clean up disconnected location rows** — overwrite re-import gives every page a NEW local
   page id, so the sync creates fresh `atlas_locations` rows and *disconnects* the old ones
   (nulls `platform_location_id`) — but disconnected rows still carry `helix_tags`, so they
   linger as stale duplicates in every locations list. Soft-delete them (the app's own
   convention), after telling the user:
   ```
   docker exec -i supabase_db_supabase-local psql -U postgres -d postgres -c \
     "update atlas_locations set deleted_at = now()
       where deleted_at is null and platform_location_id is null and fields ? 'helix_tags';"
   ```
   This touches only rows the Helix sync once managed that no longer match a live page, in the
   LOCAL throwaway database. Re-check the listable count afterwards (`make status` prints it).

8. **Report** — page/mirror counts from the job report, the LOCAL editor URL, and the same
   verification triage as `/import` step 8 (FMS units + Atlas metadata visible; both blank →
   apiPath unset; FMS-only → Atlas mirror empty).
