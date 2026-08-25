# Troubleshooting — symptom to real cause

Ordered roughly by how misleading the symptom is. Every entry here was hit for real in this
workspace; the "wrong first guess" lines are the ones that cost time.

---

## "Select a location" under a location that *is* selected

The header switcher names the facility, the page body says `Select a location`.

**Cause.** Not routing, not the lock — a **visibility filter**. Every locations list in Atlas
(`atlas/src/lib/atlas-locations-list.functions.ts:149`) requires:

```
fields.cs.{"helix_tags":["page/location"]}   OR   fields->>atlas_origin = 'import'
```

and, via an inner join, `atlas_companies.platform_website_id`. A row that satisfies neither is
returned to nobody. `DerivedSettingsPages.tsx:562` then does
`rows.find(r => r.locationSlug === locationSlug)`, gets `undefined`, and renders
`row?.location ?? "Select a location"`.

**Fix.** `make sync-atlas`. See [atlas-local-data.md](atlas-local-data.md).

**Wrong first guess:** that the location resolver had failed. It had not — the resolver reads
`atlas_locations` directly by `platform_location_id` and never applies this filter, so
resolution succeeded while every list stayed empty. Two code paths, one table, different
filters.

---

## "Atlas signing secret is not configured on this environment."

**Cause.** `HELIX_PUBLIC_SECRET_KEY` is unset on Atlas's server
(`atlas/src/lib/edge-settings.server.ts:377`). Its twin on the Helix side is
`PUBLIC_SECRET_KEY` — **one value, two names.**

Note the check order in `fetchEdgeSettingsRaw`: the secret is tested **before** accountId,
apiPath and locationCode. So this one message can be masking three further gaps behind it.
Fixing the secret often reveals the next one.

**Fix.** Set both in `helix/.env.local`. `make doctor` verifies presence *and* equality.
See [secrets-and-env.md](secrets-and-env.md).

---

## "This location has no FMS location code assigned" — but the header shows a code

**Cause.** The code has two homes and the two readers disagree:

| Reader | Reads |
|---|---|
| locations list (`atlas-locations-list.functions.ts`) | `fields.fms_location` **\|\|** `helix_page_location_code` |
| `edge-settings` (`edge-settings.functions.ts`) | `fields.fms_location` **only** |

That is deliberate, not a bug: `fields.fms_location` is the **operator's** pick (set on the FMS
Software page, the Location Detail field editor, or the bulk-id CSV). Helix does not own it, so
the reconcile will never write it.

**Fix.** `make sync-atlas` binds it from `helix_page_location_code` — doing locally what the
operator did in prod, with the provenance the FMS path uses (`sources.fms_location = 'fms'`).

---

## Every Atlas read fails, but nothing appears in any server log

**Cause.** `42501 permission denied for table …`. Applying the migrations as the `postgres`
superuser via `docker exec` creates tables **without** the privileges PostgREST's roles
(`anon`, `authenticated`, `service_role`) need. Atlas's server client uses `service_role`, so
100% of reads fail — and the failure surfaces in the **browser** console
(`iframe-session.tsx:504` is a `console.warn`), not stdout.

**Fix.** `.supabase-local/grants.sql`, now a step inside `scripts/supabase-apply.sh`.

**How to confirm in one call** — replay the query as the API role, not as `postgres`:

```bash
curl -s "$SUPABASE_URL/rest/v1/atlas_locations?select=id&limit=1" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H "authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"
```

A `docker exec psql` check will *not* reproduce this — it connects as `postgres`, which has
every privilege. That is exactly why the bug survived earlier passes.

---

## `Failed to load pages: Unauthorized: session verify rejected (401)`

**Cause.** Atlas's server verified a **local** session token against **production** Helix.
`helixBase()` (`atlas/src/lib/helix-access.server.ts:68`) defaults to
`https://api.getstoragely.com`, and 28 modules share that default.

**Fix.** `HELIX_BASE_URL=http://localhost:9600`, exported by `scripts/lib.sh`. `make dev`
does this; a bare `bun run dev` in `atlas/` does not.

---

## Atlas draws its own sidebar and header inside the iframe (duplicated chrome)

**Cause.** `isLovableHost()` (`atlas/src/lib/iframe-session.tsx:110`) returns true for
`localhost` and `127.0.0.1`, and `useIsEmbedded()` (line 678) then calls `setEmbedded(false)`
— so Atlas concludes it is a top-level Lovable preview and renders its full shell.

**Fix.** Serve the iframe from the WSL **LAN IP**, not `localhost`
(`scripts/wire-embed.sh` writes `VITE_ATLAS_IFRAME_URL` that way). The *parent* must still be
`http://localhost:9720` — that is the origin Atlas's allowlist accepts, and the only one for
which `?apiBase=` is honoured.

---

## "Couldn't load Atlas / This company isn't set up in Atlas yet"

`ctx_error=UNKNOWN_ACCOUNT`. Ordered by likelihood:

1. `SUPABASE_SERVICE_ROLE_KEY` unset → Atlas's server cannot read `atlas_companies` at all.
2. Grants missing → it can read, but every statement is `42501` (above).
3. No `atlas_companies` row whose `platform_account_id` matches the Helix account in the URL.

**Distinguish 1 from 2 quickly:** a wrong-but-present key returns `Invalid API key`; an absent
one returns a `Missing`/not-configured error. Different message, different cause.

---

## The location reverts to "All locations" on reload

