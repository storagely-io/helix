# HANDOFF — storEDGE detail + units lanes, and operator-editable sync conditions

Session of 2026-08-27. Successor to [docs/handoff-v4-location-cutover.md](handoff-v4-location-cutover.md)
(the roadmap) — that session produced the plan; this one implemented step 1 of it.

**Everything below is uncommitted, in `apex-app`.** 19 files changed, 16 new. Nothing pushed —
pushing `apex-app` main deploys prod via CircleCI with no approval gate.

Approved plan: `~/.claude-orgs/storage/plans/precious-sleeping-fountain.md` (updated in place with
the probe results).

---

## What shipped

| | |
|---|---|
| **storEDGE detail lane** | `v4_api_location` was `{}` on every facility. Now identity + contact from `GET /v2/companies/:id/facilities`, address + **coordinates** from `GET /v2/facilities/:id/addresses`. |
| **storEDGE units lane** | `v4_api_location_units` was `[]`. Now real, from **v1** `GET /:facility/units` — see the reversal below. |
| **Sync conditions** | 15 named, operator-editable rules replacing anonymous `if`s. Catalog + resolution + readback in `packages/rental-contract/sync-rules{,-resolve}.ts`. |
| **Lane-anchored UI** | Each rule is anchored to the artifact it governs; the lane row carries a condition chip and opens a per-lane modal. |
| **Facility discovery** | `listLocations()` can enumerate from the company instead of the hand-typed UUID list. Opt-in, defaults off. |

Verified live: a real local sync produced **140 units read → 112 published, 28 removed**, and the
28 reconcile exactly with the probe's reserved counts (19 + 9). The census machinery works
end-to-end.

---

## The two reversals — read these before changing the lanes

### 1. The units lane reads **v1**, not v2

Built on v2 first, for a real security reason: v2 omits six fields v1 carries, and
`v4_api_location_units` is CDN-public at a derivable URL. `--compare-v1` measured them —
`current_tenant_id`, `current_ledger_id`, `payment_status`, `combination_lock_number`,
`combo_lock_group`, `overlock_lock_number`.

The same run showed v2 omits nearly everything the normalizer needs:

| Field | v1 | v2 | Why it matters |
|---|:--:|:--:|---|
| `available_for_move_in` | ✓ | ✗ | third leg of the availability triple |
| `channel_rate` | ✓ | ✗ | the online price — v2 has no channel pricing at all |
| `unit_type` (named object) | ✓ | ✗ | v2 has a UUID ⇒ `typeToken` would be opaque |
| `tier` (carries rank) | ✓ | ✗ | v2's own `rank` was null on **70/70** |
| `unit_amenities` (with names) | ✓ | ✗ | v2 has bare ids |
| `exclude_from_api` | ✓ | ✓ | on BOTH — legacy simply never read it |

⇒ v1, with the **`raw` allow-list** as the control. The probe is what makes that list provably
complete rather than a guess. `listFacilityUnitsV2` is kept and documented as *not* what the sync
uses.

### 2. `GET /v2/facilities/:id` exists

`readFacilityRow` originally filtered the whole company list per facility — O(facilities²) across
the fan-out, and impossible without `companyId`. The probe confirmed a single-facility read. Both
problems came from designing around an unverified absence.

---

## The gotcha that cost an hour

**`packages/api/.env` has CRLF line endings.** `set -a; . .env` leaves a trailing `\r` on the OAuth
key and every storEDGE request 401s — including the pre-existing `probe-storedge-units.mjs`. dotenv
strips it, so the app syncs fine and the credentials look broken when they are not.

```bash
cd apex-app
export STORAGE_API_KEY="$(grep '^STORAGE_API_KEY=' packages/api/.env | cut -d= -f2- | tr -d '\r' | sed 's/^"//; s/"$//')"
export STORAGE_API_SECRET="$(grep '^STORAGE_API_SECRET=' packages/api/.env | cut -d= -f2- | tr -d '\r' | sed 's/^"//; s/"$//')"
node scripts/probe-storedge-facilities.mjs --facility 25e2ece8-668b-467d-934b-81dd0024edbc --compare-v1
```

The probe now refuses to report findings when every call 401s, rather than reading an auth failure
as "endpoint absent".

---

## The rule catalog

15 rules, each anchored to one artifact. Defaults reproduce legacy **exactly** — measured, not
assumed — so shipping changed nothing until an operator moves a dial.

