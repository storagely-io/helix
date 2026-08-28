# v4_api_location + v4_api_location_units — cutover cost map (session findings, 2026-08-27)

The question: **what does it cost to "use v4_api_location" (and `_units`) the way pages use
`v2_api_location*` today?** Everything below verified against code this session — apex-app,
the legacy Laravel repo (`../app-storagely-io`), and local artifacts. Companion visual:
the "Location Data Pipelines" artifact (published from this session).

All file refs are `apex-app/` unless prefixed `legacy:` (= `../app-storagely-io/`).

## 0. TL;DR

- `v4_api_location` is **registered, fetched (on checkout pages), and read by nothing**. 4 of 5
  providers write `{}`; Monument writes its **raw** shape into a key whose name promises a
  normalized one. There is no canonical location type and no `fromV4Location` reader.
- The units lane is the same cutover **already half-done**: `CanonicalUnit` + `fromV4Unit` +
  the `UNIT_SOURCES` v4-first ladder shipped; only provider reads (4/5 blank) and the
  non-checkout consumers remain. **Copy that pattern for the detail lane.**
- Legacy's `v2_api_location.json` is **not an FMS response** — it is a `site_locations` DB-row
  dump + client config (`legacy: app/Services/Export/FacilityExportWriter.php:159-163`). Half
  its fields were operator-entered in the legacy admin — the role Atlas owns now. So the honest
  v4 successor is a **union**: `v4_api_location` (FMS-owned facts) + `v4_api_atlas_location*`
  (operator/marketing facts), never one artifact.
- Only **~48 of the 110 v2 fields are actually read** anywhere. That, not 110, is the port
  surface.

## 1. Current state — why v4_api_location is unusable today

- **Lane support** (`FMS_LANE_SUPPORT`, `services/api-sources/syncs/fms/client.ts:284-364`):
  `detail` and `units` are `false` for storedge / sitelink / ssm / yardi — their clients write
  `{}` / blanks deliberately (`fms/storedge.ts:488-490`, `sitelink.ts:110-112`, `ssm.ts:89`,
  `yardi.ts:46-53`). Only **monument** has both `true` with real reads (`client.ts:345-350`).
- **No contract**: the payload type is `FmsLocationDetail = Record<string, unknown>`
  (`client.ts:70`). Units/coverage/catalog each got a `Canonical*` type in
  `packages/rental-contract/` before providers filled them; the detail lane skipped that step.
- **Monument's naming-rule violation** (self-declared, `syncs/fms/normalize/monument.ts:110-115`):
  `v4_api_location` has no source segment ⇒ the naming rule (`client.ts:150-161`) promises a
  normalized cross-provider shape — but `normalizeMonumentDetail` (`monument.ts:117-166`) spreads
  Monument's raw `PublicFacilityDto`: pennies-scaled rates, a keyed 12-hour `operatingHours`
  object (a **third** hours format vs v2's row arrays and Atlas's freeform v1), one-line
  `address`, image **UUIDs** not URLs. *"A consumer must not read it as cross-provider until
  one is settled."*
- **Fetched but starved**: `data-loader.ts:397` requests `v4_api_location` on the checkout
  trigger; `sdk/data-layer-endpoints.ts:60` registers it (`fallback: {}`); zero readers exist
  (repo-wide grep; `tests/v4-endpoints-dormant.test.ts` pins the dormancy).
- **Stale probe**: `services/fms-probe/probeCoverage.ts:29` still lists `v4_api_location` and
  `v4_api_location_units` in `UNFETCHED_V4_KEYS` ("no upstream call") — false since Monument.
- Every local `v4_api_location.json` is `{}` (2 bytes); the fixture seeder writes `{}`
  explicitly (`scripts/fms-fixtures/seed.ts:60`).

## 2. The legacy producer (what "legacy logic" actually is)

`legacy: app/Services/Export/FacilityExportWriter.php` is the writer of every per-location
artifact and `location-list.json`:

- `export_location_files()` (`:139-182`) writes, per location:
  - `fms_api_location.json` / `fms_api_location_units.json` / `fms_api_discounts.json` — **raw
    PMS data**;
  - `v2_api_location.json` — the **`site_locations` row** minus `EXCLUDE_COLUMNS`, plus
    `client_url`, merged with `$v2_config` (`:159-163`);
  - `v2_api_location_units.json` — `location_units` rows with nested `features` (`:166-176`);
  - `v2_api_location_discounts.json` (`:178-181`).
