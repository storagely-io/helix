# Prompt — implement the v4 SiteLink location + unit sync

Paste the block below into a fresh session started in `/var/www/Storagely/helix`.

---

Read these first, in order. None of them auto-load except the first.

1. `CLAUDE.md` here (workspace root) — three repos, which one owns what, the process-safety rules.
2. `docs/troubleshooting.md` — before diagnosing ANY symptom. Nearly every failure in this stack
   is silent. Note especially the `.env` entry: `apex-app/**/.env` is CRLF **and** quoted, so
   `set -a; . packages/api/.env` corrupts every value it exports and the result looks exactly like
   a dead credential. Use the `val()` helper in that entry.
3. `apex-app/CLAUDE.md` — architecture, storage philosophy, and the **credentials doctrine**.
4. `docs/handoff-tier-rate-crosscheck.md` then `docs/handoff-discount-lane.md` — the two most
   recent pieces of FMS sync work. The second's audit table is the backlog this belongs to.
5. `apex-app/docs/fms/sitelink/` if it exists, and `packages/api/app/services/fms-sitelink/`.

## The job

`v4_api_location` (detail) and `v4_api_location_units` are **not implemented for SiteLink**.
`FMS_LANE_SUPPORT.sitelink` (`syncs/fms/client.ts:327`) has `detail: false, units: false,
discounts: false`; only `insurance` and `catalog` are true. `syncs/fms/sitelink.ts:115-118`
returns `detail: {}` and `units: []` behind a `TODO(sitelink)`.

Implement those lanes, plus discounts if the evidence supports it, and **verify against legacy**.

## Step 0 — credentials, and confirm the lane before writing code

`SITELINK_CORP_CODE` / `SITELINK_CORP_LOGIN` / `SITELINK_CORP_PASSWORD` were added to
`apex-app/packages/api/.env`. **Nothing reads them** — `grep -rn "SITELINK_CORP" packages/api/app`
returns nothing. SiteLink has no env fallback; storEDGE is the only provider with one, because that
key is ours rather than an operator's.

The real home is `kv_store`, per `fms/systemKeys.ts:66-70` and `fms/fmsConfig.ts:67-78`:

| kv key | secret | required |
|---|---|---|
| `fms_sitelink_corp_code` | no | yes |
| `fms_sitelink_corp_username` | **yes** | yes — embeds the API key as `user:::APIKEY` |
| `fms_sitelink_corp_password` | **yes** | yes |
| `fms_sitelink_endpoint` | no | no (defaults to CallCenterWs 3.5) |
| `fms_sitelink_test_mode` | no | no |

Read `apex-app/docs/credentials.md`, put the pattern to the operator, and only then write the
three values into `kv_store` for the Gate 5 account and remove them from `.env`. Verify the
`corpUsername` value actually has the `user:::APIKEY` shape before blaming a 401 on the key.

## Step 1 — get the data locally

`/import "Gate 5 Self Storage"` (client_url `gate-5`, `configures.api_type = sitelink`,
legacy `users.id = 103`). `PROD_USER_API_EMAIL` / `PROD_USER_API_PASSWORD` are already set in
`apex-app/.env`. The import CLI talks HTTP to the **running** API — never stop the API for it.

That gives you legacy's own published artifacts (`v2_api_location*.json`) locally, which is half
the verification corpus for free.

## Step 2 — what already exists, so you build only what is missing

`packages/api/app/services/fms-sitelink/` owns SOAP transport, auth and the diffgram unwrap.
These ops are **implemented and uncalled** — the work is wiring, not a new client:

| Legacy method (`app/Sitelink/Sitelink.php`) | SOAP op | v4 function |
|---|---|---|
| `get_storage_locations()` `:138` | `SiteSearchByPostalCode` (`iCountry: -999`, empty postal) | `site.ts` `siteSearchByPostalCode` — already called |
| `get_site_information($loc)` `:200` | `SiteInformation` | `site.ts` `siteInformation` — **uncalled** |
| `get_units_by_location_code($loc)` `:167` | `UnitTypePriceList_v2` | `units.ts` `unitTypePriceListV2` — **uncalled** |
| `get_more_unit_info($loc)` `:1977` | `UnitsInformation_v2` (`lngLastTimePolled`) | `units.ts` `unitsInformationV2` — **uncalled** |
| `get_discounts_by_location_code($loc)` `:2005` | discount plans | `discounts.ts` `discountPlansRetrieve` — **uncalled** |

## Step 3 — settle the GRAIN before writing the normalizer

This is the decision the whole lane hangs on, and getting it wrong is expensive to undo.

**Legacy's SiteLink `location_units` rows are unit TYPES, not units.**
`SitelinkFacilitiesSyncJob.php:218-220` drives the loop from `UnitTypePriceList_v2` (one row per
type) and keys `LocationUnit::updateOrCreate` on `unit_id = $row['UnitID_FirstAvailable']` — the
first vacant unit of that type. `UnitsInformation_v2` supplies `Table` / `Table4` / `Table5` as
extra attributes joined on top (`:243-246`).

