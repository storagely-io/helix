# HANDOFF — SP-1261, the `unit_group_tier_rates` cross-check

Session of 2026-08-28. Successor to [docs/handoff-discount-lane.md](handoff-discount-lane.md),
whose audit table listed this as the highest-value remaining item.

**Uncommitted, in `apex-app`.** The discount lane before it is committed as `3d5d52d2` on
`feat/sync-conditions-and-email-verification` and pushed to that branch — **not** to `main`, so
no prod deploy has happened. (The predecessor doc said "nothing pushed"; that is no longer true
and it has been corrected in place.)

---

## The problem

`raw.tiered_rate` on the storEDGE **units** endpoint is not authoritative. It has been observed
to outlive the tiering it describes — a facility switched tiered pricing off and the feed kept
returning the old tier price (SP-161). v4 published that number straight through, in two places
at once:

- `rates.tiered_rate`, which `sdk/checkout-base-rate.ts` starts its resolution chain at; and
- `rates.web_rate`, because `full-ladder` lets the tiered rate win the ladder.

Legacy solved it and called it SP-1261: fetch `GET /:facility_id/unit_group_tier_rates`, group by
`unit_group_id`, and match each unit on its own `tier.id`
(`StoredgeFacilitiesSyncJob.php:151-159`, `:336-357`). v4 had the HTTP client
(`fms-storedge/unitGroups.ts:64`) with **zero call sites**.

Worth noting: `rate-source`'s `full-ladder` blurb already **promised** this — *"the tiered rate
confirmed against the tier-rate table before it is trusted"*. The contract text was ahead of the
code.

---

## What shipped

### The read

`TIER_RATES_SURFACE` in `syncs/fms/storedge.ts` — v1, page-paged like its neighbours.

**Read against `unitsFrom`, not `code`** — the opposite of the discount lane, one field over, and
the reason is the mirror image. A tier rate is keyed by `unit_group_id`; under
`inventory-source: borrow` the units carry the *lender's* group ids, so reading the borrower's
table would match nothing and report every borrowed unit unconfirmed. It is also right on the
merits: this is a correction to a number the lender's FMS returned, not a promise the borrower is
making.

**It is never written to an artifact**, and that is deliberate. Every other Edge collection here
becomes a CDN-public `v4_api_edge_*` file. A tier-rate row is the operator's rate card and nothing
else — no name, no identity content — and `edgeUnitGroups.ts` already reduces the unit-GROUP row
to an allow-list for exactly that reason. Its rows reach `rates.tiered_rate` on units that already
publish a price, and stop there.

### The one thing to not break

