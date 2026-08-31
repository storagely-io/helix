# HANDOFF — v4_api_location / v4_api_location_units cutover (session of 2026-08-27)

Read this first, then [docs/v4-location-cutover.md](v4-location-cutover.md) (the costed roadmap —
the deep detail lives there, not here). Companion visual (pipelines drawn as workflow-builder
node cards): **https://claude.ai/code/artifact/4e87d023-b152-4e92-939e-a28f769d785f**
— to update it in place from a NEW session, republish with `url:` set to that link; publishing
without `url` creates a separate artifact.

## How this started

Chrys asked the difference between `v4_api_locations` and `v4_api_atlas_locations`, then
progressively: can `v4_api_location` replace `v2_api_location`, what would it cost, and can we
get a visual "so we know what we are doing wrong." Context doc from the prior session:
[docs/multi-fms-api-paths.md](multi-fms-api-paths.md).

**The three near-identical keys, disambiguated** (the recurring confusion):

| Key | What it is | Status |
|---|---|---|
| `v4_api_locations` (plural) | ONE FMS connection's facility list — the v4 rebuild of `location-list.json`'s "sync driver" half | written; drives fan-out; checkout-catalog reads it with v2 fallback |
| `v4_api_location` (singular) | one facility's FMS detail — v4 successor of `v2_api_location`'s FMS-owned half | **fetched on checkout pages, read by NOTHING; `{}` on 4/5 providers** |
| `v4_api_atlas_locations` | the company-wide cross-FMS directory (thin ~968 B records, `flex_path`, rating, photo) | LIVE — default binding of storage-finder-v2-1 / nearby-v2-1 |

## What was produced (all verified; 56 claims adversarially checked by workflow, 55 confirmed, 1 fixed — test-file count is 99 not 83)

1. **`docs/v4-location-cutover.md`** — current state, legacy producer analysis, consumer
   surface (~48 of 110 v2 fields actually read, tiered), units-lane inventory + migration
   order, field-provenance → v4-home table, costed phase plan, Atlas pipeline summary.
2. **The artifact** (URL above) — 4 diagrams (legacy pipeline, v4 FMS sync, Atlas sync,
   consumer read map), 10 numbered defects, phase ladder, provenance table. Drawn in the app's
   workflow-editor idiom (user explicitly asked for "the workflow we have in the app" —
   node cards per `packages/platform/src/pages/users/workflow/nodeCards.tsx`, kind colors from
   `workflows.ts:209-217`).
3. **Plan file** (approved): `~/.claude-orgs/storage/plans/effervescent-wondering-elephant.md`.
   **Approved scope was visual + roadmap ONLY — no app-code changes were authorized.**

## The load-bearing findings (fuller versions in the cutover doc)

- **Legacy `v2_api_location.json` is a `site_locations` DB-row dump + config merge**, not an FMS
  response (`legacy: app/Services/Export/FacilityExportWriter.php:159-163`; raw PMS →
  `fms_api_location.json`). Only SiteLink syncs profile continuously; SSM/Yardi create-only;
  storEDGE creates blank rows; operator edits win on name/email/city/region even for SiteLink.
  ⇒ most "profile" fields were operator content in legacy — Atlas's lane now. The honest v4
  successor is a **union**: `v4_api_location` (FMS facts) + `v4_api_atlas_location*` (operator
  facts). Never one artifact.
- **The units lane is the proof-of-pattern**: `CanonicalUnit` (`rental-contract/units.ts:38-118`),
  `fromV4Unit`/`fromV2Unit`/`fromFmsLaneUnit`, `UNIT_SOURCES` v4-first ladder
  (`sdk/checkout-unit-context.ts:41-48`) all shipped; ladders starve gracefully (empty v4 falls
  to v2). The detail lane skipped exactly this contract step — no `CanonicalLocation`, no
  `fromV4Location`; `sdk/checkout-facility.ts:231` hardcodes v2 (and its `CheckoutFacility`
  iface `:47-132` + mapping `:273-294` is the ready-made seed for the canonical type).
