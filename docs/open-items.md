# Open items

Things deliberately left undone, and why. Check here before concluding something is broken.

## 1. Location switch drops out of Checkout Settings — *unfixed, owner-gated*

Switching facility while on **Checkout Settings** lands on the location's Overview instead of
staying put.

**Cause** (full detail in [embed-and-scope.md](embed-and-scope.md#the-section-round-trip-and-where-it-stops)):
`checkout-settings` is not in the `EmbeddedNavSection` union, so `sectionFromPathname()` returns
`null`, so there is no `section` token for the shell to mirror and replay. A vocabulary gap, not
a routing bug.

**Fix shape.** Add the token in `atlas/src/lib/embedded-nav.ts` — `EmbeddedNavSection`,
`EMBEDDED_NAV_SECTIONS`, `SURFACE_TO_SECTION`, `routeForSection`, and probably
`SECTION_TO_FLAT_SURFACE` — plus the same treatment for its sibling flat surfaces (`rates`,
`payment`, `disclosure`, `reserve-settings`, `unit-grid-settings`, …), which have the identical
gap and would otherwise be fixed one bug report at a time.

**Why not done.** `atlas/CLAUDE.md`: *"Do not build or restructure the navigation. Nav structure
and section order are being settled by the design owner."* Extending the section vocabulary is
exactly that. It also wants a decision covering the whole set rather than one token.

*Correction to an earlier assessment:* this was first reported as needing a change in
`atlas/src/routes/**` (Tareq's, per the ownership table). That was the wrong file — the routes are
25-line wrappers that report nothing. The blocking owner is the design owner via the nav rule, not
the route owner.

## 2. Duplicate local Helix account — *needs one command from you*

`account_SsTtwJgWkFksSxX` ("Storagely Self Storage", created 2026-08-24) was hand-created to
match Atlas's documented test-account id, before it was established that Atlas's local database is
empty anyway and the id need not match. It has **0 websites**. The real account is
`account_FDL4h_6DC5C8Ftp` (2026-08-13), which owns `website_g_cNyzHQqzPXKsB`.

Its `atlas_companies` row is removed. The Helix account row remains — the delete was blocked by
the permission classifier — so it still appears under **Admin ▸ Accounts**:

```bash
curl -X DELETE -H "authorization: Bearer $TOKEN" \
  http://localhost:9600/api/v1/users/<userId>/accounts/account_SsTtwJgWkFksSxX
```

Leave `Storagely Demo Co` and `Lone Star Storage` alone — those come from the tracked migrations.

## 3. `atlas_fms_code_conflicts` does not exist locally

No `CREATE TABLE` in any of the 301 migrations; the only reference is a `DROP POLICY`. The FMS
code-conflict surface (`atlas/src/lib/atlas-fms-conflicts.functions.ts`) therefore errors locally.
Not hand-created — the real definition isn't in the repo to copy. See
[local-supabase.md](local-supabase.md#known-schema-gap).

## 4. Local data has no address depth

`atlas_locations.street` is empty, so derived display names fall back to the full Helix page name
(*"Clemmons Towncenter Drive"*) where production shows the road (*"Towncenter Drive"*). Two of the
four locations also have no FMS code on their Helix page, so their Checkout Settings is correctly
empty rather than broken.

Filling this needs a scrape/GBP/FMS sync run, which reaches third-party services — deliberately
not done unprompted.

---

## 5. One legacy per-location unit filter is not expressible in the scope grammar

Scoped sync rules (`packages/rental-contract/sync-rules{,-resolve}.ts`) port every legacy
per-location and per-unit filter **except one**.

`MyGarageSelfStorageLocationUnitHandler.php` splits a main site and its annex by a **substring**
of the unit type name (`search_key_custom_loc_unite_type`, e.g. keep units whose type contains
`"7th St"` at the annex and everything else at the main site). `RentalScopeUnitRule` matches
`typeToken` and `unitName` by **equality against a list**, never by substring — a deliberate
constraint (`scope-types.ts`: no operator choice, the match rule is a property of the field), and
loosening it edges the grammar toward the general filter builder `docs/workflows.md` exists to
keep it away from.

**Not urgent.** That handler is SSM, and SSM has no v4 units lane at all (`syncs/fms/ssm.ts:126`
writes `units: []`), so nothing reads a rule there yet. It becomes a real decision only when the
SSM units lane is built.

**Two shapes if it does.** Enumerate the matching type tokens into an equality list at
configuration time (no grammar change, but the list goes stale as the FMS gains unit types), or
add a `startsWith`/`contains` match to that ONE field with the operator-choice ban intact. The
first is preferable and probably sufficient.

## 6. Facilities render as UUIDs wherever the platform names one

The sync-conditions board, the exception scope readback and the facility switcher all name
facilities from `useScopeSources` → `checkout-catalog/locations`, which returns `name === code` for
a Storedge connection that enumerates from a **configured facility list**.

Documented, not new: `checkoutCatalog.ts:160-168` says the Storedge sync "enumerates from the
configured facility UUIDs and has no names lane yet" and already borrows names from the legacy v2
export when one exists. The local sandbox has neither a legacy export nor company discovery, so
every facility reads as a UUID there.

**It fixes itself** on a connection using company discovery (`normalizeStoredgeLocations` carries
`name`) or one with a legacy export. Closing it for configured-list connections means reading each
facility's `v4_api_location` artifact to build a dropdown — N reads per page load, which is the cost
that comment declined.

## 7. A facility skipped by `facility-filter` is logged and recorded nowhere

`StoredgeClient.applyFacilityFilter` (`syncs/fms/storedge.ts:711`) logs which facilities a facility
condition skipped and how many, and the parent sync's job row keeps none of it. So the board's
facility group can state what each rule is set to but never what any of them *did* — the units group
has a per-rule census and the facilities group has nothing equivalent.

The board is honest about it (no badge rather than a zero), but "my location vanished" still has
nothing on screen to point at, which is the gap the log line's own comment says it exists to close.
The fix is a `facilitiesCensus` on the parent job row, read the same way `aggregateConditionEffect`
reads `unitsCensus`.

## 9. `facility-filter` is a generic rule locked inside one provider's client

**Numbering follows creation order, not position — §8 below keeps its number because the handoffs
cite `open-items.md §8` for the rent-roll exposure.**

All five facility-grain rules are read **only** inside the storEDGE client:

```
facility-filter      -> syncs/fms/storedge.ts:756,782  (applyFacilityFilter)
facility-source      -> syncs/fms/storedge.ts
inventory-source     -> syncs/fms/storedge.ts
deleted-facilities   -> syncs/fms/normalize/storedge.ts
invalid-addresses    -> syncs/fms/normalize/storedge.ts
```

Nothing in the shared sync layer reads any of them, and `SYNC_RULE_SUPPORT` lists them for
`storedge` alone. That is correct as a description of the code and misleading as a description of
the providers, which is the confusion this item exists to remove: it is a fact about **where the
filtering was built**, not a property of SiteLink, SSM, Monument or Yardi.

**Only one of the five is genuinely portable, and it is the one operators reach for.**

| Rule | Its own words | Ports? |
|---|---|---|
| `facility-filter` | *"Sync only the facilities that match a condition — or skip the ones that do"* | **Yes, fully.** It filters whatever the facility source produced. Nothing in it needs Edge |
| `deleted-facilities` | *"Facilities the FMS has deleted"* — provenance names the `deleted` flag on the v2 facility record | Concept ports; the **signal** is Edge's. Needs a per-provider equivalent, which may not exist |
| `invalid-addresses` | *"addresses **Storable Edge has flagged** as failing validation"* | No — it consumes an Edge validation flag |
| `facility-source` | Edge's two ways of enumerating (company vs configured ids) | No — Edge feed shape |
| `inventory-source` | Edge's unit-groups vs units feed | No — Edge feed shape |

### The live case, with a name on it

`yourway-storage` (SSM) publishes four facilities, and the first is:

```json
{ "code": "001", "facilityId": "99999", "name": "Training Facility" }
```

40 units, and **legacy's own `site_locations` row for it is `Disabled`**. It is on the production
CDN today because SSM's `listLocations` publishes whatever `GetLocationList` returns and reads no
rule. On storEDGE an operator could exclude it from the board; on SSM there is no operator-facing
way to, and no code path that would honour one.

### The second-order effect: those operators see nothing about facilities at all

`syncPipeline.ts:194` — `if (!defs.length) continue` — skips a whole group when a provider has no
rule at that grain. So the **"What this connection publishes"** board renders no Facilities group
for four of five providers, under a heading that promises what the connection publishes. An
operator on SSM reads a board that says nothing about the four facilities it publishes.

The count is not even missing — it is computed and discarded. `facilityTally(manifest)`
(`syncPipeline.ts:254`) reads the manifest that already says `counts: { locations: 4 }`, and it is
only ever rendered as the location group's tally, which never renders for these providers.

### The fix, in the order it has to happen

1. **Move the filter into the shared sync layer** — out of `applyFacilityFilter` in the provider
   client and into `fmsLocationsSync`, which is where every provider's enumerated list already
   arrives. This is the load-bearing step; until it exists, adding `facility-filter` to another
   provider's `SYNC_RULE_SUPPORT` ships a dial wired to nothing, which is worse than the gap.
2. **Then** add `facility-filter` to `SYNC_RULE_SUPPORT` for each provider whose enumeration it can
   act on, and only those.
3. Render the Facilities group whenever the manifest carries a facility count, with the tally and
   no steps — so "no conditions at this grain for this FMS" is stated rather than left as an
   absence that reads as zero facilities.
4. Pair it with **§7**: that item wants a `facilitiesCensus` on the parent job row so a filter can
   say what it *did*. A portable filter with no census reproduces §7's gap on four more providers,
   so the two are one coherent change rather than two.

Not started. Found 2026-09-02 while explaining why the board shows no facilities for SiteLink and
SSM — the first answer given was that those providers "apply no operator-tunable facility
conditions", which is wrong, and this item is the correction.

## 10. `isUnitAvailable` ignores the provider on ~57 of 60 call sites, and SSM's fallback field is a constant

**Found 2026-09-02 while answering "can a visitor look up a reserved unit?". Measured on
production, not inferred. Not caused by the v4 lanes — this is the v2 path that is live today.**

`isUnitAvailable` (`packages/components/sdk/unit-data-mapping.ts`) has correct per-provider
branches. They only run when a caller passes a 4th argument, `apiType`, and **two call sites do**:

```
sdk/schema.ts:423            isUnitAvailable(unit, undefined, undefined, options.apiType)   ✓
sdk/snap-sizer-engine.ts:428 isUnitAvailable(raw,  undefined, undefined, opts.apiType)      ✓
```

Every unit card, grid and storage finder — 18 files, ~57 calls — omits it and falls through to the
generic path, `total_vacant > 0`. The two arguments they DO pass, `availableField` and
`rentableField`, are named `_availableField` / `_rentableField` in the signature and are unused, so
configuring them on a component changes nothing.

### For SSM the generic path cannot work, because `total_vacant` is a sentinel

SSM is a per-UNIT provider, so a bucket vacancy count has no meaning, and legacy publishes a
constant. Facility `004` of a live operator, from `v2_api_location_units.json`:

| `status` | rows | read as available by the generic path |
|---|---|---|
| `rented` | 482 | **482** |
| `vacant` | 188 | 188 |
| `reserved` | 3 | **3** |

`total_vacant` is **`10000` on all 673 rows** — one distinct value across the file. So the generic
path returns true for every unit, including every rented one. The `apiType === 'ssm'` branch exists
to fix exactly this (`status === 'vacant'`), and almost nothing reaches it.

### For SiteLink the shape is right and the exposure is conditional

Its `total_vacant` genuinely counts units and **includes reserved**, so a type bucket whose only
free units are held by reservations reads available on the generic path. On the probed facility
there are **0** such rows, so nothing is visibly wrong there — but 380 of 6784 measured rows across
that operator's portfolio carry `iTotalReserved > 0`, and each is a candidate. The
`apiType === 'sitelink'` branch subtracts them.

### The fix is small, and its CONSEQUENCE is the reason it is an open item rather than a patch

Every one of those components already resolves the provider — they read `location.api_type` from
the data layer and hold it in a variable or a prop (`3-column-unit-grid-v2-1/index.ts:870`,
`mini-mall-unit-card/index.ts:585`, and `const type = loc?.api_type` in several renderers). 15 of
the 18 files already reference `apiType`; the fix is to pass the value they have.

**But on an SSM site it changes what a visitor sees, a lot.** Facility `004` would go from
offering 673 units to offering 188 — a 72% reduction, and correct. That is a customer-visible
change on live websites and belongs to whoever owns those sites, not to a silent patch. It should
ship deliberately, with the operator told what the number will do.

Three files have no `apiType` reference at all and need it threaded rather than passed —
`unit-pricing-grid/render.tsx`, `storage-finder/data.ts`, `storage-finder-v2-1/data.ts`.

### The v4 half is FIXED as of 2026-09-02; the v2 half above is the part still open

Chrys chose the thorough path, so the five readers went through the contract rather than the flag
going back off. What shipped:

| Reader | Was, on a v4 row | Now |
|---|---|---|
| `isUnitAvailable` | false for EVERY unit (0 of 1610) | canonical-first — 188 of 673 on facility 004 |
| `facilityId` | the CODE `004`; SSM's API wants `100002` | `providerFacilityId` — the SSM sync now publishes `raw.site_id` |
| `unitTypeId` | `null`, with `raw.UnitTypeId` = 112 sitting there | `providerUnitTypeId` — knows `unit_type_id` / `UnitTypeId` / `UnitTypeID` |
| `quotedRate` | `null`, with `rates.standard_rate` = 187 | `readRate` reads the canonical rate map first |
| `discountId` | `null`, dropping SiteLink's `ConcessionID` | `providerDiscountId` — 14 of 14 resolve on gate-5 |
| `InternetPrice` (submit) | `false` — billed the tenant the **walk-in** rate | `internetPriceEnabled` reads both nestings |

The one that nearly slipped: `fromV2Unit` puts provider fields at `raw.x` while `fromV4Unit` puts
them at `raw.raw.x`, because it sets `raw` to the whole ROW. The first version of the fix therefore
answered `null` on v4 with the value one level down — caught by comparing 673 real units across
both lanes, not by reading the code. `providerRaw` merges the two levels, inner winning.

**Column 4, re-run against the live artifacts: 673 units, one field disagrees — `discountId`, and
it is explained.** SSM's v2 rows carry a plan id (`1`, `18`, `21`); its v4 units artifact carries
none, because SSM publishes discounts as their own artifact. Only SiteLink's submit path reads
`discountId` (`reservation-submit/sitelink/payload.ts:127`), so for SSM the cost is the resume
link's `promo` parameter and nothing that reaches an FMS. Recorded rather than fixed: publishing a
plan id on the SSM unit row is a lane change needing its own verification pass.

### The same readers were broken in the other direction on v4

This is the hinge between this item and the SSM/SiteLink lanes. The provider branches read v2 field
names that the canonical v4 shape does not carry:

```
ssm branch       unit.status                    canonical has available / availableForMoveIn / rentable
sitelink branch  total_vacant, total_reserved   canonical has vacantCount; reserved only in raw
```

So a component fed `v4_api_location_units` gets `false` for EVERY unit — measured at 0 of 1610 on
SSM. A checkout on an SSM site would go from "everything looks available" to "nothing looks
available"; both are wrong, and only the second one is safe.

That is the five-reader prerequisite recorded as item 9 in
[handoff-ssm-v4-sync.md](handoff-ssm-v4-sync.md): the readers must go through `fromV4Unit` /
`providerFacilityId` / `providerUnitId` rather than indexing the raw record. **Doing both halves in
one pass is the coherent change** — the v2 fix and the v4 fix are the same function's two callers,
and fixing one alone leaves the other reading a shape it does not understand.

`buildReservationUnit` reads raw ON PURPOSE (its docblock says so), so touching it alters what all
four providers send their FMS and needs its own verification pass. Column 4 of the SSM handoff is
the harness for it.

**Status, to be exact about which half is which** — the two are now split, and the argument above
that they wanted doing "in one pass" did not survive contact:

- **The v4 half is DONE** (2026-09-02, the table above): all five readers go through the contract,
  Column 4 re-run over 673 units with one explained difference. `buildReservationUnit` did get its
  verification pass.
- **The v2 half is NOT STARTED**: ~57 of 60 `isUnitAvailable` call sites across 18 files still omit
  `apiType`, so a v2 SSM row still reads `total_vacant: 10000` and offers every rented unit. That
  is the customer-visible 673 → 188 change, and it is still awaiting a decision — which is exactly
  why it separated from the v4 half rather than shipping beside it.

## 11. One Voyager code, two RentCafe mappings — and a rental could reach a TEST property

**Found 2026-09-03 while building the Yardi lane. FIXED in v4, still live in legacy.**

`propertyId` is what `createlead` and `getcontinueapplicationurl` take. It comes from RentCafe's
`getpropertymappings`, joined to the SOAP Voyager code. Measured live:

```
1063 mappings · 987 distinct voyagerPropertyCode
  52 codes carry MORE THAN ONE mapping — in every case a real property and a "zTest" clone
  18 of one operator's 284 PUBLISHED facilities are among the 52
```

Both integrations did `byCode.set(code, mapping)` over an unordered list, so **which property a
rental is sent to was decided by RentCafe's response order.** It fired on the first live v4 sync:
facility `400019` resolved `2002817` — `zTest - L457 - Mini Mall Storage - Embrun` — where legacy's
own run resolved the real `1986331`.

**v4 is fixed**: `indexMappingsByCode` (`fms-yardi/merged.ts`) sets aside a marked clone to break a
tie, then takes the lowest `propertyId` for determinism, and NAMES every ambiguity on the job row.
Shared by the sync client and the lead path so the artifact and the checkout cannot disagree.

**Legacy is not**, and its protection is narrower than it looks: `YardiMergedApi.php:39-41` drops
`zTest` mappings **only for one hardcoded client slug**. Any other Yardi operator on legacy resolves
by luck. Nothing here can fix that — it is a change in the other repo — but the exposure is worth a
decision: a lead created against a test property is a lost rental that looks like a completed one.

**It also corrects a measurement.** *"0 of 284 published property names contain `zTest`"* is true
and completely misleading: they contain none **because the filter removed them**. The 58 marked
mappings live in the INPUT. Measuring a filter's output cannot see the filter.

## 12. Yardi reports no currency, and 67 facilities are Canadian

**Found 2026-09-03. Recorded rather than solved, deliberately.**

67 of one operator's 284 Yardi facilities are Canadian — `country: "canada"` on the raw property,
Canadian postal codes, and legacy's own `country_id: 2` on exactly those 67. **Neither Yardi API
reports a currency anywhere**: not on the property, not on the floorplan, not on a concession.
`CanonicalUnit` carries no currency field either.

So a CAD rate and a USD rate are the same number in the same field, and a page renders both as
`$84`. Sent to a checkout it is worse.

The v4 lane now publishes `country` (which legacy overwrites with the USER's country code — `''`
on all 284) and derives `country_id`, so the signal a consumer would need is at least present. What
is missing is a decision about whether `CanonicalUnit` grows a currency, and that was explicitly
out of scope: inventing a contract field as a side effect of a sync lane is how a half-designed
field ends up in a money path.

## 13. Legacy's `total_unit` and `total_occupied` are fabricated for Yardi

**Found 2026-09-03. Not reproduced in v4, and worth knowing before reading a legacy number.**

`Floorplan/UnitCount` is the AVAILABLE count. Legacy invents the other two
(`YardiFacilitiesUnitSyncJob.php:389-394`):

```php
$total_occupied = max(1, (int) ceil($available * 0.25));   // invented
$total_unit     = $available + $total_occupied;            // invented
```

Verified against **3890 of 3890** published rows. It is SSM's `"10000"` sentinel by a different
route, and the comment above it says so out loud: *"total_unit is high enough to pass UI
thresholds."*

v4 publishes only the real `vacantCount`. The fabrication is arithmetically **inert** in every
consumer today — `isUnitAvailable` and both `availableCount` implementations test `total_vacant`
first and the fallback reduces to the same number — so nothing changes on a page. The reason it is
an open item is the legacy artifact: anything reading `v2_api_location_units.total_unit` for a
Yardi operator is reading arithmetic, not inventory.

# Security items awaiting your decision

Neither has been touched.

## 8. Legacy publishes an operator's rent roll — including gate codes — to a public CDN

**Found 2026-09-01 while building the SSM v4 lanes. Not caused by that work, and not fixed by it.**

Legacy's `FacilityExportWriter::export_location_files` mirrors SSM's `GetUnitsList` response
verbatim into `fms_api_location_units.json`, which sits on the production CDN at a **derivable,
unauthenticated URL** — the same bucket the website importer reads anonymously by design.

`GetUnitsList` is an operator-console endpoint: it returns the RENT ROLL, not a shopping feed.
Measured on one operator's five facilities, 2006 rows, fetched anonymously with no credential:

| Field | Rows carrying it |
|---|---|
| `TenantName` / `TenantFirstName` / `TenantLastName` | 1281 |
| `TenantEmail` | 1254 |
| `TenantCellPhone` / `TenantHomePhone` | 1277 / 715 |
| `TenantAddress` + city/state/zip | ~1260 |
| **`GateAccessCode`** | **1267** |
| `GateStatus` (one value is `Delinquent`) | 1265 |
| `LeaseNumber` / `LeaseStatus` | 1281 |
| `Balance`, non-zero | 997 |

All 2006 rows carry at least one. A gate access code is the physical key to a stranger's
belongings; `GateStatus: Delinquent` is a financial judgement about a named person.

**Scope.** SSM-specific, and SSM is the outlier by a wide margin. Measured on the same lane at the
other two live providers: SiteLink's raw rows carry no person-adjacent field at all (it publishes
type buckets), and storEDGE's carry `current_tenant_id` — an opaque id and nothing else. So this
is one provider's endpoint choice, not a systemic export bug.

**What v4 does about it.** The new `v4_api_location_units` lane withholds every one of those fields
by name behind an allow-list that fails closed, and asserts it: 20 live artifacts across four
facilities carry **0** of the 33 withheld keys, while the same facility's legacy artifact carries
26 of them. Twelve tests exist only to fail if any of it ever reaches the file. That protects the
v4 lane; **it does nothing about the legacy artifacts already published.**

**Why not fixed here.** Three reasons, in order:
1. The fix is in `app-storagely-io` (`FacilityExportWriter` / the SSM sync's `fms_units` export),
   which is a different repo and a different deploy.
2. It is not only a code change — the artifacts are **already on the CDN** for every SSM operator,
   so it needs a purge as well as a patch, and someone has to decide the disclosure question.
3. Neither is a call this lane's author should make quietly.

**Fix shape**, smallest first: restrict the exported `fms_units` payload to the ~14 unit fields
(the v4 allow-list in `normalize/ssm.ts` is the list, already reviewed), then invalidate and
overwrite the existing objects for all six SSM operators. Both halves are needed — a patch alone
leaves the historical copies readable.

**Reproduce it in one call** (no credential, prod CDN, replace the path):

```bash
curl -s "$CDN/v4/fms/client_urls/<apiPath>/locations/<code>/fms_api_location_units.json" \
  | jq '[.UnitDetailLists[] | select(.GateAccessCode != null)] | length'
```

## A GitHub PAT is committed in plaintext in both repos

The same `ghp_…` token is embedded in the `origin` URL in **both** `.git/config` files. Any
`git remote -v` prints it — into logs, screen shares, tool output. `make status` masks it when
displaying remotes, which reduces exposure but does not remove it.

Rotate the token and move to SSH or a credential helper.

## `atlas/.env` is tracked and holds keys

It carries `SUPABASE_*` and `VITE_LOVABLE_CONNECTOR_GOOGLE_MAPS_BROWSER_KEY`, committed to
`storagely-home-base`. Publishable keys are semi-public by design, so this may be an accepted
risk — but it sits against `apex-app`'s own credential doctrine
(`apex-app/docs/credentials.md`) and deserves a deliberate answer rather than a silent one.

Meanwhile: put local values in the gitignored `atlas/.env.local` (browser) or
`helix/.env.local` (server) — never in `atlas/.env`.

## A reminder that is not a finding

`SUPABASE_SERVICE_ROLE_KEY` **bypasses RLS.** Against the hosted project it is full read/write on
production Atlas data, and Atlas writes unprompted (`ensureAtlasCompanyForAccount` provisions
company rows for unknown accountIds). Keep it pointed at the local stack; `make status` and
`make doctor` both assert the target.