**An unreadable table is not an empty one.** Storedge answers a bad credential with HTTP 401 *and
a well-formed empty collection*, and there is a 200-shaped version of the same thing
(`meta.error_code` on an empty body — `emptyCatalogNote`'s "soft refusal"). If those ever collapse
into "the facility runs no tiers", a rotated key drops the tiered rate off **every unit on every
facility** in one run, with no error anywhere.

So `FmsCollectionResult` gained `incomplete?: true`, set by `readCollection` on every non-clean
exit *including* a suspect empty. The call site passes `null` rather than an index when it is set,
and `normalizeStoredgeUnits` skips the check entirely on `null`. `unavailable: true` reaches the
job row so the silence is legible.

`incomplete` is genuinely useful information the pipeline was throwing away; every other consumer
writes rows to an artifact and only needs the note, so this is the first caller that had to care.

### The rule

`tier-rate-confirmation` — unit scope, governs `v4_api_location_units`, sits directly under
`rate-source` in the catalog (a test pins that adjacency).

| Mode | Does | |
|---|---|---|
| `trust-feed` | unconfirmed units keep the feed's tiered rate; the census counts them | **default — legacy-exact** (legacy kept the value and only logged `[tier_rate_unmatched]`) |
| `untier` | an unconfirmed tiered rate is not published: `tiered_rate: null`, `rank: null`, ladder falls back to managed/standard | the answer for a facility that switched tiering off. **Prices can fall** |

A **matched** rate always wins, in both modes — that is a correctness fix, not a policy, and it is
what the `full-ladder` blurb already claimed. The rule only decides the *unmatched* case.

Two modes rather than a fifth `rate-source` mode: which rate wins and what to do when the table
cannot confirm it are orthogonal, and folding them would need one mode per combination.

### Three decisions inside the check

1. **It runs under `standard` and `managed-overrides` too**, not only `full-ladder`. Those modes
   keep the tiered rate out of the *ladder* but the artifact still publishes the *field*, and
   legacy's own comment is explicit: *"several checkout blade templates read tiered_rate directly
   as the displayed price, so it must not be left holding StorEdge's raw/possibly-stale
   units-endpoint value."* It skips `no-tiering`, which has already nulled the field.
2. **It does not touch the CHANNEL rate**, which still wins `web_rate`. `rate-source: no-tiering`
   *does* ignore the channel, and the asymmetry is the point: that mode is a blanket statement
   about the facility, this is a per-unit finding about one field. SP-1261 never said the channel
   rate was stale, and legacy resolved `$web_rate` independently of its tier block. Pinned by a
   test so it reads as a decision rather than an oversight.
3. **`raw.tiered_rate` stays the feed's verbatim value** beside a corrected `rates.tiered_rate`.
   `raw` is what the provider said, `rates` is what we resolved — the distinction `no-tiering` has
   drawn since the lane shipped, and it is what lets a reader see the drift.

### The join is deliberately narrower than legacy's

Legacy read the tier key as `tier_rate['tier_id'] ?? tier_rate['id']` (`:346`) — itself evidence
nobody was sure of the shape. That fallback is **not** carried over, and the probe settles the
argument: `id` is the tier-rate ROW's own uuid, so comparing it to a unit's tier id could only
match by accident, and an accidental match applies a rate belonging to some other tier.
`indexTierRates` accepts a nested `tier.id` instead — not observed in the wild, kept as a cheap
fallback because one facility on one API version is a narrow sample.

---

## The shape is MEASURED — probe run 2026-08-28

`scripts/probe-storedge-tier-rates.mjs` (new; read-only, one signed GET per collection) read both
sandbox facilities. **The join keys are confirmed and the implementation matches them.**

| Facility | Tier rows | Groups | Tiered units | Join |
|---|---|---|---|---|
| `25e2ece8…` | 24 | 8 | 70 / 70 | **70 confirmed, 0 differ, 0 unmatched** |
| `c93036ab…` | 0 | 0 | 0 / 70 | tiering off, and the feed agrees |

Those are the two halves of the contrast the rule exists to tell apart, and both are clean.
**Neither reproduces SP-161's stale value**, so on this sandbox the correction is a verified
no-op — the lane's value here is the unconfirmed count, not a corrected rate. That is also the
strongest available evidence that `trust-feed` as the default changes nothing.

### Three fields the endpoint doc never mentioned

The reconstructed example had four fields. The real row has seven.

| Field | Why it matters |
|---|---|
| `base_tier` | boolean, true on 8 of 24 — one per unit group. Not read |
| `channel_rate` | a per-tier channel **modifier** (`amount`, `modifier_type: "$"`), not a rate |
| `max_rate` | a rate **ceiling**. Null across the sample |

`max_rate` is the sharpest confirmation that this must not become an artifact — the units
allow-list already withholds that field by name as *"a ceiling that is never displayed"*.

`channel_rate` is deliberately not read, and that is measured rather than assumed: on all **20**
units carrying a channel rate, `unit.channel_rate.rate === tierRow.rate + tierRow.channel_rate.amount`
exactly, zero mismatches. The units lane already resolves it into `rates.web_rate`. Re-deriving it
here would be a second implementation of a number we have — the Layer-A/Layer-B divergence this
whole area exists to remove.

Both the endpoint doc and the probe's `DOCUMENTED_FIELDS` set now record all seven, so the next
run flags the next unknown rather than these.

### The 401 that was not a bad credential

The probe's first run failed `HTTP 401 error_code=2 — Invalid OAuth Request`, and the unmodified
`probe-storedge-units.mjs` failed identically — which looked like conclusive proof the vendor key
in `packages/api/.env` was stale. **It was not.** That file is CRLF with quoted values, and
`set -a; . packages/api/.env` keeps both, so the request signed with `"0fOd…ptz0"\r`. dotenv
strips both, which is why the API and legacy were unaffected.

The tell is the length: a storEDGE consumer key is 40 characters, and the shell reported 41.
Now written up in [troubleshooting.md](troubleshooting.md) under the outward-facing symptom, and
in the probe script's own header — the existing entry only described it as "a `.env` value is set
but the app disagrees", which is not what this looked like from the outside.

## Files

| File | Change |
|---|---|
| `rental-contract/sync-rules.ts` | `tier-rate-confirmation` rule; `full-ladder` blurb now points at it; header paragraph on why a per-facility table does not break rule purity |
| `rental-contract/sync-rules-resolve.ts` | chip short-labels for the two modes |
| `syncs/fms/normalize/storedge.ts` | `indexTierRates`, `TierRateIndex`, `TierRateCensus`, the cross-check in the rate block, `UnitRuleCensus.tierRates` |
| `syncs/fms/storedge.ts` | `TIER_RATES_SURFACE`, the read at `unitsFrom`, `incomplete` on five `readCollection` exits, `emptyCatalogNote` → `{ note, suspect }`, `tierRatesNote`, census lines |
| `syncs/fms/client.ts` | `FmsCollectionResult.incomplete`; `unitsCensus.tierRates` |
| `docs/fms/storedge/endpoints/unit_group_tier_rates.md` | corrected — it said *"not used by legacy"*, which is wrong; plus who reads it here and why it is not published |
| `scripts/probe-storedge-tier-rates.mjs` | new |

**Tests**: `packages/api/__tests__/services/api-sources/fmsStoredgeTierRates.test.ts` — 26 tests,
with the fixture row mirroring the probe's captured shape field for field.
Root-suite guards updated: `tests/fms-sync-rules.test.ts` (units-lane count 14 → 15, catalog
adjacency, the default-mode argument) and `tests/api-source-sync-pipeline.test.ts` (19 → 20
conditions; `narrowing` stays 4 — the rule narrows nothing at its default).

No UI change was needed: the board and the connector card both read the rule catalog through
`rulesForArtifact`, so the new card renders itself and collapses at its default.

---

## Verification

All three gates, run after the change:

```
npx vitest run                      450 files, 8642 passed, 2 skipped
packages/api jest --config jest.config.main.js --maxWorkers=1
                                    228 suites, 2904 passed, 2 skipped
pnpm -r --if-present typecheck      7/7 clean
```

The root suite caught two drift guards this session (the units-lane rule count and the pipeline
summary total). That is the third session running in which `packages/api`'s jest suite alone
would have shipped a gap — the guards live in the ROOT vitest suite.

`packages/rental-contract` was rebuilt (`pnpm --filter @storagely/rental-contract build`). Restart
the dev servers before eyeballing the board, or the platform renders the old catalog.

---

## Where to pick up

0. ~~**SiteLink `detail` + `units`**~~ — done, and it turned up a bigger problem than the missing
   lanes: no SiteLink call had ever succeeded from v4 at all. See
   [handoff-sitelink-v4-sync.md](handoff-sitelink-v4-sync.md).
1. **`label` on the endpoint registry** — finishes the Atlas connector card (see the predecessor
   doc). ~20 endpoints, a server change.
2. The rest of the audit table in [handoff-discount-lane.md](handoff-discount-lane.md): unit-group
   counts, amenity → `FeatureSetting`, `slug`/`url_slug` and the three hours formats.
3. **Watch the first real run's census on a live operator.** The sandbox has no stale tiered
   rates, so `corrected` and `unconfirmed` are both 0 there and the correction has never actually
   fired. A non-zero `CORRECTED` on the job row is the first evidence SP-161 is still live; a
   facility reporting `unconfirmed` in bulk is the candidate for `untier`.
4. Nothing here is committed. Two repos, two commits, never one — and `atlas/` pushes to
   `storagely-home-base`.