storEDGE's v4 lane publishes one row per REAL unit. So `v4_api_location_units` would mean two
different things per provider. Decide deliberately, write the decision down, and check it against:

- every `packages/components/base/*unit-card*` reader,
- `sdk/checkout-unit-context.ts` (`fromV4Unit`, `matchRequestedUnit`),
- `rental-contract/units.ts` `CanonicalUnit` — does `id` mean a unit or a type here?
- `docs/rental-scope.md` — unit criteria match on `typeToken`.

`ConcessionID` rides on the unit-type row, which is the discount linkage —
`CanonicalDiscount.id` is already typed cross-provider ("SiteLink `ConcessionID`, …").

## Step 4 — verification, by comparing legacy with apex

This method was proven on the storEDGE tier-rate work on 2026-08-28; reuse it rather than
inventing one. Three columns, joined per unit:

1. **Legacy, live.** Write a read-only PHP script in `app-storagely-io/._current/` (gitignored, so
   legacy's tree stays clean). Bootstrap Laravel, use the job's OWN `Sitelink` class so the SOAP
   auth and envelope are identical, and transcribe the rate/field resolution from
   `SitelinkFacilitiesSyncJob.php` **with line numbers** — a paraphrase makes the comparison
   worthless. Write nothing: no DB, no export. Run it with
   `docker compose exec -T laravel.test php ._current/<name>.php`.
   Do NOT dispatch the real job — it deletes and rewrites five tables before exporting.
2. **Legacy, as published.** The `v2_api_location*.json` artifacts the import brought down.
3. **Apex v4.** Trigger the real sync and read the written artifact:
   - log in: `POST /api/v1/auth/login` with `LOCAL_USER_API_EMAIL` / `_PASSWORD` from `apex-app/.env`
   - find the source: `GET /api/v1/users/{userId}/accounts/{accountId}/api-sources`
   - run it: `POST …/api-sources/{sourceId}/sync?force=true`, poll `…/sync-status`
   - read `apex-app/packages/api/.local-storage/default/fms/client_urls/gate-5/locations/<code>/`
   - **confirm the running API actually has your code**: compare `ps -o lstart= -p <api pid>`
     against the file mtimes. A stale process silently verifies the old build.

Compare **location** (name, address, coordinates, phone, hours) and **unit** (identity, type,
dimensions, every rate field, availability, concession) field by field. Report counts AND
per-field diffs. Expect row-count drift between the prod snapshot and a live run — prove it is
drift (status churn) rather than a rule divergence before dismissing it.

There is a live storEDGE probe pattern in `apex-app/scripts/probe-storedge-*.mjs` worth copying
for SiteLink if you need to see raw upstream shapes; those scripts are standalone, import nothing
from the repo, and print field names/types/fill counts.

## Step 5 — rules, only if the evidence demands them

`SYNC_RULE_SUPPORT` (`packages/rental-contract/sync-rules.ts`) has a `storedge` key and no others,
deliberately: an entry means "a normalizer applies these". If the SiteLink normalizer genuinely
applies a rule, add a `sitelink` key listing only the rules it really reads. Do not copy
storEDGE's list.

Every rule default must reproduce today's behaviour exactly — that file's header explains why, and
`tests/fms-sync-rules.test.ts` pins it against MEASURED legacy behaviour.

## Non-negotiables

- **Verify before you trust a green run.** The cross-package drift guards live in the ROOT vitest
  suite, not in `packages/api`'s jest suite. Run all three:
  ```
  cd apex-app && npx vitest run
  cd apex-app/packages/api && NODE_OPTIONS='--experimental-vm-modules' npx jest --config jest.config.main.js --maxWorkers=1
  cd apex-app && pnpm -r --if-present typecheck
  ```
  Baselines as of 2026-08-28: 450 vitest files / 8642 tests, 228 jest suites / 2905 tests, 7/7
  typechecks. `pnpm lint` fails at HEAD with 2235 pre-existing problems — don't chase it.
- Touch `packages/rental-contract`? Rebuild its dist
  (`pnpm --filter @storagely/rental-contract build`) and restart the dev servers, or the platform
  renders stale rules and the API runs an old lane flag.
- Registering a new artifact lane means touching the hand-maintained lists in
  `endpoints/registry.ts`, `location-artifacts/artifactLanes.ts`, `imports/fmsMirror.ts`,
  `webpage/src/data-loader.ts`, `components/sdk/data-layer-endpoints.ts` and
  `editor/src/sidebar/panels/endpointUrls.ts`. The root suite catches every one of these; that is
  what it is for.
- **Do not push.** `apex-app` main deploys prod via CircleCI with no approval gate. Two repos means
  two commits, never one. `atlas/` pushes to `storagely-home-base`.
- Never put a real operator's name into a shipped string.

## Deliverable

Working `detail` + `units` lanes for SiteLink, the `FMS_LANE_SUPPORT` flags flipped only for what
is genuinely implemented, tests, and a `docs/handoff-sitelink-v4-sync.md` in the workspace
recording the grain decision, the verification results field by field, and what is still missing.
