# HANDOFF — the storEDGE discount lane (`v4_api_location_discounts`)

Session of 2026-08-27, late evening. Successor to
[docs/handoff-sync-pipeline-ui.md](handoff-sync-pipeline-ui.md), which shipped the board this
session's new rule renders on.

Approved design for the card redesign:
<https://claude.ai/code/artifact/11f92d10-169a-47c3-914e-0132e4cca500> — **direction A** is what
was built; B–E record the four not taken.

**Everything is still uncommitted, in `apex-app`.** Nothing pushed. Pushing `apex-app` main
deploys prod via CircleCI with no approval gate.

---

## Why this session happened

Chrys asked how legacy's `StoredgeFacilitiesSyncJob.php` compares to what v4 actually built. The
audit came out **20 of 43 conditions built, 23 not** — and the misses clustered rather than
scattered. The whole discount lane was absent: `fms-storedge/discountPlans.ts` existed as an HTTP
client with **zero call sites**, and `rental-contract/discounts.ts` said so in its own header
(*"there is no v4 twin because no provider client syncs discounts yet"*).

This session built that lane end to end.

### The audit's other findings, NOT addressed here

Kept out deliberately — folding them in would have put unrelated corrections in one change:

| Gap | Where | Note |
|---|---|---|
| ~~**SP-1261 tier-rate cross-check**~~ | — | **Done** — see [handoff-tier-rate-crosscheck.md](handoff-tier-rate-crosscheck.md) |
| ~~**SiteLink has no discount lane**~~ | — | **Done** — and `detail` + `units` with it. [handoff-sitelink-v4-sync.md](handoff-sitelink-v4-sync.md) |
| Unit-group counts | `total_unit` / `total_available_unit` / `occupancy_percentage` / `vacancy_count` | Legacy read them from the group endpoint; v4 publishes none |
| Amenity → `FeatureSetting` auto-create | legacy `:456-504` | v4 keeps raw names in `features[]`; no key derivation, no icon defaults, no label refresh |
| `slug` / `url_slug`, office + access hours | legacy `:670-673` | Not in the detail lane. Three incompatible hours formats still unresolved |

---

## What shipped: the lane