**Cause.** The iframe `src` never carries `?pageId` — `atlasIframeUrl()`
(`apex-app/packages/platform/src/shell/atlasEmbed.ts:95`) appends **only** `apiBase`.
Resolution happens over the bridge instead: the shell posts `lock` with the pageId
(`AtlasRoute.tsx:270`), Atlas calls `resolveLocationForPage`, and navigates. If any step of
that fails, the reload lands on the rollup.

In this workspace the failing step was the `42501` above, in
`atlas-page-resolve.functions.ts` lookup 2 (`platform_location_id = pageId`).

---

## Switching location leaves a sub-page and lands on Overview

**Cause.** `checkout-settings` is not in the `EmbeddedNavSection` vocabulary, so no `section`
token exists to preserve. Full mechanism in [embed-and-scope.md](embed-and-scope.md#the-section-round-trip-and-where-it-stops).
Not yet fixed — owner-gated. See [open-items.md](open-items.md).

---

## `make dev` fails on a port that looks free

**Cause.** An orphaned `tsx watch` **supervisor** from an earlier run. Killing the child lets
the supervisor respawn it and retake the port.

**Fix.** `make down` sweeps supervisors and then *verifies*, naming survivors. `make status`
shows which pid holds each port.

Two detector bugs are worth knowing about, because both classes recur:
- matching on `pgrep -af` argv produced **false positives** (it matched diagnostic shells that
  merely mentioned the port);
- matching on argv paths produced **false negatives** (relative-path launches).

The reliable test is the process's actual working directory, via `/proc/PID/cwd` —
`pid_in_workspace()` in `scripts/lib.sh`.

---

## A `.env` value is "set" but the app disagrees

Three separate traps, all seen here:

1. **`atlas/.env.local` never reaches `process.env`.** Vite exposes only `VITE_`-prefixed vars,
   and only to the **browser**. Server code (`*.server.ts`, `*.functions.ts`) reads
   `process.env`, which a `.env` file does not populate. Use `helix/.env.local`.
2. **`apex-app/.env` is CRLF.** A trailing `\r` becomes part of the value.
3. **Quoting.** A value may be wrapped in double quotes *and* contain quote characters, so
   `tr -d "\"'"` corrupts it. Strip only the outer pair: `sed 's/^"//; s/"$//'`.

Trap 3 produced a login 401 that looked like data loss.

---

## `psql` reported success and the schema is still wrong

**Cause.** Error detection anchored at line start (`grep '^ERROR'`). `psql` prefixes
diagnostics with `psql:<stdin>:NN:`, so nothing matched and a failing run reported clean.

**Fix.** Match `ERROR:|FATAL:` unanchored. Doing so changed a reported *301 clean / 0 errors*
into the true *297 clean / 4 with errors*.

The general rule: **a grep that can only ever produce good news is not a check.** Prove a
detector fires by feeding it a known failure before trusting a pass.

---

## An Atlas URL returns HTTP 200 and the page is still wrong

`curl` returning 200 for an Atlas route proves **almost nothing**: those routes are
`ssr: false`, so the server hands back the SPA shell and the real work happens in the browser.
`/atlas/{company}/this-route-does-not-exist/foo` also returns 200.

Verify the **data chain** instead — the queries and signed requests the page will make. That
evidence is real; a 200 is not.

## The API crashed mid-session (`ERR_MODULE_NOT_FOUND` on a contract package)

**Now self-healing.** Anything that rewrites `rental-contract`/`workflow-contract` `dist/`
while the API runs (a stray `pnpm build`, the root `pnpm dev`'s `tsc -w`) makes `tsx watch`
restart the API mid-wipe and it dies importing the half-written dist. This used to leave the
whole workspace headless — platform log full of `ECONNREFUSED 127.0.0.1:9600`, Atlas log full
of `provisioning failed / fetch failed` — while every *other* port stayed up.

`dev.sh` runs the API under a health-based watchdog — health-based because `tsx watch`
survives its child's crash (it only respawns on a file change), so the process tree stays
alive while :9600 is dark and a process-exit wait would never fire. When health stays dark
~20s (120s grace on a cold boot), the watchdog SIGTERMs the api child then its tsx
supervisor, rebuilds the contracts if `contracts_built()` says they're stale, and restarts
`pnpm dev:api` (giving up after 3 starts that never reach healthy). Deliberate stops are
excluded via `.logs/.stop-requested`, written
by `make down` and dev.sh's own cleanup before ports are stopped. If the API is down and STAYS
down under `make dev`, read the tail of `.logs/api.log` — the supervisor preserves crash
evidence (the log is appended to, not truncated, across restarts).

## Atlas reads fail with `TypeError: fetch failed` right after boot

The local Supabase stack isn't running while `SUPABASE_URL` points at it. `make dev` now
starts the stack itself (idempotent; skip with `HELIX_SKIP_SUPABASE=1`), and `make doctor`
actually probes `:54321` instead of judging the URL by shape — a well-shaped URL with nothing
behind it used to get a false "ok Supabase: LOCAL". The stack keeps its own lifecycle:
`make down` leaves it running; `make supabase-down` stops it. Its db volume outlives the
containers, so `make supabase-up` after a reboot comes back with schema AND data and skips
the migration apply.

## `make import CMD='import …'` fails with "Cannot reach the local API"

The import CLI (`dev-import.mjs`) talks to the RUNNING local API over HTTP for every
subcommand — it never opens PGlite directly (that's the legacy `packages/api/scripts/
import-website.ts`, which does require the API stopped). An earlier version of
`scripts/import.sh` had this backwards and stopped the API before `import`, guaranteeing the
failure. The wrapper now starts the API if it's down and leaves it running afterwards —
import jobs execute inside the API process, so stopping it mid-job kills the import.