| Artifact | Rules |
|---|---|
| `v4_api_locations` | Which facilities to sync · Deleted facilities |
| `v4_api_location` | Questionable addresses |
| `v4_api_location_units` | 12 — status allow-list, availability triple, `exclude_from_api`, flags, rates, minimum rate, amenity derivation, rounding, sort, deleted, duplicates |

Load-bearing defaults, all pinned by tests:

- **Unit status = vacant + occupied.** Silently drops every `reserved` unit — 22 of 70 on one real
  facility. This is legacy's rule and the reason the whole feature exists.
- **Availability = all three flags** (`vacant && rentable && available_for_move_in`).
- **Amenity→attribute derivation OFF.** New capability legacy never had; on by default would change
  which units match a climate/drive-up facet on every storEDGE site at once.

---

## Where things live

**New**
```
packages/rental-contract/sync-rules.ts             catalog, SYNC_RULE_SUPPORT, governs/rulesForArtifact
packages/rental-contract/sync-rules-resolve.ts     resolve, validate, readback, chips, fingerprint
packages/api/app/services/fms-storedge/facilities.ts   3 v2 calls + getFacility
packages/platform/.../LaneConditionsModal.tsx      per-lane modal
packages/platform/.../syncRuleControls.tsx         shared rule card / stepper / flags
packages/platform/.../syncRulesDraft.ts            the save gate (pure)
packages/platform/.../SyncHealthStrip.tsx          4 tiles
apex-app/scripts/probe-storedge-facilities.mjs     read-only probe
apex-app/docs/fms/storedge/endpoints/{companies-facilities,facilities-addresses,facilities-units-v2}.md
```

**Changed, notably**
```
syncs/fms/storedge.ts          3 new surfaces; detail/units no longer blank; discovery mode
syncs/fms/normalize/storedge.ts   normalizeStoredgeUnits/Detail/Locations + the raw allow-list
syncs/fms/client.ts            FMS_LANE_SUPPORT storedge detail+units → true; unitsNote/unitsCensus
apiSourcesController.ts        aggregateConditionEffect() → sync-status
fms-probe/probeCoverage.ts     UNFETCHED_V4_KEYS emptied
fms-storedge/verify.ts         "no list-facilities endpoint" corrected — true for v1, false for v2
```

---

## What is NOT done

1. **SECURITY.md entry** for the `raw` allow-list on a CDN-public artifact. Planned, never written.
2. **Per-facility condition counts.** `aggregateConditionEffect` sums across facilities; the
   inventory-matrix direction (Option E) would need per-location rows.
3. **A `fms-probe` lane** for the three new v2 endpoints, so they can be checked from the product
   rather than the CLI. `probe-storedge-units.mjs:50` calls this the intended follow-on.
4. **Nothing committed.** Two commits are needed — the workspace `docs/` are untracked and separate
   from `apex-app`.
5. **Never visually verified by me.** Every layout defect this session was caught by Chrys looking
   at the screen. See below.

---

## How to verify

```bash
cd apex-app
pnpm typecheck                                    # 7 packages
npx vitest run                                    # 8521 pass
cd packages/api && NODE_OPTIONS='--experimental-vm-modules' \
  npx jest --config jest.config.main.js           # 2807 pass — the env var is required
```

Live: `POST /api/v1/accounts/{id}/api-sources/{id}/sync?force=true`, then check
`packages/api/.local-storage/default/fms/client_urls/storagelyselfstorage/locations/<uuid>/`:

- `v4_api_location.json` — non-empty, with `latitude`/`longitude` (legacy left these empty on
  every storEDGE location)
- `v4_api_location_units.json` — a real array
- `grep -cE "current_tenant_id|combination_lock_number|overlock_lock_number|max_rate|managed_rate"`
  on both must return **0**

---

## Workspace notes

- Platform dev server: `pnpm dev:platform` from `apex-app` (port 9720). It dies if you delete a file
  it is watching.
- `make status` from the workspace root. `make dev` starts everything; the api holds PGlite, so
  never `kill -9`.
- Vite transform check without a browser:
  `curl -s -o /tmp/x -w "%{http_code}" http://localhost:9720/src/<path>.tsx`
- The design canvas with all five directions (A was chosen):
  https://claude.ai/code/artifact/05b5a59a-9612-4ae9-86ad-b5ad7720722e

## The lesson worth carrying

Three layout defects shipped in a row — a 576px `max-w-xl` squeezing the page, an empty location
connector card, a duplicated "Last synced" line — and **Chrys found all three by looking at the
screen** while I reported "typecheck clean, transforms clean". Compilation is not verification for
UI work. Drive a browser, or say plainly that it has not been looked at.
