# Multi-FMS, apiPaths, and the merged-locations machinery — session findings (2026-08-26)

Everything verified while answering "will API Sources work when I add a new FMS?"
All file refs are `apex-app/` unless noted. Verified against code and prod CDN, not from memory.

## 1. The v4_api_* naming is NOT single-FMS — multi-FMS is designed in

- `v4_api_*` are **endpoint/data-layer keys (contracts)**, not tables. Storage is namespaced
  per source: `fms/client_urls/{apiPath}/locations/{code}/v4_api_location.json`
  (`packages/api/app/services/endpoints/registry.ts`). Two FMS sources never collide.
- **Naming rule** (`syncs/fms/client.ts:150-161`): no source segment (`v4_api_location_units`)
  ⇒ normalized cross-provider shape any FMS fills via `normalize/{provider}.ts`; source
  segment (`v4_api_edge_*`, `v4_api_atlas_*`) ⇒ that provider's verbatim shape, single-writer.
- 5 providers registered: `storedge | sitelink | ssm | yardi | monument`
  (`ApiSourceFmsType` in `models/types/IApiSource.ts`), dispatched by `getFmsClient()`;
  unknown type ⇒ `BlankFmsClient` (blanks, not crash). Monument is the first with real
  `detail`/`units` reads (`FMS_LANE_SUPPORT` map in `client.ts` — flip flags same commit as client).
- **Adding FMS #6** = 4 touches: type union, `syncs/fms/{provider}.ts` client + `getFmsClient`
  case, `normalize/{provider}.ts` (must emit the neutral field names — readers `fromV4Unit`/
  `fromV4Coverage`/`fromV4Catalog` depend on them), `FMS_LANE_SUPPORT` flags.
- Location `{code}` segment = provider's own stable code, lowercased (`slugifyLocationCode`).
  storEDGE uses facility UUIDs; a new FMS uses its own id format.
- CAVEAT: `v4_api_location*` endpoints are marked **dormant** in the registry — pages render
  today off the `fms_`/`v2_` keys (same apiPath/locationCode addressing).

## 2. How a page binds to an FMS (no searching, ever)

```
apiPath = page.apiPathOverride ?? website's primary apiPath   (stored config)
code    = page.locationCode                                   (stored on the page, IPage.ts:207)
fetch     fms/client_urls/{apiPath}/locations/{code}/…        (one direct URL; a miss falls to
                                                               empty — no cross-path lookup)
```

- `website.apiPaths` is an **ordered array**; `apiPaths[0]` = primary, mirrored into legacy
  singular `apiPath` (`services/websites/apiPaths.ts`). Order is load-bearing: default source,
  merge precedence (first-wins on conflicts), and the override allowlist.
- `page.apiPathOverride` (`IPage.ts:220`): must be a member of `website.apiPaths`; redirects
  ONLY `fms_`/`v2_` per-location keys + reservation/waitlist routing
  (`FMS_OVERRIDE_KEY_RE` in `packages/webpage/src/data-loader.ts:~105`). Everything else
  (locations list, atlas v4_*, blog, gbp, images) stays on primary.
- **Editor UI exists for BOTH**:
  - Website: editor Settings → API → "API Path(s)" (comma-separated, first = primary;
    `editor/src/sidebar/panels/settings/Api.tsx`; autosave 800ms; API: `updateWebsite({apiPaths})`,
    Joi at `websitesRoutes.ts:461-462`).
  - Page: editor Settings → **Data Mappings → "API Path Source"** (`ApiPathOverridePicker` in
    `DataMappings.tsx`) — picks the override AND swaps the location picker to the override
    path's `location-list.json` so you map a code that exists in that bucket.

## 3. What a second apiPath entry actually does (the honest version)

A bare second entry does **nothing visible**. It is a *declaration*, consumed by exactly:
1. Override legality — you can't `apiPathOverride` to an unregistered path.
2. The merge job includes that path's facilities in `v4_locations`.
3. Admin Merged Locations monitoring panel.

Per-page consumption is manual (`apiPathOverride`, per page). There is no auto-inference of
overrides from which bucket a page's locationCode appears in — identified as the missing
piece worth building if facility-by-facility migration becomes common.

## 4. Merged locations (`v4_locations`) — production side works, consumption dormant

- `mergedLocationsSchedulerJob` every 15 min → one `mergedLocationsJob` per website needing a
  rebuild (fingerprint sidecar + metadata-only checks skip unchanged sites; writes change-gated
  on bytes; Run now = force). Reads each apiPath's `location-list.json`, filters **Published**,
  concatenates in order (first-wins), writes
  `endpoints/websites/{websiteId}/v4_locations.json` (website-scoped; sources untouched).