- **Monument** is the only provider with real detail+units reads and it violates the naming
  rule — raw shape under the neutral key (`normalize/monument.ts:110-115` concedes it).
  `FMS_LANE_SUPPORT` in `syncs/fms/client.ts:284-364`. `probeCoverage.ts:29` is stale (still
  claims no upstream call).
- **Legacy traps found**: `zip` never existed as a legacy column; `state`/`state_name` filled
  only by engineering seeders — live apex code reads all three via fallback chains. Dead reads
  to NOT port: `street_address`, `phone_number`, `lat/lng/lon`, `contact_info.primary_phone`.
- **Three incompatible hours formats** (v2 row arrays / Monument keyed 12-hour / Atlas freeform
  v1) — no canonical hours shape exists anywhere.
- **Waitlist email lane is deliberately v2-only** (`waitlist.ts:6-19`, open-relay threat model)
  — moving it is a SECURITY.md-level change; excluded from the roadmap.

## Open decisions (Chrys's, not discoverable)

1. **Canonical hours shape** for `CanonicalLocation` — must reconcile the three formats.
2. **Monument treatment** — normalize into canonical vs move raw to a `v4_api_monument_location`
   verbatim lane first (its own comments propose the latter).

## Missing before later phases (not blockers for phases 0–2)

- **Phase 3 provider spike**: can the v4 clients' credentials/API versions reach detail/units
  endpoints per provider? (storEDGE has no upstream list endpoint; detail story unverified.)
  Legacy's sync jobs are the reference for what each PMS can supply.
- **Atlas structured hours** (the un-shipped v1.1 contract bump,
  `apex-app/docs/atlas-v4-locations-contract.md:152-162`) — cross-repo (Atlas/Lovable side).
- **Token-shim design** (~half page): alias `{v2_api_location(.*)}` / `{v2_api_location_units(.*)}`
  through the ladders in `resolvePath`; watch the whole-array tokens
  (`snap-size-guide-v2-1/index.ts:93`, `unit-size-finder-v2-1/index.ts:65`) and
  `interpolatePriceTemplate`'s prefix-stripping (`sdk/unit-pricing.tsx:56` + its documented
  inline mirror in `base/modern-unit-card-v2/render.tsx:~653-665` — must move in lockstep).

## If implementation is approved, start here (phases 0–2, all small)

- `packages/rental-contract/location.ts` — new `CanonicalLocation` (seed from CheckoutFacility;
  FMS-owned families only per the provenance table) + `fromV2Location`/`fromV4Location`.
- New `LOCATION_SOURCES` ladder (copy `UNIT_SOURCES`); first consumers `sdk/checkout-facility.ts`
  and the duplicate builder in `base/checkout/render.tsx:325-400` (collapse them).
- Extend `CanonicalUnit`/v4 normalizers with the §6 field gap from the cutover doc
  (`total_area`, `weekly_regular_rate_website`, `additional_fee`, `promo`, `climate`,
  occupancy trio, …).
- Monument compliance + truthful `FMS_LANE_SUPPORT` + fix `probeCoverage.ts:29`.
- Tests: 99 files reference the v2 key; `tests/v4-endpoints-dormant.test.ts` flips from
  "nothing reads v4" to pinning the ladder order.
- Consolidation debts to collect on the way: 5 hours/image extractor clones (facility-header
  family), 7 unit-card location blocks, 2 facility builders; units migration order is in the
  cutover doc §6 (start at `getUnitsArray`, `sdk/unit-data-mapping.ts:213` — one module behind
  14 card renders).

## Workspace gotchas for the next session

- This workspace = 3 repos; app changes go through `git -C apex-app` (pushing apex-app main
  **deploys prod** via CircleCI, no approval gate — verify prod, not just green CI; the data
  layer is tree-shaken, so correct code can ship starved).
- These `docs/*.md` are workspace-local and currently untracked; don't commit unless asked.
- Editor fetches every location key unconditionally — the editor working proves nothing about
  SSR (`data-layer-endpoints.ts:12-15`); the `needs()` tree-shake is the recurring bug class.
- Chrys wants short answers — lead with the answer, tables over prose.
