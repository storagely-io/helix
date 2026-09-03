# HANDOFF — the Yardi v4 location + unit + discount sync

Session of 2026-09-03. The last provider. Successor to
[docs/handoff-enumeration-sitelink-ssm.md](handoff-enumeration-sitelink-ssm.md); answers
[docs/prompt-yardi-v4-sync.md](prompt-yardi-v4-sync.md), **three of whose premises turned out to be
wrong** — see [Four corrections to the brief](#four-corrections-to-the-brief).

Uncommitted work: none. Two commits, one per repo, listed under [Files](#files). `apex-app` is on
`fix/fms-tenant-write-policy`, not `main` — the prompt's warning about pushing to `main` did not
apply, and nothing was pushed.

---

## The headline: the offline 1-to-1 was clean and the first live sync published ZERO units

Three columns of comparison over the whole 284-facility portfolio — **173,705 field comparisons,
zero mismatches, zero rows on either side only, 32 of 32 perturbations caught.** Then the first
live run wrote `v4_api_location_units.json` as `[]` for all ten facilities it touched.

The cause is worth more than the lane:

```
AvailableUnits returns   PhysicalProperty > Property[@IDValue] > Floorplan[@IDValue][@IDType]
                         PascalCase children, ranges on ATTRIBUTES of empty elements

the offline corpus is    { units: [ { …, floorplans: [ { id_value, initial_rent, … } ] } ] }
                         legacy's PARSED DTO, which it also publishes as fms_api_location_units.json
```

Every column of the 1-to-1 fed the normalizer legacy's DTO, because that is what the CDN carries
and what the import mirror carries. **The client was handing it the raw MITS document.** The
comparison was internally perfect and measured a shape the client never produced.

Two more defects hid behind the same seam, and neither was visible offline either:

- **`elementToValue` silently dropped attributes from childless elements.** `<Identification
  IDValue="400016"/>`, `<SquareFeet Min="100" Max="100"/>`, `<MarketRent .../>` and
  `<EffectiveRent .../>` all converted to `''`. That is the shared SOAP→object helper every
  provider uses; SiteLink and SSM never noticed because DataSet XML puts values in child elements.
- **RentCafe returns TWO mappings for 52 Voyager codes, and both legacy and v4 keyed them
  last-wins over an unordered list.** See the next section — this is the one that would have cost
  money.

**The lesson, stated as a rule for the next provider:** a 1-to-1 against a mirrored corpus
verifies the NORMALIZER and says nothing about the CLIENT. The corpus is the previous system's
output; the wire is the wire. There must be one comparison that reads what the client actually
wrote — [Column 5](#column-5--the-live-artifacts-which-is-the-only-column-that-reads-what-the-client-wrote).

---

## The one that would have cost money: 52 Voyager codes, two RentCafe mappings each

`propertyId` is what `createlead` and `getcontinueapplicationurl` take. It comes from RentCafe's
`getpropertymappings`, joined to the Voyager code. Measured live on this connection:

```
1063 mappings · 987 distinct voyagerPropertyCode
  52 codes carry MORE THAN ONE mapping
  58 mappings carry a "zTest" marker, in SIX spellings:
     "zTest_"  "ztest_"  "zTest - "  "ztest - "  "ztest- "  "zTest "
  18 of this operator's 284 PUBLISHED facilities are among the 52
  22 mappings carry no voyagerPropertyCode at all
```

In all 52 cases the duplicate is a **test clone of the real property**. Both integrations did
`byCode.set(code, mapping)` over an unordered list, so **which property a rental is sent to was
decided by RentCafe's response order.**

It fired on the first live run. Facility `400019` resolved `2002817` — `zTest - L457 - Mini Mall
Storage - Embrun` — where legacy's own most recent run resolved the real `1986331`. The visible
consequence was every floorplan on that facility taking its display name from the test property's
`getunittypes`; the invisible one would have been a lead created against a test property.

### Why the brief's measurement was true and completely misleading

The prompt records *"Measured today: 0 such names in the published list, so reproduce it as a rule
and count it rather than hardcoding a client slug."* That measurement is correct — and I
reproduced it independently: **0 of 284 published property names contain `zTest`.**

They contain none **because legacy's filter removed them.** Measuring the published output cannot
see a filter's effect; only measuring the INPUT can. `getpropertymappings` is where the 58 live.

So legacy's hardcode (`YardiMergedApi.php:39-41`, *"for client `mini-mall-storage-yardi`, drop
mappings whose `propertyName` contains `zTest`"*) is not the retired-per-customer-hardcode the
brief took it for. It is **load-bearing**, and the plan to replace it with `facility-filter` could
not have worked: that rule runs on the enumeration ROW, after the intersection has already chosen
a `propertyId`. It can drop a facility; it cannot choose between two mappings for one code.

### What shipped instead

`indexMappingsByCode` (`fms-yardi/merged.ts`), shared by the sync client and the lead path so the
artifact and the checkout cannot disagree:

1. **prefer mappings whose `propertyName` does not carry the marker** — used only to BREAK A TIE,
   never to drop a code. A facility whose only mapping is marked is kept and reported
   (`onlyTestMapping`), where legacy's unconditional drop would silently remove it;
2. **among those, the lowest `propertyId`** — arbitrary but stable, so two runs of unchanged data
   resolve the same id. As load-bearing as step 1: with every clone set aside, two unmarked
   mappings would still be resolved by list order, and *"the sync sends rentals to a different
   property on Tuesdays"* is not a failure anyone would look for;
3. **every ambiguity is NAMED on the job row**, on every run, including runs where the choice
   happens to match last time.

It is still a name match, which this sequence spends its time removing. The difference from
`SitelinkLockHelper` is that there is no structured field to use instead, the match decides a
tie rather than an inclusion, and the alternative is luck. Nine tests pin it, including the
lowest-id tie-break and the negative control.

---

## Four corrections to the brief, all load-bearing

### 1. The unit counts are NOT real — `total_unit` and `total_occupied` are fabricated

The prompt says *"Unlike SSM, the counts are REAL. `total_unit`/`total_vacant` measured 30/24,
15/12, 8/6, 9/7 — genuine numbers, not SSM's `"10000"` sentinel."*

`Floorplan/UnitCount` is the **AVAILABLE** count — the endpoint doc says so and legacy's own
comment repeats it. Legacy then invents the other two (`YardiFacilitiesUnitSyncJob.php:389-394`):

```php
$available      = $floorplan->unit_count ?? 0;
$total_occupied = max(1, (int) ceil($available * 0.25));   // invented
$total_unit     = $available + $total_occupied;            // invented
```

30/24 is `24 + ceil(24×0.25)`. 15/12 is `12 + 3`. 8/6 is `6 + 2`. 9/7 is `7 + 2`. **That formula
reproduces legacy's published `total_unit` and `total_occupied` on 3890 of 3890 rows.** It is
SSM's `"10000"` sentinel by a different route — `total_vacant` is real and the other two are
arithmetic.

`CanonicalUnit` has one count field, so the fabrication has nowhere to go and **is not
reproduced**: `vacantCount` carries the feed's own number. Checked before deciding: the
fabrication is arithmetically **inert** in every consumer — `isUnitAvailable` and both
`availableCount` implementations test `total_vacant > 0` first and only fall back to
`total_unit − total_occupied − total_reserved`, which for this formula is `(a + o) − o − 0 = a`.
Column 4 confirms it: `availableCount` disagrees on 0 of 3890 units.

### 2. Legacy does NOT drop the country signal — it maps it to `country_id`

The prompt says legacy *"drops the one field that would answer it"*. Half right:

| | value | facilities |
|---|---|---|
| raw `country` | `canada` / `us` | 67 / 217 |
| legacy `v2_api_location.country` | `""` | 284 |
| legacy `v2_api_location.country_id` | `2` / `1` | **67 / 217 — an exact match** |

`YardiFacilitiesSyncJob.php:51-60` maps anything containing "canada" to `2`, everything else to
`1`, and writes it on **every** run — one of only three fields its update branch touches. So the
signal survives in a numeric column and the string does not. Both are published now: `country`
because it is what Yardi said, `country_id` because it is what consumers read.

### 3. `zTest` is load-bearing, not a no-op

See the section above.

### 4. The `.env` license trap, which presents as a dead credential

Not in the brief at all, and it cost the first `verify`. `YARDI_SOAP_LICENSE` is a 378-byte base64
PKCS#7 blob that **must carry real newlines**, and this `.env` holds them **escaped** — five
literal two-character `\n` sequences inside one quoted single-line value. Legacy converts them
(`YardiSoapClient::getCredentials`) **only when `App::environment('staging')`**, and this checkout
is `APP_ENV=local`.

Sent escaped, Yardi answers inside an HTTP 200:

```
<Message messageType="Error">Unable to invoke Interface Web Service. Invalid Yardi Interface License.</Message>
```

Which reads as an expired or revoked license, not as a value the reader mangled. That is a **third
variant** of the `.env` trap in [troubleshooting.md](troubleshooting.md), alongside CRLF and
quoting, and it is the same misattribution by a new mechanism. Added there.

---

## What shipped

Three lanes: `v4_api_location`, `v4_api_location_units`, `v4_api_location_discounts`.
`FMS_LANE_SUPPORT.yardi` reads `detail/units/discounts: true`; `insurance` and `catalog` stay false
with a named reason each.

| Lane | Reads | Note |
|---|---|---|
| detail | the reconciled property — SOAP `GetPropertyConfigurations` + RentCafe `getpropertymappings` + SOAP `GetPropertyInfo` | the only facility descriptor Yardi has, and it is thin — see below |
| units | SOAP `AvailableUnits` `Floorplan`s, validated against RentCafe `getunittypes`, plus one `GetUnitTypeMoveInCharges` per floorplan | unit-TYPE grain |
| discounts | the `Concession[]` nested in each floorplan — there is no discount endpoint | priced against the units lane's own standard rate |

`insurance` — Yardi publishes no coverage ladder. `Floorplan/InsNotRequired` is a per-floorplan
boolean saying whether insurance is *required* for that size, which is a different fact from the
tiers-with-premiums a protection lane needs. False here means **no artifact** rather than an empty
one, so a reader falls through to `v2_api_location_insurance`.

`catalog` — "never checked", not "impossible". Legacy reads no catalog from Yardi; the WSDL does
carry `GetServices` and `GetAvailableRetailItems`, neither wired into `fms-yardi` and neither ever
called against a live tenant. Guessing at a shape would put items in front of a tenant that no
read has ever returned — the SiteLink `Late Fee` problem before `sChgCategory` filtered it.

No new artifact lane, so none of the six hand-maintained registration lists needed touching.

### The GRAIN: a row is a FLOORPLAN (unit type)

Confirmed with Chrys before any code was written. Yardi is the third type-grain provider after
SiteLink and Monument. Four independent confirmations:

1. **Legacy keys on the floorplan.** `LocationUnit::updateOrCreate(['unit_id' => $fp->id_value, …])`
   (`:396-402`). Measured portfolio-wide: **3900 raw floorplans → 3890 published rows**, and the
   10-row difference is legacy's own exclusion list, not the grain.
2. **The property's own total is a different number.** Facility `400007` reports
   `Information/UnitCount: 138` and 11 floorplans of 24, 15, 8, … Legacy publishes 11 rows.
3. **It is the grain the rental transacts at.** `getcontinueapplicationurl` takes
   `voyagerUnitTypeId` — the floorplan's numeric type code. **Yardi has no call that accepts a
   per-unit id**, so a per-unit lane could not complete a rental even if it existed.
4. **The per-unit shape exists and has never been parsed.** `AvailableUnits` returns `ILS_Unit`
   elements beside the summaries (26 on facility `400016`, 236 on one doc sample) with
   `UnitOccupancyStatus`, `UnitLeasedStatus` and `RentReady`. Legacy's parser skips them entirely.
   A real future lane, not a correction to this one.

### The TWO IDS, and this is the first provider where they genuinely differ

```
id_value: "ut000001"   the floorplan KEY — GetUnitTypeMoveInCharges' YardiUnitTypeId,
                       getunittypes' unitTypeMapping join key, legacy's `unit_id`
id_type:  "1660"       the numeric TYPE CODE — getcontinueapplicationurl's voyagerUnitTypeId,
                       legacy's `unit_type_id`
```

Settled from `docs/fms/yardi/endpoints/rest-getcontinueapplicationurl.md` (*"`voyagerUnitTypeId` is
the SOAP `Floorplan/@IDType`, **not** `@IDValue`"*) and `soap-GetUnitTypeMoveInCharges.md`
(*"`YardiUnitTypeId`: the `Floorplan/@IDValue`, e.g. `ut000004`"*). Not guessed: the two are
indistinguishable in a green run, and getting them the wrong way round sends a rental an id
RentCafe does not resolve.

Measured before keying anything on either: **3900 distinct `id_value` and 3900 distinct `id_type`
over 3900 floorplans, with no `id_type` reaching two floorplans.** So both are globally unique and
either can carry a join; what differs is what Yardi does with them.

**Chrys's call:** `CanonicalUnit.id` = `id_value`, `providerId` = `id_type`.

That is what the two fields are for. `id` is documented as the identity everything inside the
platform keys on — `?unit=` links, cart state, re-pricing, the join against legacy's rows — and
`providerId` as *"what a move-in call must name"*. For four providers they coincide, which is why
`fromV4Unit` hardcoded `providerId: id` with a docblock saying *"a client that ever writes
something else has broken the contract"*. Yardi is the case that contract was written for, so
`fromV4Unit` now reads an explicit `providerId` when a row sets one, and falls back to `id`
otherwise — additive for every other provider.

**The facility code has its own version of the trap, and legacy loses it.** The 284 codes come in
six shapes — `400007`, `usmm4101`, `USMM####`, `bowie##`, `usstorag`, `castorag` — and the artifact
key lowercases. Checked: **lowercasing all 284 yields 284 distinct codes**, so there is no
collision. It also surfaced a live defect in legacy:

```
location-list.json says   USMM2805   →  403 at .../locations/USMM2805/...
its artifacts sit at      usmm2805   →  200 at .../locations/usmm2805/...
```

Three rows, all three uppercase, all three 403 at the cased path. v4's lowercasing lands on the
readable path, so this lane is right where legacy's own list is not. Counted as an improvement in
the 1-to-1 rather than a mismatch.

### The rates: four, and `web_rate` is a WEEKLY rate times four

Measured across all 3890 published rows, exact on every one:

| v2 field | Yardi raw | Verified |
|---|---|---|
| `standard_rate` | `InitialRent` | **3890 / 3890** |
| `push_rate` | `PushRent` | **3890 / 3890** |
| `web_rate` | **`WebWeeklyRate` × 4** | **3890 / 3890** |

**Four weeks is not a month.** The number on a Yardi site's unit card is a four-week price in a
monthly field. This is not a rounding quirk — it is the price 284 live facilities have shown for
years, and every Mini Mall component in the library labels it `/4 wks`
(`MinimallStorageVbpHandler::getPriceSuffix`). So it is reproduced exactly and **named** in the
normalizer, with a test pinning the arithmetic, rather than silently corrected: a correction would
move prices on 284 facilities on the next sync with nothing to point at. Same call the SiteLink
discount lane made about its two rounding quirks.

`market_rent_min/max` and `effective_rent_min/max` are published per floorplan and legacy reads
**neither** — they are in `raw` and absent from `rates`, because a fifth rate reaching a quote by
accident is the failure mode.

**Yardi is the first provider in this stack with weekly pricing at all**, and it rides in `raw`.
The feed carries `WebWeeklyRate` and `StartingWeeklyRate`; legacy derives four more. `CanonicalUnit.rates`
is a closed set (`CANONICAL_RATE_FIELDS`) and no reader knows a weekly rate exists, so contract
fields would be four new keys with no consumer. All six live in `raw` under legacy's own
spellings — which also keeps a component template reading
`{v2_api_location_units.weekly_web_rate}` working when it moves lanes.

### Availability: one signal, and no split to make

`total_reserved` is the literal STRING `"0"` on all 3890 published rows, and no Yardi field carries
a reserved count. So SiteLink's `iTotalVacant − iTotalReserved` split has **no counterpart**, and
`available` and `availableForMoveIn` are deliberately the same signal. Publishing a difference
would be pretending to subtract something the feed does not have.

### `door_type` and `entry_location` are STICKY in legacy, and 187 unit features are residue

Legacy sets each only when the feed's string matches a branch (`:464-483`), has no else, and does
not include either column in the `updateOrCreate` payload — so a value written by an earlier feed
shape survives forever. Measured:

```
entry_location: 2 ("Interior Hallway Entry")  on 157 rows whose current `access` is "Drive Up"
door_type:      1 ("Rollup Door")             on  31 rows whose current `door` is null
                                                 187 UnitFeature rows manufactured off the back
```

This lane derives both from the current feed every run, which is why the 1-to-1 classifies those
375 differences as legacy residue rather than as mismatches.

### The facility descriptor is nearly empty, and legacy's row is WRITE-ONCE

`YardiFacilitiesSyncJob.php:174-185` — the update branch writes exactly three things
(`weekday_start: NULL`, `weekday_end: NULL`, `country_id`) plus `country` at `:196`. **Everything
else is frozen at row creation.** So a published `v2_api_location` looks far richer than the feed
that supposedly fills it. What the feed actually carries, over all 284:

```
property_manager   null on 284        year_built / year_renovated   null on 284
gated              false on 284       other_info_1..5               null on 284
phone              set on 5 of 284    address_line_3                null on 284
time_zone          5 distinct WINDOWS zone names ("Mountain Standard Time", …)
email              CDR@yardi.com on 278 of 284
```

Two consequences worth reading:

- **`email` is Yardi's own address on 278 of 284 facilities.** Published verbatim — the artifact's
  job is to say what the provider said, and special-casing a vendor string is the anti-pattern this
  sequence retires — but the count goes on the job row every run (`yardiDetailCensus.vendorEmail`,
  matched on the DOMAIN rather than the literal). Nothing renders it today: `v4_api_location`'s
  only consumer in the repo (`announcement-v2-1/data.ts:527`) reads `location_code` and nothing
  else, and tries `v2_api_location` first. Open item 4.
- **`phone` is the thinning field.** Legacy publishes a real facility phone on 276 facilities that
  the current feed does not state, so v4 publishes null there. Counted apart from staleness in the
  1-to-1 for exactly that reason — same provenance, different outcome. Open item 3.

The six office-hour fields are null, and that is legacy-EXACT: they come from
`FacilityExportWriter::apply_office_hours` — the operator's own CMS rows — not from Yardi, which
returns no hours at all. A negative control in the perturbation pass proves it: corrupting a feed
field must not move them, and does not.

### The discount lane

No discount endpoint exists — a concession is nested in the `Floorplan` that offers it, already
unit-scoped, so this lane needs no join and no fan-out. Legacy reads three of nineteen fields, two
by string surgery. Measured over the whole portfolio:

```
raw concessions                 31,393
  active = false                     0    the flag is a measured NO-OP
  show_on_portal = false        27,488    the whole filter, in practice (87.6%)
  keyword-blocked                    0    every "Military"/"Senior"/"MMSP Staff" plan is
                                          ALREADY off-portal, so the blocklist never fires
  eligible                        3,905
  emitted (first eligible wins)   3,415    490 eligible promotions discarded
  published by legacy             3,405    the 10-row difference is EXCLUDED_UNITS again
```

The keyword blocklist being a no-op is worth stating rather than quietly dropping: it is the
`SitelinkLockHelper` pattern, it protects nothing on this portfolio, and `show_on_portal` — a
structured boolean Yardi maintains — already does the job it was written for. Reproduced because
legacy-exactness is this lane's contract, and **counted** so the next person can retire it on
evidence.

**The footer is PARSED, not substring-matched.** `DescriptionFooter` is a comma-separated
`Key=Value` blob and legacy does `str_contains($footer, 'percentofrent')`. Measured over all 3415
chosen concessions: the key set is always exactly `Modifiable,Required,NewMoveIn,ValueType`, and
`ValueType` is only ever `PercentOfRent` (3357) or `Flat` (58) — so a real parse and legacy's
substring agree everywhere today. The parse is what stops a future `ValueType=PercentOfRentAfterFees`
being read as a percent, and a test pins that case.

**`discounted_rate` is ZERO on 3357 of 3415, and NEGATIVE on 2.** The chosen promotion is almost
always `100% × 4 Recurring` — "4 Weeks Free" — so `standard − (100/100 × standard)` is exactly 0.
That is what legacy publishes and what live sites show, so it is reproduced.

The two negatives are a **real defect** and not a rounding artifact: on `usmm3511`, "No Activation
Fee" is a **$35 fee waiver** with `ValueType=Flat`, and legacy subtracts it from the monthly RENT —
publishing `discounted_rate: -11` on a $24 unit. Yardi carries no field separating a fee concession
from a rent one, which is the gap `sChgCategory` closes for SiteLink and nothing closes here.
Reproduced, counted (`nonPositiveRate`), and recorded as open item 2 rather than silently clamped:
a clamp would hide the two rows that need an operator's attention.

**`month_number` stays null, and `term` is not the schedule.** SSM could not fill it for lack of
month indexing. Yardi looks like it can — `Term`, `StartMonth`, `RecurrenceType`, `Recurrences`,
`StartingWeek` — and it cannot, for a measured reason: `Term` is **1 on all 3415** chosen
concessions, and `Recurrences` counts WEEKS on one plan and MONTHS on another with only the
free-text name to tell them apart (`"STV - 25% - 12 Weeks"` carries `recurrences: 12`;
`"STV - 25% - 3 Months"` carries `recurrences: 3`). Deriving a schedule from that would be a guess
rendered as a price. All five fields are in `raw` so the semantics can be confirmed with Yardi.

---

## Rules: six, and both extras replace a hardcode that shipped

`SYNC_RULE_SUPPORT.yardi` — the key EXISTING is itself a change, since `yardi` was the codebase's
designated "provider with no rules".

| Rule | Why it is listed |
|---|---|
| `named-units` | **the reason this provider needed the rule.** `YardiFacilitiesUnitSyncJob.php:32-111` hardcodes **78 floorplan ids** under a `@TODO impl new Yardi logic they'll add`, applied to every Yardi client. **10 are live today across 4 facilities**, and legacy withholds all 10. `SYNC_RULES.named-units`' own provenance has cited this list by file and line since the rule was written |
| `dimension-rounding` | **earned, and the OPPOSITE answer to SSM's.** Legacy's rounding is decided by `Configure.is_disable_rounding_unit_size`, which this operator has **set** — so the model accessors return the stored value untouched and **52 of 3900** floorplans publish fractional dimensions (42.5, 17.5, 7.5) verbatim. The rule's own provenance names that flag |
| `facility-filter` | legacy's `zTest` hardcode was meant to land here and **cannot** — see the mapping section. Listed anyway because the rule is genuinely applicable (the enumeration row carries `code`, `name` and `country`) and it is what scoped this session's live run to ten facilities |
| `duplicate-ids` | measured no-op — 3900 floorplans carry 3900 distinct `id_value`s |
| `minimum-rate` | off by default |
| `unit-sort` | `feed-order` |

**Two connection-wide settings make a migrated connection legacy-exact**, both the operator's own
existing legacy configuration carried across as DATA rather than code:

```
named-units          exclude-listed over the 78 ids
dimension-rounding   { enabled: false }
```

The exposure without them is bounded and measured, and both runs are in the handoff rather than
only the flattering one:

```
with the two settings     0 MISMATCH · 0 rows on either side only
without them             52 MISMATCH (38 width + 14 length) · 10 units + 10 discounts only in v4
```

Nine of the ten extra floorplans have `unit_count: 0` and would render unavailable; one
(`400047 / ut000668`, "30' Uncovered Parking") would become bookable. Chrys chose this route with
that number in front of them.

### `SyncRuleSet` could not carry `unitIds`, and the contract already said it must

Storing the 78 ids failed with a 400: the route's Joi schema for `syncRules` omitted `unitIds` and
`facility` while the override `state` accepted both. That is the exact asymmetry
`checkRuleState`'s own docblock forbids — *"the failure mode is silent in the worst direction: a
value an operator can save as an override and not as the base, for no reason either screen can
explain."* The contract's `SyncRuleState` has always declared them and `resolveSyncRules` has
always read them; only the wire refused. Fixed in `apiSourcesRoutes.ts`, bounded the same way.

### `SYNC_FIELDS` had no `yardi` key, which would have made `facility-filter` unconfigurable

Listing a rule whose condition vocabulary is empty is a dial an operator cannot set — the same
dishonesty as listing a rule the normalizer ignores. Three fields added: `code`, `name`, and
**`country`**, which Yardi uniquely earns (it is the only provider whose enumeration row carries
it, present on all 284, and *"sync only my Canadian sites"* is a question a cross-border portfolio
actually has). `propertyId` is deliberately omitted, for the reason SSM's `facilityId` and
SiteLink's `siteId` are — and more sharply here, since this provider has two ids at every grain.

A guard now asserts that **every** provider claiming `facility-filter` has a facility vocabulary,
so the next one cannot forget the other half.

### The fourteen omissions

Each reasoned in `SYNC_RULE_SUPPORT`'s own comment. The one worth reading:

**`discount-visibility`** — the exact shape of SSM's `unit-status` omission. Yardi has both fields
the rule asks about (`Active` and `ShowOnPortal`) and legacy's Yardi lane filters on BOTH,
unconditionally, in code. But the rule's default mode is `active`, whose blurb is *"a plan the FMS
has hidden from the website is still published"* — and on this provider that is **27,488 of
31,393 concessions**, including every staff, military and senior plan the operator deliberately
keeps off the portal. `website-visible` is what Yardi actually does, but a rule default is one
value for all providers, so listing this would either put internal staff discounts on 284 public
websites or change what storEDGE publishes. Legacy's filter is reproduced as an **invariant** and
COUNTED (`notOnPortal` / `inactive`) so the number has a home even though no dial explains it.

**`exclude-from-api`** — checked rather than assumed, because that rule's own provenance records
the legacy sweep getting this wrong for storEDGE. Yardi has no website-exclusion field on either
API: the floorplan carries `InsNotRequired` (an INSURANCE flag) and nothing else, and legacy's
Yardi job never writes `exclude_website` — measured `0` on all 3890 rows, which is the column
default rather than an answer.

**`amenity-attributes`** — the question is not real here. SSM earns it because climate and drive-up
exist only inside free-text attribute names; Yardi's `Climate`/`Door`/`Access`/`Feature`/`Size` are
their own columns and legacy already derives four values from them, so there is nothing to
arbitrate and the derivation runs unconditionally.

### `monument` is now the ONLY rule-less provider

Nine guard assertions across three test files asserted `yardi` had no rules and no field catalog.
All were **moved to `monument` with positive assertions added for Yardi's set** — never weakened.
Each now says it is using `monument` as an EXAMPLE rather than asserting rule-lessness as a
property, and adds an `"not-a-provider"` case, so the next provider to grow a normalizer **deletes**
the example rather than moving it a fourth time.

---

## Verification — five columns

### Column 1 — legacy raw → legacy published, with v4 removed entirely

`YardiFacilitiesSyncJob.php` (298 lines) and `YardiFacilitiesUnitSyncJob.php` (701 lines)
transcribed into JS and run over legacy's own mirrored raw feed, then compared against legacy's own
published output. Nothing of ours in the comparison.

```
284 facilities · EXCLUDED_UNITS dropped 10
units      47 fields × 3890 rows = 182,830 comparisons ·  0 mismatches
discounts   5 fields × 3405 rows =  17,025 comparisons ·  0 mismatches
rows only in legacy 0 · only in the transcription 0
STALE (legacy residue) 375 — entry_location 157, features 187, door_type 31
```

**21 of 21 perturbations caught, negative control held.** The pass found two real harness bugs,
neither visible by reading:

- **the boolean comparison coerced.** `Boolean(a) === Boolean(b)` made every truthy value equal
  `true`, so corrupting `is_rentable` to the string `"true~"` reported CLEAN. Same class as the SSM
  harness's `'004' === '4'`.
- **the row-level assertion's own regex could never match** the padded output it was testing, and
  reported a working `__drop_unit` check as a miss.

### Columns 2 vs 3 — the real normalizers over the same mirrored rows, offline

One snapshot feeds both sides, which removes the drift two live runs carry.

```
284 facilities compared · v4 enumerates 284, legacy lists 284

units      34 fields × 3890 rows = 132,260 comparisons · 0 MISMATCH · 188 stale
features   set comparison × 3890 rows                 · 0 MISMATCH · 187 stale
discounts   9 fields × 3405 rows =  30,645 comparisons · 0 MISMATCH ·   0 stale
detail     23 fields ×  284 rows =   6,256 comparisons · 0 MISMATCH · 890 stale · 276 thinner · 294 improvement
feed       16 fields ×  284 rows =   4,544 comparisons · 0 MISMATCH

rows only in legacy   units 0 · discounts 0 · facilities 0
rows only in v4       units 0 · discounts 0 · facilities 0
```

**173,705 comparisons, 0 mismatches, 0 rows on either side only.** Every difference is classified
and reported, never hidden:

| bucket | what it is | where |
|---|---|---|
| stale | legacy frozen at a value the feed has since changed | detail 890 (`site_name` 283, `timezone` 283, `email` 281, `address1` 29, …), units 188 + features 187 |
| **thinner** | legacy states it and the CURRENT feed does not, so v4 publishes null | **`phone` 276** — the number that decides whether a page is safe on this lane, which is why it is counted apart from staleness |
| improvement | the feed states it and legacy publishes empty | `country` 284, `address2` 5, `location_code` 3 (the case fix), `phone` 2 |

**32 of 32 perturbations caught, both negative controls held.** This pass found the third harness
bug, and it is the most instructive: **seven cases reported CLEAN because the write-once staleness
classifier absorbed them.** A classifier that can explain away any difference has no detection
power, so the frozen fields got a `feed` column — v4's output against the RAW FEED, unclassified —
and that column then reported clean for a second wrong reason: it compared the output against the
same object the perturbation had already mutated. Snapshotting the feed first is what made the
claim the right way round.

### Column 4 — the CONSUMERS

The five readers fixed on 2026-09-02 were measured for SSM and SiteLink; nothing had checked them
against a Yardi row.

```
3890 units joined across 284 facilities

typeToken / facilityId / unitTypeId / discountId / internetPriceEnabled   same 15560  DIFFERENT 0
quotedRate(standard_rate | web_rate | push_rate | tiered_rate)            same  3890  DIFFERENT 0  each
providerUnitTypeId / providerDiscountId / internetPriceEnabled(canonical) same  3890  DIFFERENT 0
providerFacilityId — 280 distinct pairings, every one matching

isUnitAvailable disagrees on 0 of 3890 · availableCount disagrees on 0 of 3890
CLEAN — 0 consumer-visible differences over 3890 units
```

**Two differences are INTENDED and reported apart from the total**, because folding either in would
make the honest answer look like a defect and invite a "fix" that sends Yardi an id it cannot
resolve:

- `canonicalUnitId` — `CanonicalUnit.id`, which on v2 is legacy's `location_units` ROW id
  (`5986118`) and on v4 the provider's own (`ut000001`). Every provider differs here.
- `providerUnitId` — **Yardi is special here.** v4 answers the numeric `id_type` (`1660`); v2
  answers legacy's `unit_id`. Legacy's own lead capture then re-reads `unit.unit_type_id`
  (`YardiLeadCapture.php:178`), which is the same `1660` — so the two lanes send Yardi the same id
  by different routes, and v4 is the one that states it in the field whose contract says so.

**8 of 8 perturbations caught, negative control held** — and this pass found the fourth harness
bug, which is the sharpest of them: **a number reported apart from the total must still be
ASSERTED, or it is decoration.** Dropping `providerId` made `fromV4Unit` fall back to `id`, so
`providerUnitId` agreed with v2, the intended-difference count collapsed to zero, and the run still
said CLEAN. The lane had silently stopped sending the id `getcontinueapplicationurl` resolves —
the exact failure the file was written to prevent. Three counts are now pinned.

Its first version also transcribed the **pre-fix** consumer (copied from the SSM harness) and
reported 23,340 differences against a lane that was correct — the same mistake in the mirror.

### Column 5 — the LIVE artifacts, which is the only column that reads what the client wrote

The column the first four could not be: it reads the files on disk that a consumer would fetch.

```
10 facilities · 112 units joined
STABLE   15 fields × 112 rows = 1,680 comparisons · 0 MISMATCH
discounts 112 agree · 0 moved · only in v4 0 · only in legacy 0
rows      only in v4 0 · only in legacy 0
volatile  331 agree · 5 moved between the two runs
```

The five are `vacantCount` on four facilities, over a 100-minute gap between v4's run and legacy's
— real inventory movement, and the fact that it moves is itself evidence the lane reads live data.
Each side's mtime is printed on every row for exactly that reason.

**Before the mapping fix this column reported 33 mismatches, all on facility `400019` alone**, and
tracing them is what found the duplicate-mapping defect.

### The live run

```
verify   ok: true — Voyager SOAP + RentCafe RentV2 reachable (1063 property mapping(s))
sync     10 locations, 0 failed, 112.8s
         facility-filter only-matching on code contains "40001" — 10 of 284 enumerated
```

Scoped to ten facilities deliberately, and the restraint is the point: a full run is 284 facilities
× (`AvailableUnits` + `getunittypes` + one `GetUnitTypeMoveInCharges` per floorplan) ≈ **4,500
requests against a customer's production Voyager** to check our own arithmetic, which the SSM
handoff already ruled out doing. The ten are all Canadian (so `country`/`country_id` is exercised)
and two carry ids from the exclusion list.

Credentials written through the sanctioned `PUT …/api-sources/{id}/credentials` route, ten keys, the
other six left to their code-side defaults so the defaults stay exercised. The route's own readback
confirms **`hasGlobalDefault: false` on all ten**: Yardi has no env fallback, so a wrong value fails
in a way that looks like a dead account.

**Staleness check passed** on every live run: the api child pid's start time was compared against
the newest source mtime and the contract dist before trusting any result. One run was invalidated
by it — a sync started before the supervisor restarted the api mid-edit, leaving a job row `active`
that the process no longer owned, so the next sync reported `alreadyRunning: true` and did nothing.

### Gates — re-measured, not assumed

```
npx vitest run                   549 files, 10506 passed, 11 skipped
packages/api pnpm test  main     244 suites, 3303 passed, 2 skipped
                        wasm      46 suites,  753 passed
pnpm -r --if-present typecheck   7/7 clean
```

Both jest lanes were run. `pnpm lint` fails at HEAD with pre-existing problems and was not chased.

### The two settled §9 gaps

- **`ServerName`/`Database` are byte-identical on this operator.** `sha256(YARDI_SOAP_SERVER_NAME)
  === sha256(YARDI_SOAP_DATABASE)`, so the documented swap is **unobservable here** — whichever way
  it is wired, the same string goes into both elements. That is not "confirmed correct"; it is
  "provably cannot matter for this operator, and cannot be tested by them either". The v4 code
  preserves legacy's wire placement and says so.
- **The live host is `www.yardipcf.com`**, path segment `002389avelcl`, and the configured URL
  carries `?WSDL` — which `soapClient.ts` already strips, and needed to.

---

## What is still missing

1. **`getcontinueapplicationurl` is still absent from the vendored swagger**, and the checkout
   redirect the whole rental flow depends on is known only from legacy. Out of scope for these
   three lanes; do not build on it as though it were specified.
2. **The two NEGATIVE `discounted_rate` rows.** `usmm3511 / ut001476` and `ut001477`: a $35 fee
   waiver subtracted from a $24 and a $32 rent. Reproduced and counted; the fix needs a field Yardi
   does not publish, or an operator naming that concession as a fee.
3. **`phone` thins on 276 facilities.** Legacy publishes a real facility phone that the current feed
   does not state. Nothing renders `v4_api_location` except `location_code` today, so it costs
   nothing yet — but a `v4_api_location`-backed contact block would lose them.
4. **`email` is `CDR@yardi.com` on 278 of 284.** Reported every run. The fix is in Yardi, where the
   data lives.
5. **Weekly rates have no contract home.** Six weekly figures ride in `raw`. If a component ever
   needs them canonically, `CANONICAL_RATE_FIELDS` is where that decision goes.
6. **CURRENCY is unanswered, and 67 facilities depend on it.** Yardi reports no currency anywhere in
   either API — not on the property, not on the floorplan, not on a concession. `country` is now
   published (and `country_id` derived), which is the closest thing to an answer that exists, and
   `CanonicalUnit` still carries no currency field. A CAD rate rendered as `$84` beside a USD one is
   wrong money on a page. **Not invented as a side effect of this lane**, per the brief; recorded
   here with the count.
7. **`ILS_Unit` is unparsed.** Per-unit inventory with `UnitOccupancyStatus`, `UnitLeasedStatus`,
   `RentReady` and per-unit rents, 26 elements on one facility. A real future lane at a finer grain
   — but no Yardi call accepts a per-unit id, so it could inform a display and not a rental.
8. **`UnitTypeOccupancyPercent` is a field nobody documented.** Present on live floorplans (98.55
   measured), absent from legacy's DTO and from `soap-AvailableUnits.md`. Carried through so the
   census names it; nothing reads it.
9. **`facility-filter`'s conditions live on an OVERRIDE, not beside the rule set.**
   `applyFacilityFilter` reads `overrides.filter(o => o.rule === 'facility-filter').flatMap(o =>
   o.when)`, so the mode is connection-wide and the thing it matches on is a scoped exception. It
   works, and it is a surprising split to configure by hand.
10. **The 78 excluded ids and the rounding setting are not yet on the production connection.**
    Until they are, the measured exposure is 10 floorplans appearing (one bookable) and 52
    dimensions rounding. One config write.
11. **The `zTest` marker match is a name match.** No structured field exists. It breaks a tie rather
    than dropping, every ambiguity is named on the job row, and nine tests pin it — but if Yardi
    ever ships a real property whose name starts with `zTest`, this prefers the other one.
12. Two repos, two commits, never one — and `atlas/` pushes to `storagely-home-base`.

---

## Files

**Server** (`apex-app`)

| File | Change |
|---|---|
| `syncs/fms/normalize/yardi.ts` | **new** — `normalizeYardiLocations`, `normalizeYardiDetail`, `normalizeYardiUnits`, `normalizeYardiDiscounts`, `indexYardiUnitTypes`, `yardiUnmappedProperties`, `yardiDetailCensus`, `yardiMoveInFee`, `parseConcessionFooter`, the three censuses, four allow-lists |
| `syncs/fms/yardi.ts` | the stub replaced — the two-leg enumeration, the reconciliation join, the fan-out, bounded move-in-fee reads, three census notes |
| `syncs/fms/client.ts` | `FMS_LANE_SUPPORT.yardi` — `detail`/`units`/`discounts` true, each `false` reasoned |
| `fms-yardi/soap.ts` | **`parseAvailableUnits`** — the MITS document → the floorplan DTO. The thing whose absence published zero units |
| `fms-yardi/merged.ts` | **`indexMappingsByCode`** — deterministic mapping selection, shared with the lead path |
| `fms/soapUtil.ts` | `elementToValue` keeps attributes on a childless element. A shared-helper bug that cost four rent ranges and the sqft on every Yardi floorplan |
| `rental-contract/units.ts` | `fromV4Unit` reads an explicit `providerId`; `providerUnitTypeId`'s comment records that Yardi needs no fourth spelling |
| `rental-contract/sync-rules.ts` | `SYNC_RULE_SUPPORT.yardi` — six rules, fourteen omissions reasoned |
| `rental-contract/sync-fields.ts` | `SYNC_FIELDS.yardi` — `code`, `name`, `country` |
| `api-sources/apiSourcesRoutes.ts` | `syncRules` accepts `unitIds`/`facility`, closing an asymmetry the contract already forbade |
| `scripts/probe-yardi-floorplans.mjs` | **new** — one read-only `AvailableUnits`, prints the wire shape, `--save` captures it |
| `scripts/probe-yardi-mappings.mjs` | **new** — read-only `getpropertymappings`, counts the duplicate codes |

**Tests**

| File | What |
|---|---|
| `__tests__/services/api-sources/fmsNormalizeYardi.test.ts` | **new** — 52 tests: the grain, both ids through `providerUnitId`, the weekly×4 arithmetic, the fabricated counts NOT reproduced, the concession filter, the footer parse, the rules |
| `__tests__/services/fms/yardiAvailableUnitsParse.test.ts` | **new** — 23 tests over a REAL captured response: the attribute-only elements, one-vs-many, the DTO mapping, and nine on `indexMappingsByCode` |
| `__tests__/services/api-sources/syncs.test.ts` | the yardi stub assertion replaced by two: `incomplete` on a failed leg, and the two blank lanes carrying a reason |
| `tests/fms-sync-rules.test.ts` · `tests/api-source-sync-pipeline.test.ts` · `tests/fms-sync-conditions.test.ts` | nine guards moved to `monument`, positive Yardi assertions added, plus a new guard that every `facility-filter` claimant has a facility vocabulary |

**Harnesses** (gitignored `packages/api/tmp/yardi-crosscheck/`)

`column1.mjs` + `prove-column1.mjs` · `crosscheck.ts` + `prove.mjs` · `consumer.ts` +
`prove-consumer.mjs` · `live-check.ts` · `parse-check.ts`

**Workspace** (this repo) — this handoff, plus `README.md`, `open-items.md` and
`troubleshooting.md`.