- Records pass through verbatim with `client_url` + `endpoints[]` (self-namespacing provenance).
- **VERIFIED: zero components bind `v4_locations`** (grep across packages/components is empty).
  `locations-map` defaults to `dataSource: "locations"` = primary bucket only
  (`base/locations-map/index.ts:15`). Adoption today = flip the placed component's
  `dataSource` prop to `"v4_locations"` (works — SSR fetches keys named in page JSON; needs
  `websiteId`, threaded). For default adoption add a name-based trigger in
  `extractReferencedKeys`.
- Docs: `docs/merged-locations.md` (operator view), `services/locations-merge/README.md`.

## 5. The Atlas list is the OTHER cross-FMS directory — and it's the live one

- `v4_api_atlas_locations` is written by the **Atlas connector sync** (`syncs/atlasSync.ts:1542`)
  under the primary apiPath's endpoints root (`endpoints/{apiPath}/v4_api_atlas_locations.json`).
  Atlas holds ALL company locations regardless of FMS ⇒ the file is inherently cross-FMS.
- **VERIFIED prod**: `…/v4/endpoints/mini-mall-storage-yardi/v4_api_atlas_locations.json`
  = **286 records** (both FMSes), each carrying `location_code`, `flex_path`, address, rating,
  photo. (`mini-mall-storage/…` also 200 = leftover from when it was primary; french 403.)
- v2-1 components (`storage-finder-v2-1`, `facility-nearby-locations-v2-1`) bind
  `atlasLocations` to `{v4_api_atlas_locations}` **by default**, fetched unconditionally from
  primary apiPath in data-loader. So directory completeness on modern surfaces comes from
  Atlas, NOT the merge job. This deflates the "map loses migrated facilities" argument for
  multiple apiPaths — their real value is the per-page override lane (units/pricing).

## 6. Mini Mall (the live multi-path account) — verified numbers

- `website_5b-jvTg9qxCYMMz`, apiPaths: `mini-mall-storage-yardi, mini-mall-storage, mini-mall-storage-french`.
- Prod v4 CDN `location-list.json` rows: yardi **284**, legacy **3**, french **3** (=290 read).
  Merge kept **281** (279 + 2 + 0); 9 dropped = 7 unpublished + 2 conflicts; french keeps 0
  (its rows lose first-wins conflicts / unpublished).
- Admin page → Merged Locations section chips = the merge job's last run report per apiPath.
- **`location-list.json` is written by the LEGACY Flex sync** — verified: nothing in the v4
  API writes it, everything (atlas-pages, checkout-catalog, locations-merge, reservation-sync
  targets, imports fmsMirror) only reads it. So Mini Mall's three paths need **no v4 API
  Source rows** — explains "why don't we have different API sources" on the admin page.
  API Source rows exist only for what v4 itself syncs (e.g. the Atlas connector).

## 7. Design discussion outcomes

- **Rejected: `{apiPath}.v4_api_location.{code}` key prefixes.** Would bake source slugs into
  stored page artifacts/templates (FMS migration = rewrite every page; operator names in
  shipped strings), break the closed key vocabulary (`extractReferencedKeys`, `needs()`,
  registry, triggerComponents), and buy nothing the merged-artifact pattern doesn't.
  Cross-source data = rollup artifact with provenance (the `v4_locations` pattern).
- **Split lanes on one page (detail from A, units from B): not supported**; override is
  all-or-nothing per page. If needed: per-key override map for presentational keys only.
  HARD boundary: units/checkout/reservation cluster must move together — submit derives
  credentials/contract from the unit's source.
- **Multiple apiPaths: needed IFF one website spans two FMSes simultaneously** (gradual
  migration / permanent split). Whole-website cutover ⇒ single path is enough.
  Recommendation: keep multi capability, simplify UI to single-select + "add migration
  source" affordance.
- **Dropdown fed by API Sources:** right direction (kills silent-typo failure: free text
  pointing at an unsynced bucket renders empty with no error), BUT (a) must stay ordered
  multi-select, (b) Mini Mall's legacy paths have NO API Source rows so a source-fed picker
  can't reproduce today's working config — pin current-but-unlisted values, or backfill
  Source rows first; (c) keep the API contract free text (field is also Atlas-synced —
  `websitesRoutes.ts:326`).

## 8. Unresolved / parked

- **ENAMETOOLONG render error** (user hit, then we pivoted): external-images cache uses
  base64url of the FULL source URL as a directory name
  (`storageKeyFor` in `services/external-images/externalImages.ts:66`);
  long Atlas media URLs (`atlas.apps.storagely.io/api/public/cdn/location-media/{3 uuids}/…`)
  exceed the 255-byte filename limit on local disk. Fix direction: hash the URL (e.g.
  sha256 hex) for the directory segment instead of raw base64url — but note the encoded
  segment round-trips through the public URL (`/external-images/{encoded}/{file}` decodes it
  server-side, `decodeSrcUrl`), so a hash needs a lookup or the route contract changes.
- Auto-inferring `apiPathOverride` from which bucket a page's `locationCode` appears in —
  the missing automation for facility-by-facility migration.
- Backfilling API Source rows for legacy apiPath buckets (prerequisite for a source-fed picker).