- `export_config()` (`:184-210`) writes `location-list.json` — the location rows with an
  `endpoints[]` file list appended per location (which is why Helix components can fetch a
  location's artifacts from `endpoints[]`).
- The per-field logic lives **upstream of the writer**: the four facility sync jobs
  (`legacy: app/Jobs/Sync/{Sitelink,Ssm,Storedge,Yardi}FacilitiesSyncJob.php`, plus
  `YardiFacilitiesUnitSyncJob.php`) upsert `site_locations` from each PMS;
  `GoogleReviewDataSyncJob.php` feeds the review aggregate; operators enter the marketing/SEO
  fields in the legacy admin; helpers compute the rest (`apply_office_hours` `:216`,
  `apply_access_hours` `:294`, from the `TenantOfficeHour` model).

**Consequence:** "port the legacy logic onto v4" is a per-field provenance question. PMS-sourced
⇒ belongs in `v4_api_location` (FMS sync normalizers). Operator-entered ⇒ belongs to Atlas
(`v4_api_atlas_location*`) — most of it already does. Computed ⇒ reimplement in the v4
normalizer or the canonical reader. §5 carries the field-by-field table.

## 3. The consumer surface (what must keep working)

~48 of 110 v2 fields are read anywhere (full inventory in this session's transcript; tiers):

- **Tier A (10+ call sites):** `site_name, phone, location_code, api_type, rating_value,
  review_count, address1, city, region, location_image`
- **Tier B (3–9):** `state, state_name, postal_code, zip, address, address2, email, reviews,
  client_url, url_slug, latitude, longitude, company_name, locations_features,
  weekday_start/end, saturday_start/end, sunday_start/end, closed_weekdays/saturday/sunday,
  access_hours`
- **Tier C (single consumer):** `public_phone, office_hours, locations_features_top, timezone,
  country, country_id, site_id, road, access_hour, location_page,
  meta.google_maps_url / meta.google_reviews_url`, review/photo sub-shapes
- **Dead reads — do NOT port:** `street_address` (5 unit cards), `phone_number`
  (storage-finder-v2-1, documented bug in its CHANGELOG), `lat/lng/lon` (`sdk/schema.ts:185-186`),
  `contact_info.primary_phone` (an Atlas shape).

Highest-leverage consumers (cut these over and most surfaces follow):

| Consumer | Reads | Note |
|---|---|---|
| `sdk/checkout-facility.ts:231-294` | 23 fields | **The widest reader and the ready-made draft of `CanonicalLocation`** — hardcodes `v2_api_location` at `:231` |
| `base/checkout/render.tsx:325-400` | ~11 fields | A duplicate inline facility builder — collapse into the above first |
| `sdk/schema.ts:139-227` | ~20 fields | SelfStorage JSON-LD |
| `sdk/directions-url.ts`, `sdk/facility-phone.ts`, `sdk/reservation-analytics.ts` | 3–9 each | shared SDK readers |
| 5 byte-identical extractor clones | hours/access/image | `facility-header/render.tsx` + 4 `data.ts` twins — consolidate to 1 module first |
| 7 unit-card location blocks | 12-field block | `mini-mall-unit-card` family + `grouped-unit-card` + `3-column-unit-grid-v2-1` |
| ~40 components | `{v2_api_location.*}` tokens | plus an **open-ended** operator-typed token surface (`sdk/template-autocomplete-input.tsx:44` offers every field) |
| API `services/locations/locationDetailFeed.ts` | 7- and 19-field projections | callers: workflows sendFrom/sendRecipients, reservations, **waitlist** |

**Do-not-move flag:** the waitlist email lane (`services/waitlist/waitlist.ts:6-19`) is
deliberately v2-only with an open-relay threat model — moving it is a SECURITY.md-entry change,
excluded from this roadmap.

## 4. The units lane — the pattern, already half-shipped

Already done (this is what the detail lane copies):
- `CanonicalUnit` (`packages/rental-contract/units.ts:38-118`);
- readers `fromV4Unit` / `fromV2Unit` / `fromFmsLaneUnit` (`units.ts:140-292`) — validating
  pass-throughs, mapping happens at sync time;
- the v4-first ladder `UNIT_SOURCES = [v4_api_location_units → v2_api_location_units →
  fms_api_location_units]` (`sdk/checkout-unit-context.ts:41-48`; copies in
  `sdk/scope-explainer.tsx:38-42`, `base/reservation/preview-unit.ts:19`);
- server-side `services/checkout/unitFeedShape.ts:13-19`, `checkoutPricing.ts:181`.
- The checkout picks v4 the moment it has data — no component changes needed there.

Remaining:
- provider `units` reads (4/5 blank; Monument real via `normalizeMonumentUnits`,
  `normalize/monument.ts:183`);
- the non-checkout consumers still bound to `v2_api_location_units` directly —
  **inventory: see §6 (finder results)**;
- the third lane `fms_api_location_units` is checkout-only and is the ONLY feed listing
  reserved units (`data-loader.ts:399-416`) — a v4 units lane must either include reserved
  units or keep this lane.

## 5. Field provenance → v4 home (the tiebreaker table)

From the legacy sweep (`legacy: app/Services/Export/FacilityExportWriter.php`,
`app/Jobs/Sync/*FacilitiesSyncJob.php`, `app/Http/Controllers/Admin/LocationController.php`).
Rule: PMS-sourced ⇒ `v4_api_location`; operator-entered ⇒ `v4_api_atlas_location*`;
computed ⇒ v4 normalizer/reader; dead ⇒ drop.

**The structural finding: per-PMS provenance differs, and the operator usually wins.** Only
SiteLink continuously syncs profile fields (30-min cadence, EventBridge →
`legacy: app/Http/Controllers/Sync/AllDispatchJobUrls.php:77-80`). SSM and Yardi write profile
fields **once at row creation** and never again; storEDGE creates rows with empty defaults —
every profile field operator-entered afterwards (`StoredgeFacilitiesSyncJob.php:104-136`). Even
SiteLink keeps the DB value when set for `site_name`, `email`, `city`, `region`
(`SitelinkFacilitiesSyncJob.php:140-165`). So legacy's own data model already treated most of
the profile as operator content — the Atlas lane is its honest successor, not a new idea.

| Field family | Legacy provenance | v4 home |
|---|---|---|
| Identity: `location_code`, `site_id` | PMS identifiers (SiteLink `sLocationCode`/`SiteID`, SSM `Code`/`Id`, Yardi `code`/`property_id`, storEDGE facility UUID) | `v4_api_location` (canonical identity) |
| Config merge: `api_type`, `client_url`, `company_name`, `checkout_version`, `is_tier_enabled`, … | `$v2_config` from the `configures`/`users` tables, merged over the row (`FacilityExportWriter.php:162`) | website/apiSource config, not any location artifact |
| Address/profile: `address1/2`, `city`, `region`, `postal_code`, `country`, `site_name`, `email` | PMS at create; SiteLink continuous for address; operator wins for name/email/city/region; storEDGE all-operator | **Atlas** for the published profile (`v4_api_atlas_location`); `v4_api_location` carries the FMS's own values where a provider supplies them |
| `phone` vs `public_phone` | `phone`: SiteLink clobbers every 30 min — `public_phone` **exists as the operator override** (migration `2025_05_08_112004`) | Atlas `contact_info`; FMS phone stays in `v4_api_location` |
| Geo: `latitude`/`longitude` | SiteLink continuous; SSM/Yardi/storEDGE **engineering-seeded by one-off migrations**, no admin UI | Atlas (already carries them); FMS lane where the provider supplies |
| Hours: `weekday_*`/`saturday_*`/`sunday_*`/`closed_*`, `office_hours[]`, `access_hours[]` | SiteLink: PMS every sync; SSM/Yardi **NULL them on every sync**; `office_hours[]`/`access_hours[]` COMPUTED from operator-entered `TenantOfficeHour` rows (`apply_office_hours` `:216`, only when `is_custom_office_hours==1`; `access_hours` `[]` when `always_accessible`) | Atlas hours (structured per-day is the un-shipped v1.1 contract bump); FMS hours into `v4_api_location` where supplied (Monument already sends them — third format, needs normalizing) |
| Reviews: `rating_value`, `review_count`, `reviews` | COMPUTED — DataForSEO Google-reviews sync every **7 days**, keyed on operator-entered `place_id` (`GoogleReviewSyncService.php:75-101`) | `v4_api_atlas_location_reviews` (already live) |
| SEO/marketing: `title`, `meta_desc`, `meta.google_maps_url/google_reviews_url`, `location_image`, `locations_features(_top)`, `road` | OPERATOR (`Admin/LocationController::data_update`; features list = hardcoded helper + per-account extras) | Atlas: `on_page_seo`, photos/gallery, amenities |
| `url_slug` | COMPUTED at create (SSM/Yardi) / operator edits; export falls back to `Str::slug(location_code)` | page/link concern — Atlas `flex_path` + the page manifest already own it |
| `discount_info` | PMS — **SiteLink only**, raw discounts JSON every sync; other PMSs use `discount_by_units` → `v2_api_location_discounts.json` | FMS discounts lane (v4 twin TBD) |
| **Flagged (legacy provenance not establishable)** | `zip` — **no such column in legacy**; `state`/`state_name` — written only by engineering seeders for location-split clients, empty on normal rows | consumers reading `zip` already fall back to `postal_code`; `state`/`state_name` readers are leaning on near-empty fields — verify before porting |

Units file (`v2_api_location_units.json`): rows are PMS-sourced `location_units` upserts per
job — **except** SiteLink `width`/`length` are operator-overridable (originals kept in
`*_original`, `SitelinkFacilitiesSyncJob.php:263-283`), nested `features` are
operator-rewritable (`LocationController::unit_features_update`), `is_rentable` is computed per
PMS, and Yardi **fabricates** `total_unit`/`total_occupied` (`YardiFacilitiesUnitSyncJob.php:389-394`).
Yardi is also split parent/child: the parent writes only `location-list.json`; a child job per
property writes the per-location files.

## 6. Units-lane consumer inventory (outside the `UNIT_SOURCES` ladder)

Four consumption classes (full detail in the finder transcript):

1. **Template tokens** (`{v2_api_location_units.*}` in component defaults): the whole unit-card
   family — 7 `modern-unit-card*` clones, 4 mini-mall-family cards, `legacy-unit-card`,
   `unit-pricing-grid`, `3-column-unit-grid-v2-1`, `location-mobile-units` — plus
   `snap-size-guide-v2-1` / `unit-size-finder-v2-1` binding the **whole array** as one token,
   and `sdk/checkout-page-search.ts:49-50` (`CHECKOUT_UNIT_QUERY`, the default rent query in
   every card). Resolution engine: `interpolatePriceTemplate` (`sdk/unit-pricing.tsx:56`) —
   which strips the `v2_api_location_units?.` prefix, **plus a documented inline mirror in
   `base/modern-unit-card-v2/render.tsx:~653-665`** that must move in lockstep.
2. **`dataSource` props** defaulting to `"v2_api_location_units"`: 14 card components, all read
   via one function — `getUnitsArray` (`sdk/unit-data-mapping.ts:213`) with the picker
   vocabulary in `UNIT_SOURCE_PRESETS`/`V2_FIELD_MAPPING` (`:73-141`). Single change point.
3. **Programmatic readers**: JSON-LD schema builders (`sdk/schema.ts:233,362` via 10 component
   `generateSchema` hooks), the snap-sizer/finder engines (`sdk/snap-sizer-engine.ts:389`,
   `sdk/unit-finder-engine.ts:381`), editor mapping panels, and four API-side copies —
   `reservation-sync/unitIndex.ts:44` (own ladder), `checkout-catalog/locationUnits.ts:133`
   (own ladder), `edge-settings/facilityTiersSurface.ts:55` (**deliberately v2-only** until
   FMS_LANE_SUPPORT unstubs), `variables/variableCatalog.ts:106`.
4. **Direct `.json` fetchers** (filename, not key): `locations-map`/`storage-finder(-v2-1)`
   lazy enrichment via per-location `endpoints[]` arrays, `snap-size-guide` standalone mode,
   `facility-header-gallery-v2-1/nearby-modal.tsx:103-108` (**index-based `eps[1]` — fragile**).
   Note the filename is also **stored data**: `location-list.json` / `v4_locations` records
   carry `…/v2_api_location_units.json` URLs verbatim in `endpoints[]`.

**Fields a v4-only future must provide beyond `CanonicalUnit`** (read outside the canonical
readers): `total_area` (read instead of `area`), `size_description`, `unit_description`,
`unit_group`, `weekly_regular_rate_website`, `additional_fee`, `promo`, `image`/`unit_image`,
`climate`, `api_response.access` + `entry_location` (drive-up detection), `floor_level`/`floor`,
`total_unit`/`total_occupied`/`total_reserved` (availability math needs the trio — `total_vacant`
alone is insufficient), `exclude_website`, `is_rentable`, `price`, provider/identity plumbing
(`unit_type_id`, `site_id`, `site_locations_id`, `is_site_link`, `concession_id`, `uuid`,
`unit_number`), the discounts join key (`location_units_id` ↔ unit `id`), and the array-shape
contract (bare array, may arrive as a JSON string, omits `status:"reserved"` rows).

**Migration order (cheapest first):** ① `getUnitsArray`/`unit-data-mapping` (one module behind
14 renders) → ② `interpolatePriceTemplate` + its inline mirror → ③ snap-sizer engine →
④ `schema.ts` + the 10 mechanical `generateSchema` key swaps → ⑤ the filename/URL layer
(incl. the fragile `eps[1]`) → ⑥ the two storage-finder mapping copies → ⑦ the 14-component
default-block tail (+ regenerate `componentSettingsSchema.ts`, data-loader name triggers) →
⑧ the four API-side copies (one of which is blocked on FMS_LANE_SUPPORT, not effort).

## 7. Costed phase plan

| Phase | Work | Size |
|---|---|---|
| **0. Contract** | `CanonicalLocation` in `packages/rental-contract/location.ts`, seeded from `CheckoutFacility` (`sdk/checkout-facility.ts:47-132`), FMS-owned field families only. Also: extend `CanonicalUnit` (or the v4 normalizers) with the §6 field gap (`total_area`, `weekly_regular_rate_website`, `additional_fee`, `promo`, `climate`, occupancy trio, …) | **S** |
| **1. Readers + ladder** | `fromV2Location` (port of `checkout-facility.ts:273-294`), `fromV4Location`, `LOCATION_SOURCES = [v4_api_location, v2_api_location]` (copy `UNIT_SOURCES`); first consumers: `checkout-facility.ts` + the duplicate builder in `base/checkout/render.tsx` | **S–M** |
| **2. Sync side** | Monument compliance (normalize into canonical, or move the raw payload to a `v4_api_monument_location` verbatim lane per `monument.ts:23-32`'s own proposal); flip `FMS_LANE_SUPPORT` truthfully; fix stale `probeCoverage.ts:29` | **S** |
| **3. Providers** | Real **detail + units** reads for storedge / sitelink / ssm / yardi, each normalizing to canonical. Per-provider upstream API work — the dominant unknown. Legacy's sync jobs (`legacy: app/Jobs/Sync/*FacilitiesSyncJob.php`) are the reference implementations for what each PMS can supply | **L / unknown, per provider** |
| **4. Consumer long tail** | Consolidate first (5 extractor clones → 1; 7 unit-card blocks → 1; 2 facility builders → 1), then swap onto the ladders; template-token shim: alias `{v2_api_location(.*)}` / `{v2_api_location_units(.*)}` through the ladders in `resolvePath` so operator-typed tokens in stored pages don't silently blank; migrate non-checkout unit consumers onto `UNIT_SOURCES` | **M–L** |
| **Tests** | 99 test files reference the v2 key (82 under `packages/components/tests/`); rewrite `tests/v4-endpoints-dormant.test.ts`; watch `checkout-location-resolution`, `location-artifact-lane-coverage`, SSR fixtures | **M** |

Sequencing note: phases 0–2 are safe now and make phase 3 land value the moment any provider
ships a real read (the ladder starves gracefully — empty v4 falls through to v2, exactly like
the units/coverage lanes today, `checkout-protection-context.ts:47-49`).

## 8. How `v4_api_atlas_location` is computed (the "under the hood" answer)

No diagram existed anywhere in the workspace before this session's artifact. Condensed pipeline
(all in `services/api-sources/syncs/atlasSync.ts` unless noted):

1. **Ingest (webhook, async):** Atlas POSTs `location-upserted` (HMAC) →
   `webhooks/topics/locationUpserted.ts` validates, lifts join keys (`fmsLocationCode`,
   `sourceUrl`), guards conflicts → upserts `atlas-locations/{accountId}/*.json`. This store is
   the only base-record source (no Atlas list API).
2. **Sync prelude:** read store → `dedupeLocationsByRenderKey` → resolve each location's real
   page path from `pages-manifest.json` → read each location's prior reviews artifact →
   build + write `v4_api_atlas_locations` (the thin list, `:1517-1560`).
3. **Per location** (`syncOneAtlasLocation`, `:1043-1417`, concurrency 4): three concurrent
   fetches — the **bundle** (photos/reviews/disclosure/promoBar/truckRental/seoBlockContent
   slots, one GET), the **detail** (amenities override-resolved by Atlas + 24 verbatim blocks),
   and **signed photos** (self-contained, writes its own artifact).
4. **Folds:** base = webhook blob → live detail wins per block → prior artifact as
   keep-last-good on failure (everything except `gallery_photos`) → `buildAtlasCheckoutSlice`
   (pure allowlist).
5. **Writes (6 concurrent):** `v4_api_atlas_location`, `_checkout`, `_units` (stub `[]`),
   `_location_faqs`, `_location_reviews`, `_location_disclosure` — plus `_location_photos`
   from step 3.

## 9. Related docs

- `docs/multi-fms-api-paths.md` (this directory) — apiPaths, merged locations, the Atlas list.
- `apex-app/docs/merged-locations.md`, `services/locations-merge/README.md` — `v4_locations`.
- `apex-app/docs/fms-provenance.md` — the sync manifest / provenance guard.
- `apex-app/services/api-sources/README.md:42-74` — the (generic) sync architecture sketch.
