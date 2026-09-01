# HANDOFF — the SSM v4 location + unit + discount sync

Session of 2026-09-01. Successor to
[docs/handoff-sitelink-v4-sync.md](handoff-sitelink-v4-sync.md).

**Uncommitted, in `apex-app`, on `feat/sync-conditions-and-email-verification`.** Nothing pushed.
Pushing `apex-app` main deploys prod via CircleCI with no approval gate. The reservations /
`checkout-destination` work in that tree is somebody else's and was not touched.

SSM was the last provider with a stubbed units lane. storEDGE, Monument, SiteLink and now SSM all
publish one; **Yardi is the only one left**, and it is entirely stubbed.

---

## Two things before anything else

### 1. Legacy publishes an operator's rent roll — gate codes included — to a public CDN

Not caused by this work and not fixed by it. Full writeup and fix shape in
[open-items.md §8](open-items.md). The short version: legacy mirrors SSM's `GetUnitsList` verbatim
into `fms_api_location_units.json`, which is CDN-public at a derivable URL, and that endpoint
returns the RENT ROLL. Measured on one operator's five facilities, 2006 rows, fetched anonymously
with no credential:

**1281 tenant names · 1254 email addresses · 1277 mobile numbers · 1263 home addresses ·
1267 `GateAccessCode`s · 1265 `GateStatus` values (one is `Delinquent`) · 997 non-zero balances.**

All 2006 rows carry at least one. It is SSM-specific: on the same lane SiteLink's raw rows carry no
person-adjacent field at all and storEDGE's carry only an opaque `current_tenant_id`.

The new v4 lane withholds all of it by name and proves it (0 of 33 withheld keys across 20 live
artifacts). That protects the v4 lane and does nothing about what is already published. **Needs a
decision, in the other repo, plus a CDN purge.**

### 2. The SSM lanes have been writing to a directory nothing reads

`normalize/ssm.ts` keyed each location on SSM's numeric `Id` (`99999`) rather than its
operator-facing `Code` (`001`). Every consumer resolves a facility's artifacts by `Code` — it is
what legacy stores as `location_code`, what its `location-list.json` enumerates, and what an
operator's Atlas `fields.fms_location` holds. So the `insurance` and `catalog` lanes, which have
been succeeding in production, were publishing to `…/locations/99999/` while every reader looked in
`…/locations/001/`, and the ladder fell silently through to the v2 lane.

The stated reason for choosing `Id` was that `Code` looks like `"LOC/7750"` and the slash would
split the storage key. **That value is a synthetic fixture** from
`docs/fms/ssm/endpoints/GetLocationList.md` ("real field shape, synthetic values"). Measured
against production: **0 of 236 real SSM location codes across six operators contain a slash.**

