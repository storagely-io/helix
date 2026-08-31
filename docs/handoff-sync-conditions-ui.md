# HANDOFF PROMPT — build the sync-conditions pipeline UI

> **Done.** This prompt was run on 2026-08-27; what came out of it is
> [docs/handoff-sync-pipeline-ui.md](handoff-sync-pipeline-ui.md). Kept for the brief it
> gave, not as work outstanding.

Paste the block below to start the implementation session. Everything it references is on disk.

---

Continuing work in `/var/www/Storagely/helix`. **The backend is done and verified; this session
builds the UI.**

Read these first, in order:

1. `docs/handoff-scoped-sync-rules.md` — both parts. Part 1 = scoped rules, Part 2 = conditions.
2. `~/.claude-orgs/storage/plans/swift-launching-perlis.md` — the approved plan Part 2 implemented.
3. The approved design: **https://claude.ai/code/artifact/6511ba6c-3df4-439d-bf7d-5bf3fed8f489**
   Page 1 is the design to build (direction A). Page 2 is the directions not taken, kept for the
   argument. Read it with the Artifact tool — it is yours, so it comes back as raw HTML; the
   readable content is in the `.dc.html` entries of the state block, or re-extract the working
   files with the `design` skill's `seed-canvas.mjs --extract`. The working files are still at
   `/tmp/claude-1001/-var-www-Storagely-helix/76edce4c-07c5-4837-8996-d6212157d45f/scratchpad/canvas/`
   if that path survived.

## State

**43 files uncommitted in `apex-app`. Nothing pushed. Pushing `apex-app` main deploys prod via
CircleCI with no approval gate.** Two commits are owed and not written (workspace `docs/` and
`apex-app`, separately — they are different repos).

Green as of handoff: `pnpm typecheck` 7/7 · `npx vitest run` **8612** · api Jest **2842**
(needs `NODE_OPTIONS='--experimental-vm-modules'`). One flaky unrelated test,
`websitesService › 409s a stale brand write`, fails ~1 run in 3 and passes in isolation.

The local sandbox is at baseline: `fmsConfig` carries no overrides, 140 read → 112 published,
51 + 61 per facility, feed order. **Leave it that way** — restore it after any live test.

## What is built and working

The whole rule + condition engine, verified against a real sync:

- `rental-contract/sync-rules{,-resolve}.ts` — 18 rules, `SyncRuleOverride` with `when`,
  `resolveSyncRulesAt`, validation, readback, fingerprint.
- `rental-contract/sync-fields.ts` — the field catalog (~47 storEDGE fields, typed, grouped,
  measured enum options), `SYNC_FIELDS_FORBIDDEN`.
- `rental-contract/sync-conditions.ts` — the grammar, `matchesSyncConditions`, `describeSyncConditions`.
- `syncs/fms/storedge.ts` — per-facility resolution, `facility-filter`, the inventory-source read
  redirect.
- `syncs/fms/normalize/storedge.ts` — condition gates, `no-tiering`, `unit-sort`, `dimension-rounding`.
- `apiSourcesController.ts` — `conditionEffect` with `byLocation`.

Do not redesign any of it. The UI reads it.

## What to build

Direction A: **the sync as a pipeline**, replacing BOTH the lane list (`ApiSourceSyncTree.tsx`)
and the conditions modal (`LaneConditionsModal.tsx`) on the API Source detail page.

Two groups, because the sync has two grains — facilities decided once, units decided again at each
facility. Each step shows what it did on the last run. Exceptions are a **chip row on the step**,
one level of nesting, not four. Untouched rules collapse to one dashed row. A step inspector on the
right edits the selected step.

The existing pieces to reuse rather than rewrite:
`syncRuleControls.tsx` (rule cards, params), `syncConditionRows.tsx` (the field ▾ · comparison ▾ ·
value repeater), `syncRuleOverrides.tsx` (the exception editor), `components/scope/ScopePicker`
(pass `unitCriteria={false}`), `useScopeSources` for facility names.

### The one backend change the design needs

The step inspector shows *"Unit status removed 19 at Northgate, 9 at Riverside"*. That data exists
per facility — `unitsCensus.dropped` is written on each per-location job row — but
`aggregateConditionEffect` (`apiSourcesController.ts`) **sums `dropped` across facilities and keeps
only `read`/`kept`/`viaOverrides` per facility**. Carry each facility's `dropped` array into its
`byLocation` row. That is the whole change; everything else the board shows is already on the wire.

## Gotchas that cost real time

1. **`rental-contract` is consumed as a BUILT DIST**, not source — `package.json` resolves
   `node → ./dist/index.js`. A contract change is invisible to the running API until
   `cd packages/rental-contract && npm run build`, and **there is no error** if you forget: the
   sync silently applies the old catalog. This invalidated one measurement mid-session. Rebuild
   before trusting any live sync.
2. **`packages/api/.env` has CRLF endings.** `set -a; . .env` leaves a `\r` on the storEDGE OAuth
   key and every request 401s. Source it as
   `export STORAGE_API_KEY="$(grep '^STORAGE_API_KEY=' packages/api/.env | cut -d= -f2- | tr -d '\r' | sed 's/^"//; s/"$//')"`.
3. **Driving the platform locally.** `POST /api/v1/auth/login` with `LOCAL_USER_API_EMAIL` /
   `LOCAL_USER_API_PASSWORD` from `apex-app/.env`. The seeded operator carries
   `forcePasswordReset: true`, so the SPA bounces to `/login/change-password` — the token is fine,
   only the client guard blocks; patch `storagely.auth.user` in localStorage to
   `forcePasswordReset: false` rather than changing the password. Session key is
   **`storagely.auth.token`**. The route is `/users/:userId/**admin**/accounts/:id/api-sources/:id`.
   A `[data-stg-popup]` overlay swallows clicks — remove it before driving. Playwright: use
   `executablePath: '/usr/bin/chromium-browser'`, `args: ['--no-sandbox']`.
4. The local Helix DB is **PGlite, single-writer**. `kill -TERM` one pid at a time, never `kill -9`,
   never `pkill -f node`.
5. **Compilation is not verification for UI work.** Two defects this cycle survived a clean
   typecheck and 8,500 green tests and died on the first screenshot / first real sync. Drive the
   browser and look, or say plainly that it has not been looked at.

## Two questions left open on the board

- The facility switcher in the header re-runs the whole board for one facility — that is direction C
  folded in. Build it now or later?
- "Show 9 that changed nothing" hides the untouched rules by default. Right call?

## Still owed, unrelated to this session

- **`SECURITY.md`** needs two entries: the `raw` allow-list on a CDN-public artifact (owed since
  two sessions ago), and that a condition on a withheld field (`max_rate`) renders that value in
  the platform UI and the run log.
- `docs/open-items.md` §5 — MyGarage's substring match, not expressible in the grammar.
- The three missing units lanes (SiteLink, SSM) and the Yardi client — the named next phase, and
  the reason the field catalog has one provider.