`v4_api_location_discounts` — canonical, **not** `v4_api_edge_*`. The registry convention is real:
`v4_api_edge_*` is a verbatim provider shape, `v4_api_location*` is normalized and cross-provider.
`CanonicalDiscount.id` was already typed cross-provider ("SiteLink `ConcessionID`, Storedge
discount-plan id, SSM discount id").

### The one decision worth re-reading before changing anything

**The rows are UNIT-scoped even though the source is not.** storEDGE keeps a discount on the PLAN
and attaches it to unit GROUPS. A plan-scoped artifact would be smaller and tidier — and unreadable
by everything in the repo on the day it shipped, because `readDiscountArtifact`,
`discountSchedule`, `pendingDiscount`, `findDiscount` and every unit card's `discountsSource` read
legacy's row shape.

So the fan-out happens at **sync time**, which buys the thing a plan-scoped file cannot have:
`discounted_rate` is priced against **the unit lane's own resolved `web_rate`**. A unit's published
price and its published discount cannot disagree, because there is one derivation. Legacy had two
rate resolutions in one job and the discount half never learned about SP-1261.

Cost: rows = units × plans-on-their-group. ~200 for a 70-unit facility with three plans — the size
`v2_api_location_discounts.json` already is in production.

### Two sources, and which one wins

| Source | Gives | |
|---|---|---|
| `GET /:facility_id/discount_plans` | the plan catalog **plus** `turned_on`, `hide_from_website`, `move_in_only`, `existing_tenant_only`, dates | **Authoritative, including its silence** |
| `unit_groups[].discount_plans` embed | the group→plan association, which the facility endpoint does not carry (`facility_ids` names facilities) | Only used for plans the facility endpoint never returned |

**The bug the tests caught:** the embed carries neither `deleted` nor `hide_from_website` nor
`turned_on`, so an embed row for a plan the rule had just dropped sailed straight through
`visible()` on the strength of fields it does not have. The `known` set fixes it — a plan the
facility endpoint returned and the rule dropped stays dropped.

### The rule

`discount-visibility`, **its own scope** (`SyncRuleScope` gained a third value), governing
`v4_api_location_discounts`.

| Mode | Does | |
|---|---|---|
| `active` | drops `deleted` only | **default — legacy-exact** (`StoredgeFacilitiesSyncJob.php:250-253` filtered on nothing else) |
| `website-visible` | also drops `hide_from_website` / `turned_on: false` | the operator's own answer to "should a tenant see this?", which legacy could not see |
| `all` | publishes deleted plans | for diagnosing a promotion that vanished |

It has its own scope rather than folding into `location` because the board titles each group by
scope, and "Facilities" over a rule about which *promotions* publish reads as a rule about which
*facilities* sync.

### Known gap: borrowed inventory

Under `inventory-source: borrow`, units carry the **lender's** `unit_group_id` while groups are
read for the **borrower** — nothing matches, every unit lands on its empty default row. That is the
right fail-closed answer (no promotion promised the borrower's FMS would not honour at move-in),
but it is indistinguishable from "runs no promotions", so the census note names it explicitly.

---

## Files

**Server**

| File | Change |
|---|---|
| `rental-contract/sync-rules.ts` | `discount-visibility`, `v4_api_location_discounts` artifact, `'discount'` scope, storEDGE support |
| `rental-contract/discounts.ts` | header corrected — two lanes, one row shape |
| `syncs/fms/normalize/storedge.ts` | `normalizeStoredgeDiscounts` + `priceDiscountRow` + `DiscountRuleCensus` |
| `syncs/fms/storedge.ts` | `DISCOUNT_PLANS_SURFACE`, the fetch, `discountCensusNote` |
| `syncs/fms/client.ts` | `discounts` lane + `FMS_LANE_SUPPORT` (storEDGE only) |
| `syncs/fms/{sitelink,ssm,yardi,monument}.ts` | `discounts: []` |
| `syncs/fmsLocationSync.ts` | guarded write + `discountsNote` on the job row |
| `endpoints/registry.ts`, `location-artifacts/artifactLanes.ts`, `imports/fmsMirror.ts` | registration |
| `checkout/checkoutDiscountFeed.ts` | **v4-first ladder** with `hasRows` — falls through on an EMPTY v4, not just a missing one |

**Consumers** — the half that is easy to forget, and the reason to check prod not just CI:

| File | Change |
|---|---|
| `webpage/src/data-loader.ts` | v4 added to the checkout trigger. Without it the server preferred v4 while the browser read v2 — the promo divergence `checkoutDiscountFeed` warns about, vintages swapped |
| `components/sdk/data-layer-endpoints.ts` | key registered while still dormant, per that file's own rule |
| `editor/src/sidebar/panels/endpointUrls.ts` | human label |

**Tests**: `__tests__/services/api-sources/fmsNormalizeStoredgeDiscounts.test.ts` — 19 tests,
several asserting *through* the contract readers rather than against the literal object, because
those readers are the only reason the row shape was chosen.

---

## The card redesign (direction A)

`ApiSourceSyncTree.tsx` — the FMS connector card's `Produces` inventory. Three bands on two
different distinctions:

- **Scope** separates band 1 from bands 2–3 (once per connection vs per facility).
- **Ownership** separates band 2 from band 3, read off the key prefix (`isEdge`). `v4_api_location*`
  is normalized here and read by the website; `v4_api_edge_*` is Storable's shape kept for
  reference. That distinction decides what an operator does next and was previously legible only by
  squinting at fifteen keys for an `_edge_` infix.

`LaneRow` inverted — **label leads, key trails**. Tones are the pipeline board's `GROUP_TONE`
(teal connection-wide · navy ours · violet theirs) so the two halves of the page read as one system.

**Deleted:** `CollapsedLanes` ("+ 6 more Edge lanes" — it said the hidden rows were the boring ones
when what is true is that they are somebody else's shape), `GroupHeading`, and the `PRIMARY` set.
Nothing is hidden now; fifteen rows at 5px gaps is shorter than the collapsed version was, because
the note no longer wraps.

### The Atlas card got half of it

`ApiSourceDetailPage.tsx:568` branches — `LocationSyncLanes` for the FMS location sync, a generic
inline list for **every other connector including Atlas**. `Band` is now exported and used by both.

**What did not transfer, and why it is not laziness:** `ApiSourceEndpoint` is
`{ key, scope, description? }` — **no `label`**. Direction A leads with a short bold label; Atlas
has only whole sentences from the endpoint registry (*"Atlas v4 — one Atlas location's FAQ list
(written per-location by the atlas sync)"*). Leading with one of those puts a sentence where the
FMS card puts a word.

**To finish it:** add `label` to the endpoint registry entries and carry it through the connector
contract — a server change across ~20 endpoints, after which both cards render identically.

---

## Verification — read this before you trust a green run

**`packages/api`'s jest suite is not enough.** This repo keeps its drift guards in the **root
vitest suite**, and running only the API's tests missed four real wiring gaps this session:

```bash
cd apex-app && npx vitest run          # 8641 tests — the drift guards live here
cd packages/api && NODE_OPTIONS='--experimental-vm-modules' \
  npx jest --config jest.config.main.js --maxWorkers=1   # 2881 tests
pnpm -r --if-present typecheck
```

The four it caught, every one of which would have shipped:

1. `tests/api-source-sync-tree.test.ts` — the lane row was missing from the hand-maintained list
   (the file's own docblock warns about exactly this).
2. `tests/data-layer-link-coverage.test.ts` — no human label; the key would have rendered raw.
3. `tests/location-artifact-lane-coverage.test.ts` — the checkout-trigger key set.
4. `tests/fms-sync-rules.test.ts` — rule/artifact/scope counts.

Also: **rebuild the contract dist** after touching `packages/rental-contract` —
`pnpm --filter @storagely/rental-contract build` — and restart both dev servers, or the platform
renders stale rules and the API runs an old lane flag.

---

## Where to pick up

1. ~~**SP-1261**~~ — done. [handoff-tier-rate-crosscheck.md](handoff-tier-rate-crosscheck.md).
2. **`label` on the endpoint registry** — finishes the Atlas card.
3. The rest of the audit table at the top.
4. Two repos, two commits, never one — and `atlas/` pushes to `storagely-home-base`.

**Correction to this doc's own premise:** it says "everything is still uncommitted, nothing
pushed". That was true when it was written. The lane landed as `3d5d52d2` on
`feat/sync-conditions-and-email-verification`, which is pushed — to that branch, **not** to
`main`, so no prod deploy has happened.