This is the mirror image of the SiteLink headline. There, the flags were honest about the code and
wrong about the outcome because nothing had ever succeeded. Here everything succeeded and landed
somewhere nobody looks. Symptom → cause is now in
[troubleshooting.md](troubleshooting.md#an-fms-lane-syncs-green-and-the-website-shows-nothing--check-the-folder-name).

**It also poisoned the import mirror, which is how it was found.** `imports/fmsMirror.ts`
enumerates from the source's own `v4_api_locations`, so it looked for legacy's `v2_*`/`fms_*` files
under `99999`, found none, and reported a clean import having mirrored **zero** legacy artifacts.
The prompt's premise that an import gives "half the verification corpus for free" failed for the
second operator running — for a completely different reason than on Gate 5.

### 3. This lane is NOT safe to route a checkout or reservation through yet

The three column comparisons below all compare the ARTIFACT, field by field, and all three are
clean. That is a different question from whether the code that READS the artifact agrees, and it is
not.

`checkout/checkoutUnitFeed.ts:28` tries `v4_api_location_units` **first** and falls through only
when it is EMPTY. It has been empty for every SSM facility, which is why nothing has surfaced. The
moment a page pulls this lane in, five consumers switch onto v4 rows — and they read a row RAW,
with the v2 lane's field names. Measured on 1610 published units across four facilities, comparing
what each consumer ANSWERS from a v4 row against the same unit's v2 row:

| Consumer read | from v2 | from v4 |
|---|---|---|
| `providerFacilityId` → SSM `FacilityId` | `100002` | **`004`** → `Number("004")` = **4**, a different facility |
| `unitTypeId` → `SaveReservationDetails_WEB` | `"112"` | **`null`** → sends `UnitTypeId: 0`, which SSM refuses |
| `discountId` (the unit's concession) | `"1"` | **`null`** |
| `quotedRate` (`readRate` indexes the row) | `187` | **`null`** |
| `isUnitAvailable(apiType:"ssm")` reads `unit.status` | 493 of 1610 available | **0 of 1610** |

**A compatibility block carrying the v2 spellings was built, measured clean, and then removed on
Chrys's call** — and the reasoning is worth keeping, because it is the right one: mirroring the old
vocabulary makes five wrong readers accidentally right, inside a NEW artifact whose whole purpose is
that consumers read it canonically. Nothing routes through this lane today, so the fix belongs with
the readers, when something does.

So the gap is **deliberate, measured, and recorded in three places** rather than hidden:

- a `describe` block in the test suite that FAILS if anyone re-adds a v2 spelling, naming the five
  call sites to fix instead;
- a section in `normalize/ssm.ts` headed *"This artifact is NOT SAFE to route a checkout or
  reservation through yet"*, with the table above;
- open items 9–11 below.

**Nothing on any SSM site reaches it today** — verified per operator in *Who could reach this*.

**Two of the five are provider-independent** (`readRate`, `discountId`), and SiteLink already
publishes a non-empty units artifact in production — so that provider may be exposed today. Not
checked; open item 10.

---

### Who could reach this — all six SSM operators

| Operator | prod v4 sync writes locations | v4 website | Reachable? |
|---|---|---|---|
| `yourway-storage` | 4 | 11 pages | **no — all 11 checked for a checkout or `reservation` component** |
| `storage-star` | **0 entries** | 232 pages | moot — no units artifact to read. *(115 facilities in legacy and 0 enumerated is its own finding — pre-existing, not caused or fixed here)* |
| `my-garage-self-storage` | 24 | 1 page, `page/map`, `hasApiPath: false` | no |
| `smart-self-storage-ohio` | 1 | none | no |
| `ssmdemo` · `testing-for-mock-up` | no v4 sync | none | no |

The two mechanisms that would arm it, both checked: `webpage/src/data-loader.ts` adds
`v4_api_location_units` to the browser data layer **only** on the checkout-component trigger (so
unit grids and size finders keep reading v2), and the native reservation path
(`POST /websites/{id}/reservations`) has exactly one caller — the `reservation` component. The unit
grid's Reserve button goes through `sdk/reservations.ts` to a **thin proxy onto legacy's
`reserveunit-async`**, which reads no artifact at all.

---

## What shipped

Three lanes, real: `v4_api_location`, `v4_api_location_units`, `v4_api_location_discounts`.
`FMS_LANE_SUPPORT.ssm` now reads `detail/units/insurance/catalog/discounts: true`.

| Lane | Reads | Note |
|---|---|---|
| detail | `GetLocationList`, the facility's own entry | the ONLY facility descriptor SSM publishes |
| units | `GetUnitsList` + `GetAllUnits` | physical-unit grain, flags/features/tier joined on |
| discounts | `GetAllDiscounts` per unit type, `GetUnitTypeDiscounts` as a fallback | fanned onto the units, priced off the units lane's own standard rate |

Unit rows are **canonical only** — no v2 field spellings. See headline 3 for what that costs and
why it is the right cost.

No new artifact lane, so none of the six hand-maintained registration lists needed touching —
`endpoints/registry.ts`, `location-artifacts/artifactLanes.ts`, `imports/fmsMirror.ts`,
`webpage/src/data-loader.ts`, `components/sdk/data-layer-endpoints.ts`,
`editor/src/sidebar/panels/endpointUrls.ts` are all unchanged.

### The GRAIN decision: a row is one PHYSICAL unit

Confirmed with Chrys before any code was written. SSM is the second provider on this grain after
storEDGE (SiteLink publishes type buckets, Monument unit groups). Four independent confirmations:

1. **Legacy keys on the unit.** `LocationUnit::updateOrCreate(['unit_id' => $un['UnitId'], …])`
   (`SsmFacilitiesSyncJob.php:317-322`) iterating `GetUnitsList`'s `UnitDetailLists`. 2006 raw rows
   over five facilities, one per rentable unit.
2. **The consumer already knows.** `unit-data-mapping.ts:453` branches on `apiType === 'ssm'` and
   answers availability from `status === 'vacant'` alone. A bucket has counts, not a status.
3. **It is the id the FMS rents.** `checkout-submit/ssm/quote.ts:18` sends
   `Number(providerUnitId(unit))` as `GetCostForRental`'s `UnitId`; `reservation-submit/ssm/payload.ts:61`
   does the same for `SaveReservationDetails_WEB`.
4. **Legacy's counts are FAKE precisely because of the grain.** It writes the string literals
   `total_unit: "10000"`, `total_vacant: "10000"` on every row (`:299-302`). Nothing counts a
   bucket because there is no bucket.

### Two unit feeds, and which is authoritative for what

|  |  |
|---|---|
| `GetUnitsList` → `UnitDetailLists` | **the row source.** Identity, size, rate, status, type, insurance exclusion |
| `GetAllUnits` → `allUnitsLevelModels` | **a join, never a row source.** The three things the row source lacks: `DoNotDisplayforOnlineReservations`, `UnitLevelAttributes` (features) and `PricingCategory` (tier) — plus `FloorNumber` |

Both returned exactly 2006 rows for the same five facilities and every `UnitDetailLists.UnitId`
resolved in the index, so the join is total on real data rather than usually-total.

Note the docs had `PricingCategory` on the wrong endpoint — legacy reads it off the `GetAllUnits`
row (`:349`) and a live read confirms it is only there.

### `vacantCount` is 1 or 0, and deliberately diverges from legacy

Legacy's `"10000"` sentinel is not harmless: `snap-sizer-engine.ts`'s `availableCount()` returns
`total_vacant` when positive, so **every SSM unit currently reports ten thousand remaining.** The
v4 lane publishes the truth for one unit. Nothing regresses — `v4_api_location_units` was `[]` for
every SSM facility, so no consumer has ever read a number from it.

### `rank` is null, and the contract's claim about SSM was wrong

`CanonicalUnit.rank` stated *"SSM: `tier.PricingCategoryId` 1-3 → `PricingCategoryId - 1`"*.
Measured: ids are **1 "Standard" (3 rows), 3 "Plus" (10), 4 "Premier" (5)** — they run to at least
4 and `2` is never observed. `rank()` accepts only `0|1|2`, so that arithmetic ranks the first two
and silently nulls **Premier**, the most desirable tier. A three-value canonical rank cannot hold a
four-value provider scale without deciding which two collapse, and that is a pricing decision.
`rank` is null; `PricingCategory` is published verbatim in `raw.unit_record`. The docblock is
corrected in place.

### Availability: one signal, and it answers all three flags

SSM publishes a per-unit `UnitStatus` and no rentable/move-in pair. Legacy's answer is one line —
`is_rentable = strtolower($un['UnitStatus'] ?? '') === 'vacant'` (`:355`) — and the browser-side
twin agrees exactly. So `available`, `availableForMoveIn` and `rentable` are all that test.

`availableForMoveIn` is the same value rather than `null`, and the distinction matters: `null` means
"the feed carries neither signal" and makes consumers fall back to `available`. SSM carries one
signal and it is the strict one. Verified on 1612 rows: `is_rentable` is true on exactly the rows
whose status is `vacant`, zero exceptions.

### The detail lane, and the hours that are null on purpose

`GetLocationList` is the only thing in SSM's surface that describes a facility, so the child sync
re-reads the corp-wide list per facility. That read is not overhead bolted on for the detail lane —
it is the lane's **only addressing mechanism**, because `001` is not `99999` and is not `1` either.
Two jobs, one call. Passing the summary down from the parent was rejected for a stated reason:
`syncRunJob` persists child data as `job.data.data`, so it would put every facility's contact name,
mailbox and phone into Postgres forever to save one small GET.

**The six hours fields are null, and that is legacy-EXACT rather than cautious.** Legacy's SSM sync
writes `weekday_start`/`weekday_end` as `NULL` on **both** branches (`:240`, `:245`) every run. The
hours in a published `v2_api_location` come entirely from `FacilityExportWriter::apply_office_hours`
— the operator's CMS values. Measured: four of five facilities have `is_custom_office_hours: 1`; the
fifth has `0` and publishes `weekday_start: null`, exactly what the sync wrote.

SSM *does* hold hours and they are published under SSM's own names in `raw` (`StartTime`, `EndTime`,
`GateStartTime`, `GateEndTime`, `WeekDay`, `StoreOpen`, `GateOpen`). Not mapped onto the six,
because they cannot be: SSM returns ONE open/close pair for the whole week plus a `WeekDay` bitmask
(observed `249`, `252`) whose bit order is undocumented, and the six fields want three day pairs.

**`FacilityTime` is the timezone signal legacy wanted and never had.** It is the facility's local
clock stamped at read time, so `FacilityTime` minus the response instant IS the current UTC offset,
DST included — measured correct on all five (−4 Eastern ×3, −6 Mountain ×1). Published raw and no
offset derived, because the value encodes *the moment of the read* and a stored offset goes wrong
twice a year.

**Legacy's facility row is WRITE-ONCE**, which is its own finding: `:285`'s else-branch updates only
the two hour fields, so `site_name`, `address1`, `phone` and `region_code` are frozen at whatever
the feed said the day the row was created. A facility that renames or moves in SSM never updates in
legacy. The v4 lane reports the current feed value; the cross-check counts the divergence as STALE
rather than as a mismatch, and there were **12** such fields across four facilities.

`ContactPerson` is **withheld** — the same call the SiteLink lane made about `sDivName`, with the
same two pieces of evidence: on live data it names an individual on three of five facilities, and
**nothing in this repo reads a location's `contact_name`**.

### The discount lane

Legacy's shape, reproduced exactly, plus one addition:

- **Rows are unit-scoped**, fanned out from a unit-TYPE plan, in the shape
  `readDiscountArtifact` reads.
- **A unit with no plan gets NO row** — and this differs from the SiteLink lane, which emits an
  empty default. Legacy's SSM job writes a row only inside the branch that found a plan. Measured:
  facility `005` returns zero plans and publishes `[]` against 491 units.
- **The base is `Rent`** (`standard_rate`), and unlike SiteLink it is not a close call:
  `InternetPriceEnabled` is false on all 2006 rows, so there is no second rate to prefer.
- **Both `Type` spellings on every branch.** `GetAllDiscounts` sends strings, `GetUnitTypeDiscounts`
  numbers, for the same three concepts. `Fixed Rent` / `147` is a REPLACEMENT rate, not a
  reduction — legacy publishes a discounted price with no stated discount for those.
- **Nothing is rounded.** Unlike SiteLink's lane, legacy's SSM arithmetic rounds neither the
  percentage before applying it nor the fixed amount.
- **The FIRST passing plan wins** (`$disNum == 0`, `:388`). Reproduced exactly.
- **The addition:** the plans legacy discards go into `available_discounts[]`, which
  `readDiscountArtifact` reads as "concessions the unit OFFERS but is not on" — the array whose
  absence `discounts.ts` documents as having silently lost real promo codes. The top-level row is
  unchanged, so nothing legacy publishes moves. Counted as `offeredBeyondDefault`; **51 additional
  plans** on one facility.

#### Legacy's keyword blocklist, reproduced and counted

`['military', 'senior', '-4', '-3', '-2', '-1']` — a case-insensitive SUBSTRING test against the
plan's `Name` (`:378`). The first two are an audience filter done by string match, and
`GetAllDiscounts` already publishes the field they are groping for (`CustomerType`, `"Regular"` on
all 91 plans). The last four are unexplained.

Reproduced because it decides which promotions a live site shows today, and **counted** rather than
silent. Measured: **0 of 91 plans match** — a live no-op for this operator, which is exactly why it
wants counting rather than assuming harmless elsewhere.

#### The two discount endpoints genuinely differ, so the per-user branch is not dead code

Legacy routes exactly one operator (`$discountApiException = [187]`) to `GetUnitTypeDiscounts` under
a literal *"I don't know why this logic exists"* comment. That question is now answered by reading
both operators' own published raw artifacts:

| | `GetAllDiscounts` | `GetUnitTypeDiscounts` |
|---|---|---|
| envelope | `discountModels` | `RentalDiscountModel` |
| fields | **40** | **14** |
| `Type` / `Category` | string / string | numeric / numeric |
| visibility | `DonotDisplay` + `Availability` + `Website`/`Instore`/`Callcentre` | `DoNotDisplayOnWebSite` only |
| schedule, audience | `Startdate`/`Enddate`, 3 × `ApplyatMoveIn*`, `CustomerType`, `NewCustomer` | — |
| unit type | you pass it in | echoed back |
| unique to it | 26 fields | `PreferredDiscount`, `UnitTypeCode` |

So `GetAllDiscounts` is a superset but for two fields. **No user id is carried into v4**: the lane
reads `GetAllDiscounts` and falls back to `GetUnitTypeDiscounts` when that read fails, which turns
a hardcoded operator id into a capability probe — and a 500 at this provider means exactly "not
granted for this tenant". Both envelopes and both `Type` spellings are accepted regardless.

---

## Rules: eight, and the two extras are earned

`SYNC_RULE_SUPPORT.ssm` lists `duplicate-ids`, `exclude-from-api`, `minimum-rate`,
`amenity-attributes`, `dimension-rounding`, `unit-sort`, `named-units`, `discount-visibility`.
Every one is legacy-exact at its default, measured rather than reasoned:

| Rule | Why it is listed |
|---|---|
| `duplicate-ids` | measured no-op — 2006 rows carry 2006 distinct `UnitId`s |
| `exclude-from-api` | SSM's own `DoNotDisplayforOnlineReservations`, on 2006/2006 rows and true on 5. Legacy honours it as of 2026-07-24 |
| `minimum-rate` | off by default |
| `amenity-attributes` | **earned.** Climate and drive-up exist ONLY inside free-text `UnitLevelAttributes` names (a 12-name vocabulary), and legacy derives nothing — it writes `climate => 0`, `entry_location => 0`, `door_type => ''`. Not listed for SiteLink because SiteLink publishes those as structured columns |
| `dimension-rounding` | **default ON, and legacy-exact — but that had to be MEASURED.** The SSM sync writes raw dimensions; the model accessor rounds on read (`UnitSizeFormatterService::resolve` → `number_format`). All 34 fractional production rows publish rounded, none verbatim |
| `unit-sort` | `feed-order` |
| `named-units` | `all` |
| `discount-visibility` | **earned.** `active` drops only `deleted`, which SSM does not publish, so the default is a no-op and legacy (which filters on nothing) is reproduced. SSM has both other fields — `DonotDisplay` and `Availability`, measured false/true on all 91 plans, so `website-visible` is a verified no-op rather than an untested mode |

### The omission worth reading: `unit-status`

**SSM's status vocabulary has SIX members to the rule's three.** Measured over 110,588 production
rows across six operators:

| Value | Count |
|---|---|
| `Rented` | 97062 |
| `Vacant` | 12183 |
| `Reserved` | 229 |
| `Pending Move-In` | 54 |
| `Unavailable` / `Company Unit` | excluded by the sync, so never in a published row |

The rule's ladder is `vacant` / `occupied` / `reserved`. `Pending Move-In` maps to none of them and
would be dropped by every mode but `all`; worse, the shared default `vacant-occupied` would drop the
`Reserved` rows legacy publishes today. **A rule default is one value for all providers**, so there
is no way to list this without either changing what a live SSM site shows or claiming a vocabulary
SSM does not have.

So legacy's exclusion is reproduced as an invariant in the normalizer and **counted** —
`SsmUnitCensus.droppedByStatus`, surfaced on the job row as *"status exclusion dropped 14 company
unit(s), 33 unavailable"* — so the number has a home even though no dial explains it. Fixing it
properly means provider-scoped modes or provider-scoped defaults; see *What is still missing*.

The other eleven omissions are reasoned one by one in `SYNC_RULE_SUPPORT`'s own comment.

---

## Verification — three columns, and both detectors proved

### Column 1 — legacy raw → legacy published, with v4 removed entirely

Before writing any normalizer, legacy's own logic was transcribed and run over legacy's own
mirrored raw feed, then compared against legacy's own published output. It validates the
TRANSCRIPTION with nothing of ours in the comparison.

**14 unit fields × 1612 rows and 5 discount fields × 1119 rows — 0 mismatches, 0 rows on either
side only.** Then **16/16 perturbations caught.**

That is what made it safe to write the normalizer: the two filters, `Math.round` ≡ `number_format`,
`web_rate = InternetPriceEnabled ? InternetPrice : 0`, the lowercased status, `is_rentable`, the
tier's home, the features join, the keyword blocklist, first-plan-only and all three type branches
were all confirmed before a line of TypeScript existed.

### Column 2 vs 3 — the real normalizers over the real mirrored rows, offline

`apex-app/packages/api/tmp/ssm-crosscheck/crosscheck.ts` (gitignored). Feeding both sides from one
snapshot removes the drift two live runs carry.

```
57 fields, 42,294 comparisons, 4 mismatches
```

| Group | Fields | Rows | Mismatches |
|---|---|---|---|
| units | 22 — identity, dimensions, all four rates, availability×3, status, tier, features, `rank`/`height` null | 1612 | **0** |
| discounts | 6 — `concession_id`, `name`, `discount`, `fixed_discount`, `discounted_rate`, `location_units_id` | 1119 | **0** |
| detail | 29 — identity, address, contact, the six hours asserted NULL, the withheld names asserted absent | 4 | **4** |

**All four detail mismatches are legacy's write-once row**, not a divergence: `site_name` on three
facilities and `region_code` on one, each frozen at creation while SSM has since changed it.

Facility `002` is excluded from every column and the reason is worth keeping: **its published
artifacts have been frozen since 2026-05-08**, and it is the same facility SSM no longer returns.
Its raw file still shows 4 units flagged `DoNotDisplayforOnlineReservations` that its v2 file
publishes — which looked like a filter divergence until `git log -S` dated that filter to
**2026-07-24**, two months after the export. A stale artifact is indistinguishable from a live one
except by timestamp.

**22/22 perturbations caught, plus a negative control.** The pass earned its keep immediately: the
`facility-code` case (`004` → `4`) reported CLEAN, because the comparison helper coerced
numeric-looking strings and could not tell `001` from `1` — the exact zero-padding failure this
provider is prone to, hiding in the thing meant to detect it. Identity fields now compare exactly.
The negative control (corrupting `StartTime`) must NOT fire, and does not, which is what proves the
office hours genuinely never reach the six fields.

### Column 3 — legacy, LIVE: `._current/yourway-ssm-crosscheck.php`

The twin of `._current/gate5-sitelink-crosscheck.php`. Bootstraps Laravel, makes the job's reads
through the job's **own** `SsmController` — so the `/api/Auth` exchange, the cURL options and the
URL construction are identical — and transcribes every resolution line with its line number.

```
mode              LIVE legacy read through the job's own SsmController
GetLocationList   4 facility(ies): 001(Id 99999), 003(Id 100001), 004(Id 100002), 005(Id 100003)
enumeration       legacy stores 5 · feed returns 4 · GHOST in legacy but not in the feed: 002

── 001 ── legacy resolved  40 of  47 · 40 discount rows · ✓ same unit ids · ✓ same discount rows
── 003 ── legacy resolved 412 of 464 · 410 discount rows · ✓ same unit ids · ✓ same discount rows
── 004 ── legacy resolved 667 of 717 · 667 discount rows · ✓ same unit ids · ✓ same discount rows
── 005 ── legacy resolved 491 of 498 ·   0 discount rows · ✓ same unit ids · ✓ same discount rows

CLEAN — 42 fields, 37,853 comparisons, 0 mismatches (plus 12 legacy fields STALE against the live feed)
NOTE  390 discount name(s) differ only by upstream trailing whitespace, which v4 trims

table counts after {...}   ✓ unchanged — this script wrote nothing
```

Writes nothing: no DB write, no S3 export, no queue job. Table counts are re-counted after every
run and printed, and `git status` in that repo stays empty because `._current/` is gitignored.

**The comparison window is two minutes, and it had to be made so.** The first live run reported one
mismatch — unit `1103`'s rent had gone 187 → 194 in the 40 minutes since v4 synced, and two other
units had become `Unavailable`. Re-syncing v4 and re-running produced the clean result above, with
both sides seeing the moved values. **A stale v4 artifact would have failed this**, which is what
makes the zeros mean something; the script prints each artifact's mtime for exactly that reason.

**23/23 perturbations caught** (`._current/yourway-prove.mjs`), including `001` → `1`. This pass
also found a defect in its own assertions: `$V['rank'] ?? 'x'` returns `'x'` for a JSON null,
because PHP's `??` treats null as absent — so two contract assertions could never pass and reported
**1610 false mismatches** against a correct lane. `array_key_exists` now. Two harnesses, two
harness bugs, both found by perturbing rather than by reading.

A `--legacy-cache` flag was added so the perturbation pass replays one live legacy read instead of
making 24 of them: ~2,300 requests against an operator's own production FMS to check our own
arithmetic is not a reasonable thing to do. The headline result above is always from a run WITHOUT
it, and the output states which mode it is in on every run.

### Column 4 — the CONSUMERS, which the other three could not see

`apex-app/packages/api/tmp/ssm-crosscheck/consumer.ts` (gitignored). Runs the actual consumer code
— `providerFacilityId`, `buildReservationUnit` transcribed from `reservationSubmission.ts:483-524`,
`readRate`, `readVacancy`, and `isUnitAvailable`'s `apiType === 'ssm'` branch — over the real
published v4 and v2 artifacts, and compares what each one *answers*.

**This column is the reason headline 3 exists.** As shipped it reports the gap rather than a pass,
which is the intended state:

```
1610 units joined across facilities 001,003,004,005
  providerUnitId              same=1610  DIFFERENT=   0
  facilityId                  same=   0  DIFFERENT=1610
  unitTypeId                  same=   0  DIFFERENT=1610
  discountId                  same=   0  DIFFERENT=1610
  quotedRate ×3               same=   0  DIFFERENT=1610   (tiered: null on both, so 0)
  internetPriceEnabled        same=1610  DIFFERENT=   0
isUnitAvailable(apiType="ssm") disagrees on 493 of 1610
```

It is kept precisely so the eventual fix can be PROVED rather than assumed: when the five readers
are changed to read canonically, this must go to zero. `prove-consumer.mjs` shows the check can
fail (8 of 11 dropped fields caught; the other three — `tiered_rate`, `api_response`, `rentable` —
are indistinguishable in this operator's data and are covered by unit tests instead).

The compatibility block that briefly closed this **did** take it to `CLEAN — 0 consumer-visible
differences over 1610 units`, so the measurement above is of a known-closable gap, not an
open-ended one. It also caught a second bug while it existed: writing `concession_id` as null made
`buildReservationUnit` hand a provider the literal string `"null"`, which every artifact comparison
missed because the artifact was internally consistent. Worth knowing when the real fix is written.

**One difference here is intended and is not the gap.** `readVacancy` reads four keys, none of which
a v2 SSM row carries, so `__vacancyKnown` was false and a reservation's availability check never ran
for this provider. Every v4 row carries the canonical `rentable`, so it will — meaning a reservation
on a non-vacant unit starts being REFUSED where it previously passed. A property of the canonical
shape shared with SiteLink and storEDGE, and a correctness improvement, but a behaviour change.

### The one thing SiteLink could not test: enumeration on a real portfolio

**Answered, and the answer is clean.** `GetLocationList` takes no parameters. Against an operator
whose legacy database names five facilities it returned **four** — and legacy's own live sync
returned the same four, on the same day, minutes apart. The fifth left SSM's feed around
2026-05-08 and legacy has been carrying a ghost row for it ever since (`site_locations` is never
deleted).

So **there is no cap and no geo-filter**: two independent transports agree on the same four. The
apparent 4-vs-5 discrepancy is legacy carrying a ghost, and the cross-check now reports it by name
on every run. Confirmed on 5 facilities, not on 115 — `storage-star` has 122 and is unverified.

### The live run

Credentials confirmed as YourWay's by SHA-256 against legacy's own `configures` row (never
printed), piped as base64 so no shell could mangle them. Written to `kv_store` through the
sanctioned `PUT …/api-sources/{id}/credentials` route — `fms_ssm_api_url`,
`fms_ssm_api_username` (secret), `fms_ssm_api_password` (secret). There were no dead `SSM_*` lines
in `packages/api/.env` to leave alone, unlike SiteLink. The route's own response confirms
`hasGlobalDefault: false` on all three: **SSM has no env fallback and no default for the base URL**,
so a wrong `api_url` fails in a way that looks like a dead account.

```
verify   ok: true — GetLocationList
sync     4 locations, 0 failed, 10.7s · conditionEffect read 1726, kept 1610
```

Per-location census on the job rows, matching the offline run facility by facility:

```
001  status exclusion dropped 7 unavailable · 40/47 published · 18 carry a PricingCategory, rank null
     40 rows from 12 plans over 6 types · 51 additional offered plans in available_discounts
003  status exclusion dropped 3 company unit(s), 49 unavailable · 412/464 published
     410 rows from 29 plans over 31 types · 2 units on no plan (no row emitted, as legacy)
004  status exclusion dropped 14 company unit(s), 33 unavailable · 669/717 (rules: Excluded in the FMS 1)
005  status exclusion dropped 3 company unit(s), 4 unavailable · 491/498 published
     0 rows from 0 plans over 34 types · 491 units on no plan
detail (all four)  facility fields withheld: ContactPerson[, ReservationEmail]
```

No unrecognised upstream field on any lane at any facility.

**Staleness check passed**: api child pid started 09:54:33, newest source mtime 09:54:14, contract
dist 09:50:39 — the running process had the code.

**Content boundary, asserted on the live artifacts**: 20 files across four facilities carry **0** of
the 33 withheld keys, while the same facility's legacy artifact carries **26** of them.

---

## Files

**Server**

| File | Change |
|---|---|
| `syncs/fms/normalize/ssm.ts` | the three lanes — `normalizeSsmDetail`, `normalizeSsmUnits`, `normalizeSsmDiscounts`, `indexSsmUnitInfo`, `ssmDetailCensus`, five allow-lists + four withheld-lists, the census types. `normalizeSsmLocations` re-keyed to `Code` |
| `syncs/fms/ssm.ts` | rewritten: code→id resolution, five reads plus a bounded discount fan-out, rule resolution, three census notes |
| `syncs/fms/client.ts` | `FMS_LANE_SUPPORT.ssm` — five lanes true, with the location-code note |
| `rental-contract/sync-rules.ts` | `SYNC_RULE_SUPPORT.ssm` (eight rules, twelve omissions reasoned) |
| `rental-contract/units.ts` | `CanonicalUnit.rank`'s SSM claim corrected against measured data |

**Docs**

| File | Change |
|---|---|
| `docs/fms/ssm/README.md` | banner and index mark six endpoints MEASURED; §7's gaps table replaced with the docs-said-vs-live counts; enumeration + pagination findings |
| `docs/fms/ssm/endpoints/GetLocationList.md` | 12 → **23** fields; the `Code` vs `Id` question; `FacilityTime`; the ghost-facility warning |
| `…/GetUnitsList.md` | 12 → **36**; the rent-roll table with fill counts; the six-value status vocabulary |
| `…/GetAllUnits.md` | 2 → **18**; the 12-name attribute vocabulary; `PricingCategoryId` runs to 4 |
| `…/GetAllDiscounts.md` | 4 → **40**; the blocklist, first-plan-only, no-rounding and no-row-without-a-plan gotchas |
| `…/GetUnitTypeDiscounts.md` | 4 → **14**; the side-by-side comparison that settles the per-user branch |
| `…/GetInsuranceSchemes.md` | 3 → **11**; `SchemeName` + `InsuranceCompany` falsify the code's own claim |
| `helix/docs/troubleshooting.md` | the green-sync-wrong-folder symptom |
| `helix/docs/open-items.md` | §8, the rent-roll exposure |

**Legacy** (`app-storagely-io`, in gitignored `._current/` — that repo's tree stays clean)

| File | What |
|---|---|
| `._current/yourway-ssm-crosscheck.php` | the live cross-check. Read-only; the job's own controller; `--user=`, `--location=`, `--v4=`, `--json=`, `--verbose`, `--legacy-cache=` |
| `._current/yourway-prove.mjs` | the 23-case perturbation pass over the staged v4 copy |

**Verification harnesses** (`apex-app/packages/api/tmp/`, gitignored)

| File | What |
|---|---|
| `tmp/ssm-crosscheck/crosscheck.ts` + `prove.mjs` | the offline normalizer comparison and its 22-case perturbation pass |
| `tmp/ssm-crosscheck/consumer.ts` + `prove-consumer.mjs` | Column 4 — the consumer comparison and its 11-case pass |
| `._current/ssm-inventory.php`, `ssm-codes.php`, `ssm-status.php`, `ssm-creds-export.php` | the read-only measurement scripts behind the numbers in this doc |

**Tests**: `__tests__/services/api-sources/fmsNormalizeSsmUnits.test.ts` — **78 tests**, twelve of
them existing only to fail if a tenant field, a gate code or an attribute image URL ever reaches the
artifact, and three pinning the canonical-only decision: they FAIL if anyone re-adds a v2 field
spelling, and name the five readers to fix instead. `fmsNormalizeSsm.test.ts` and `syncs.test.ts` updated where they asserted the old
`Id`-keyed behaviour — the `LOCATIONS` fixture's `LOC/7750` was the synthetic value that justified
it, and is replaced with the measured shape.

Root-suite guards updated: `tests/fms-sync-rules.test.ts` and `tests/api-source-sync-pipeline.test.ts`
both used `ssm` as their "provider with no rules" example. Moved to `yardi`/`monument` and given
positive assertions for SSM's eight — plus a new guard that every id every provider claims exists in
the catalog, so the next provider does not need a fourth manual move.

---

## Gates

```
npx vitest run                   521 files, 9922 passed, 11 skipped
packages/api jest                231 suites, 3070 passed, 2 skipped — 1 PRE-EXISTING failure
pnpm -r --if-present typecheck   7/7 clean
```

**The one jest failure is not this work.** `__tests__/services/checkout/checkoutQuote.test.ts › the
cache › asks again when a price-bearing input changes` fails identically on a clean tree —
confirmed by stashing every change in `api-sources` and `rental-contract` and re-running. The test
logs `quote cache read failed: Database service not activated`, so it is a test-isolation problem in
the quote cache, unrelated to any FMS lane.

Jest baseline re-measured as the prompt asked: **231 suites / 3073 tests** (was 229/2962 before the
`main` merge). The root suite caught **6** drift guards this session — the fifth session running in
which `packages/api`'s jest suite alone would have shipped a gap.

`packages/rental-contract` was rebuilt. Restart the dev servers before eyeballing the board.

---

## What is still missing

1. **Provider-scoped `unit-status`.** The one rule SSM genuinely needs and cannot have: a six-value
   vocabulary against three modes, and a shared default that would drop 229 `Reserved` and 54
   `Pending Move-In` rows. Needs either provider-scoped modes or provider-scoped defaults on
   `SyncRuleDef` — a contract change touching every UI surface that reads `def.default`, which is
   why it is not folded in here. Until then the exclusion is an invariant plus a census line.
2. **The legacy rent-roll exposure.** [open-items.md §8](open-items.md). A patch in the other repo
   AND a CDN purge, plus a disclosure decision.
3. **`provider` on the coverage lane.** `normalize/ssm.ts` says `GetInsuranceSchemes` sends no plan
   or provider label, so it publishes `provider: null` and the checkout names tiers by id. Live data
   carries `SchemeName` (`"$2500 Protection Plan"`) and `InsuranceCompany` on every scheme. A
   two-line honest improvement, deliberately not made as a side effect of the units work.
4. **A discount month SCHEDULE.** `month_number` is null, so an SSM promotion publishes no schedule
   and `pendingDiscount` never fires. SSM carries the ingredients — `DiscountPeriods` (1, 2, 3, 13),
   `ApplyAfter` and the three `ApplyatMoveIn*` booleans, all published in `plan`. Building one needs
   those semantics confirmed: does "50% Off 3 Months" discount months 1–3 or 2–4? Guessing puts
   wrong money in a quote.
5. **`PricingCategoryId: 2`.** Never observed in 18 tiered rows, and ids reach 4. Whatever it is
   called, the SSM tier scale needs enumerating before a `rank` mapping can exist.
6. **A rule for the discount name blocklist.** `['military','senior','-4'…]` is reproduced and
   counted but is an anonymous condition. `CustomerType`, `NewCustomer` and
   `ApplyforExistingTenants` are the fields that would answer the question properly, and all three
   are published on every row so the design can be done from the artifact.
7. **Enumeration on a large portfolio.** Confirmed on 5 facilities. `storage-star` has 122 and
   `my-garage-self-storage` 48; neither is verified, and no pagination parameter exists on any SSM
   list endpoint. A 717-unit facility returned in one response, so the ceiling is above 717 — but
   62k-unit operators exist.
8. **The orphaned numeric-id directories.** Locally, `…/locations/99999/` etc. survive from the
   import mirror. Harmless here. **In production every SSM operator has a parallel tree of
   `v4_api_location_insurance`/`_catalog` artifacts under numeric ids** that nothing will ever read
   again once this ships. Worth a cleanup pass, and worth knowing they are there before someone
   finds them and assumes they are live.
9. **The five readers must be fixed BEFORE a checkout or `reservation` component goes on an SSM
   site.** This is the one hard prerequisite this lane ships with — see headline 3. The reads are in
   `reservationSubmission.ts` (`buildReservationUnit`, `readRate`), `unit-data-mapping.ts`
   (`isUnitAvailable`'s ssm branch) and `checkout-submit/ssm/submit.ts:115`; the fix is to go
   through `fromV4Unit` / `providerFacilityId` / `providerUnitId` instead of indexing the raw
   record. `buildReservationUnit` reads raw ON PURPOSE — its docblock says so — so changing it
   alters what all four providers send their FMS and wants its own verification pass. Column 4 is
   the harness for it; it must go to zero.
10. **The same gap would hit SiteLink the moment its units lane goes on.** `quotedRate` and
   `discountId` are provider-independent. *Corrected 2026-09-01:* an earlier draft of this item said
   SiteLink "publishes a non-empty `v4_api_location_units` in production today" and might already be
   affected. It does not — `3f97ef72` took only the transport fix to main and left `detail`, `units`
   and `discounts` off, so that artifact is still empty for every SiteLink location and nothing is
   exposed. The gap is therefore a PREREQUISITE for turning SiteLink's units lane on, not a live
   defect. See [handoff-sitelink-v4-sync.md](handoff-sitelink-v4-sync.md), which now records what
   actually shipped for that provider.
11. **`readVacancy` starts answering for SSM.** See Column 4. A reservation on a non-vacant unit
   will be refused where it previously passed. Correct, but new.
12. **Yardi is the last stubbed provider**, and it is a bigger job than this one: two APIs in tandem,
   eleven credential keys, and nothing in `FMS_LANE_SUPPORT` true.
13. Two repos, two commits, never one — and `atlas/` pushes to `storagely-home-base`.
