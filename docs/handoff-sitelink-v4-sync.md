# HANDOFF — the SiteLink v4 location + unit sync

Session of 2026-08-28. Successor to
[docs/handoff-tier-rate-crosscheck.md](handoff-tier-rate-crosscheck.md); succeeded by
[docs/handoff-ssm-v4-sync.md](handoff-ssm-v4-sync.md), which did the same for SSM and answered
open item 6 below.

---

## ⚠️ READ THIS FIRST — what actually shipped is NOT what this doc describes

Written 2026-09-01, from the session that landed SSM. **This document describes five SiteLink lanes
going live. Three of them never did, and the two that did took a different route.** The body below
is left intact because its measurements are still the reference for this provider — but its "What
shipped" section is a record of one session's branch, not of what reached `main`.

| Lane | This doc says | Actually on the branch today |
|---|---|---|
| `detail` | on | **off** |
| `units` | on | **off** |
| `discounts` | on | **off** |
| `insurance` | on | **on**, but only after a separate review — see below |
| `catalog` | on | **on**, and only behind a filter that did not exist when this was written |

**What happened.** 39 minutes after this session's SiteLink commit (`c227bba5`, 16:58), a second
commit landed on `main` — `3f97ef72`, *"the SOAP namespace that made every SiteLink call fail, with
both lanes held blank"*. It took the transport fix and **nothing else**: `detail`, `units` and
`discounts` were never carried across, and `insurance` and `catalog` were explicitly set false. The
reason is in that commit and it is a good one:

> `ChargeDescriptionsRetrieve` is SiteLink's whole CHARGE catalog, not a curated add-on list, and no
> column separates a sellable service from a penalty. **35 of 96 service items on a real facility
> are fees** — `Late Fee` $20, `NSF Fee` $25, `Auction Fee` $75, `Lock Cut Fee` $90,
> `Administrative Fee` $29, `Security Deposit`. And an unconfigured checkout **offers everything**
> (`rental-contract/catalog.ts`), so those would reach a tenant as monthly add-ons.

Since no SiteLink call had ever succeeded, no location had ever had either artifact — so turning
them on was switching them on for the FIRST time, on live checkouts, in one sync cycle. That is a
content decision, and it was rightly kept out of a transport fix.

Both have since been released, one at a time, on
`feat/sync-conditions-and-email-verification` (PR #1166):

- **`06cff2ac` — coverage on.** It was held for a look, not for a defect. A live
  `InsuranceCoverageRetrieve` returns a clean protection ladder: five tiers, one named underwriter,
  $2,500 → $20,000 of coverage at $13 → $103 a month, monotonic in both.
- **`8e9dea5e` — catalog on, behind a filter.** See the next section.

`detail`, `units` and `discounts` remain **off** and are the open item this doc's own body is the
best guide to. Note what turning `units` on would arm: the reader gap recorded as open item 10 in
[handoff-ssm-v4-sync.md](handoff-ssm-v4-sync.md), which is provider-independent.

---

## The catalog filter — how the fee problem was answered

`normalizeSitelinkCatalog` now separates merchandise from penalties on **`sChgCategory`**, which is
SiteLink's own enum and the same field the discount lane already reads to tell a rent concession
from a POS one. Not a match on the words in `sChgDesc` — that is `SitelinkLockHelper`, the thing
this lane exists to replace.

**It is the only candidate that works.** Measured against the same 96 live charge rows:

| Field | Distinct values | Values mixing sellable with fee |
|---|---|---|
| **`sChgCategory`** | 51 | **0** ✅ |
| `iPriceType` | 2 | 1 |
| `bPermanent` | 2 | 2 |
| `bApplyAtMoveIn` | 2 | 1 |
| `sCorpCategory` | 10 | 2 |
| `ChartOfAcctID` | 30 | 2 |

`Recurring1`–`Recurring13` publish as services, `POS` as one-time items, and the 33 named fee and
accounting categories (`LateFee1`–`5`, `NSFFee`, `AuctionFee`, `LockCutFee`, `AdminFee`, `SecDep`,
`Rent`, `Mob_*`, `*_Dismssd`, …) are withheld and counted by name.

**A second clause came out of testing the first.** Filtering by category alone still published nine
EMPTY slots: SiteLink ships thirteen recurring slots whether an operator uses them or not, and 9 of
13 read `Recurring Charge 5`…`13` at $0. A tickable *"Recurring Charge 11 — free"* is the same
problem in different clothes. The test is structural rather than a name match — an unconfigured slot
still carries the provider's default label, so `sChgDesc === sDefChgDesc`. It separates **13 of 13**:
the nine unconfigured are equal, and the four real ones (`Water and Electric`, `24 Hour Access`,
`Blankets`, `Shelving`) are not.

Measured end to end, the real normalizer over that facility's real published rows:

| | Before | After |
|---|---|---|
| Items offered on an uncurated checkout | 127 | **64** |
| Fee-looking items among them | 28 | **1** |

What remains is merchandise — boxes, bubble wrap, padlocks, dehumidifiers, packing kits — plus the
four configured recurring services.

**A separate bug the work exposed.** The two retail feeds were being de-duplicated by id only, and
they share **zero ids and only 5 titles**: `POSItemsRetrieve` returns 31 items, the POS-category
charge rows 43, and they are complementary catalogues (mattress bags and dish boxes on one side,
dehumidifiers and padlocks on the other). The id-only subtraction removed nothing. Both now publish,
de-duplicated by id AND by normalised title.

The census reaches the job row as `catalogNote` — never the artifact, which is CDN-public. It
answers both *"where is my Late Fee"* and, more usefully, *"you did not publish something I sell"*.

### What it deliberately cannot classify

- **Seven uncategorised rows**, and they are genuinely mixed: `Cleaning Fee`, `Mailing Fee`,
  `Key Charge`, `Cut Lock Letter` and `Transferred Rent` are charges, but `24 hour access` ($15) and
  `Davinci Lock Rental` ($50) are things the operator plainly sells. Nothing in the row separates
  them, so the allow-list fails CLOSED and names every one. Offering a cleaning fee is a worse error
  than withholding a lock rental — but the second is a real cost, and the census is how it gets
  noticed.
- **One $0 row still publishes**: `Auction Unit (Abandoned units)`, from `POSItemsRetrieve`, which
  returns no `sDefChgDesc` — so no structural signal exists for it.
- **Validated on ONE facility.** The categories are SiteLink system enums, so they should hold
  everywhere; that is reasoning, not measurement. Gate 5's is the only SiteLink charge feed
  available locally.

### The scope this changes, stated plainly

`SitelinkRentalAddonHandler.php` is legacy's answer to the same question, and it offers far less:
`LEDGER_SERVICE_ITEMS` is **empty** in the base class, so the recurring block never runs at all, and
POS is filtered to smart-unit items only. The four operators with subclasses each carry a ONE-item
allow-list (`24 Hour Access`, `Smart Unit Service`, `Smart Unit Monitoring`). Gate 5 has no subclass
and no smart-unit POS row, so **legacy offers it zero add-ons today.**

So this is 0 → 64, not a like-for-like restore. That is the v4 model working as
`syncs/fms/client.ts` states it — *"everything is ingested and the OPERATOR curates"*, replacing
four hardcoded per-customer name lists — but it is a change in kind, and worth knowing before the
first SiteLink checkout renders an add-on section.

---

## The headline, before anything else

**No SiteLink operation had ever succeeded from v4.** `fms-sitelink/transport.ts` signed every
envelope with `http://tempuri.org/`; the service's real namespace is
`http://tempuri.org/CallCenterWs/CallCenterWs`, and all **534** operations in the WSDL agree on
it. SiteLink answers the wrong one with a SOAP Fault naming the `SOAPAction` header.

That is one constant, but it changes how to read everything that came before it:
`FMS_LANE_SUPPORT.sitelink` has reported `insurance: true, catalog: true` since those lanes were
written, and both were **fetching and failing on every run**. The flags were honest about the code
and wrong about the outcome, and nothing said so — a provider whose every read fails soft is
indistinguishable from a provider with no data.

Legacy never met this: PHP's `SoapClient` reads the namespace and SOAPAction out of the `?WSDL`
URL. A hand-built envelope has to be told. The 55 endpoint docs' copy-paste cURL samples carried
the same wrong value and are corrected with the code.

Symptom → cause is now in [troubleshooting.md](troubleshooting.md#every-sitelink-call-fails-and-the-error-names-an-http-header).

---

## What shipped *on this session's branch* — see the banner above for what reached main

Three lanes, real: `v4_api_location`, `v4_api_location_units`, `v4_api_location_discounts`.
`FMS_LANE_SUPPORT.sitelink` now reads `detail/units/insurance/catalog/discounts: true`.

> **Superseded.** Only the transport fix went to main, and these three lanes are OFF today.
> `insurance` and `catalog` were released separately later, the catalog behind a filter. Everything
> below is still the reference for HOW these lanes work when someone turns them on.

| Lane | Reads | Note |
|---|---|---|
| detail | `SiteInformation` | **not** the corp-wide list legacy uses — see below |
| units | `UnitTypePriceList_v2` + `UnitsInformation_v2` | type grain, per-unit attributes joined on |
| discounts | `DiscountPlansRetrieve` | legacy's narrow join, priced off the units lane |

### The GRAIN decision: a row is a unit TYPE

Confirmed with Chrys before any code was written. `UnitTypePriceList_v2` returns one row per
**(unit type × size)** bucket — 14 rows describing 277 physical units on Gate 5 — and the row's
identity is `UnitID_FirstAvailable`, the first vacant unit of that bucket.

Four things say type grain, and all four are checked rather than assumed:

1. **The consumers already know.** `components/sdk/unit-data-mapping.ts:385` and
   `snap-sizer-engine.ts:369` branch on `apiType === "sitelink"` to net `total_reserved` out of a
   bucket count. Nothing in the repo treats a SiteLink unit row as one unit.
2. **It is the id the FMS rents.** `checkout-submit/sitelink/quote.ts:21` and
   `reservation-submit/sitelink/payload.ts:98` send `providerUnitId(unit)` as `iUnitID`; on the
   canonical lane `providerId === id`. This is exactly what legacy rents today.
3. **`ConcessionID` exists only on the type row.** The per-unit record carries no concession at
   all, so a real-unit grain would lose the discount linkage or have to re-derive it.
4. **The per-unit endpoint carries sitting tenants** — `dMovedIn` on 252 of 277 rows, plus
   `iDaysRented`. `v4_api_location_units` is CDN-public at a derivable URL.

The lane was **already mixed-grain** and this does not make it more so: Monument publishes one row
per unit GROUP, storEDGE one per unit. What every provider owes `CanonicalUnit` is that `id` is
what a move-in must send, and all three keep it.

**The cost, stated rather than inherited silently.** `UnitID_FirstAvailable` can name a unit that
is already rented: **109 of 6784 measured rows** have `iTotalVacant > 0` while
`bRented_FirstAvailable` is true. A move-in against those ids fails at the FMS. Legacy has this
defect today; the lane reproduces it and **counts it every run** (`census.staleFirstAvailable`,
surfaced on the job row). Fixing it needs the real-unit lane, not a patch.

### Availability: both of legacy's two answers, computed once

Legacy computes SiteLink availability **twice, differently**:

| Layer | Formula | Where |
|---|---|---|
| A — the sync | `iTotalVacant > 0` | `SitelinkFacilitiesSyncJob.php:323` |
| B — the render | `(total_vacant - total_reserved) > 0` | `components/sdk/unit-data-mapping.ts:385` |

They disagree exactly when reservations hold a bucket's last free units — live on **380 of 6784**
rows. `CanonicalUnit` already has the vocabulary to keep both without picking a winner, and its
contract says which is which:

```
available          iTotalVacant > 0                      Layer A, unchanged
availableForMoveIn iTotalVacant - iTotalReserved > 0     Layer B, unchanged
rentable           iTotalVacant > 0                      legacy's is_rentable, unchanged
vacantCount        iTotalVacant                          raw, so nobody double-subtracts
```

Both numbers survive, both are computed once at sync time, and no renderer re-derives either.
That is the Layer-A/Layer-B divergence `sync-rules.ts` calls legacy's worst defect, removed
without changing either number.

### The detail lane reads `SiteInformation`, which legacy never calls

`get_site_information()` exists at `Sitelink.php:200` with **zero callers**; legacy builds its
location row from the corp-wide `SiteSearchByPostalCode` list. That list is the wrong shape for
this pipeline — the per-location child sync is handed a `locationCode` and nothing else, so
reading it here would mean one identical whole-portfolio read per facility.

Safe because the two agree: **all 26 shared public fields are byte-identical** on the probed
facility. Two spelling traps come with the swap and both are handled — `sSiteFAX` here vs
`sSiteFax` on the list, and `sSitePostalCode` arriving as a bare integer for numeric US postcodes.

**Gains** `iGMTTimeOffset` + `iDST` (legacy left `'timezone' => …` commented out at `:113` for
want of a source) and `bSiteDisabled` + `bArchived`. **Drops** `sDivName`/`sDivDesc`, which
`SiteInformation` does not return — a privacy improvement, not a regression: on live data
`sDivName` reads `"FL - <a named regional manager>"`, and legacy published it.

**Withholds** roughly a third of the 86 fields: `bSubscription`, `bTrial`, `iSiteLinkStoreTier`,
`sSLBillingRef`, `iFeatMaxUnits` and the whole `bFeat*` entitlement block. Publishing which
SiteLink modules an operator pays for would be a commercial disclosure about a third party's
contract, on a public URL.

### Office hours: a wrapped window becomes null

SiteLink's office hours are frequently a wrap — an end at or before the start — which is how "not
configured" reads on the wire. Measured across 89 production facilities:

| Window | Count |
|---|---|
| `23:00:00 → 22:59:59` | 59 |
| `21:00:00 → 20:59:59` | 3 |
| end before start (`08:00→06:00`, `09:30→06:00`, `08:00→05:00`) | 3 |
| `00:00:00 → 23:59:59` — a genuine 24h facility, **not** a wrap | 2 |

**65 of 89 wrap.** Published verbatim a page renders *"Open 11:00 PM – 10:59 PM"*, which is worse
than saying nothing. The test is `end <= start`, per DAY, so a real all-day window survives and a
site with real weekday hours and an unset Sunday keeps the weekday pair.

Nothing is lost by being cautious: **all 89 facilities have `is_custom_office_hours = 1`**, so
legacy overrode the FMS hours with its own CMS values on every one. They have never reached a
published artifact. Office hours are operator content and their v4 home is Atlas.

### The discount lane keeps legacy's NARROW join, and the reason is measured

Legacy joins a plan to a unit on one equality — `plan.ConcessionID === unit.ConcessionID` — where
the unit's concession is the unit type's default plan. SiteLink also returns `ConcessionUnitTypes`,
a real plan→unit-type association (3212 rows across 89 facilities), and legacy's *render-time*
handler joins on that instead — a second implementation disagreeing with the first.

Widening is deliberately **not** done here:

**69% of plans do not discount rent.** `sChgCategory` across 1177 production plans: `POS` 808,
`Rent` 357, `AdminFee` 12. The narrow join never meets the non-rent ones, because a unit type's
default concession is a rent concession — verified end to end: **all 5603 published
`v2_api_location_discounts` rows matched a `Rent` plan, zero exceptions.** A wide join would start
applying a POS concession's percentage to a unit's rent, so widening needs a category filter and a
rule to arbitrate it. `sChgCategory` is published on every row so that decision can be made from
the artifact; the census counts the associations the narrow join leaves unused.

**`discounted_rate` is priced off `standard_rate`**, which is legacy's base — and which diverges
from the storEDGE lane's argument that a unit's price and its discount must have one derivation.
Legacy-exact wins because it is measured (below), and the two rates differ on only 133 of 6784
rows. Named as an open item rather than silently corrected.

**Legacy's two rounding quirks are reproduced and named:** the percentage is rounded *before* it is
applied (`round($dis['dcPCDiscount'])`, so a 2.5% plan discounts 3%), and a fixed discount under
half a dollar is ignored entirely (`round($dis['dcFixedDiscount']) != 0`, so the only non-zero
fixed discount in the sample, `0.01`, leaves the rate untouched). Both are what live sites publish
today; a silent correction would move prices on the next sync with nothing to point at.

### Rules: six, and the shortness is the claim

`SYNC_RULE_SUPPORT.sitelink` lists `duplicate-ids`, `exclude-from-api`, `minimum-rate`,
`dimension-rounding`, `unit-sort`, `named-units` — all unit-scoped, all legacy-exact at their
defaults. The eleven omissions are recorded in the table's own comment with a reason each; the
short version is that SiteLink's feed cannot answer their questions (no unit `status` — a row is a
bucket with counts; no tier table; no Storable flag vocabulary; no channel rate).

`exclude-from-api` is the one worth noting: SiteLink genuinely has a website-exclusion flag,
`bExcludeFromWebsite` on the per-unit record, which legacy **read and stored but never filtered
on**. The rule's blurb no longer names one vendor.

**No `discount-visibility` rule.** SiteLink carries two visibility-shaped fields — `iShowOn`
(0 = all screens, 1 = move-ins only, plus an undocumented `2` on 26 of 1177 plans) and
`iAvailableAt`, a channel bitmask. Their semantics are known only from one operator's render-time
subclass, whose filter would drop **890 of 1177 plans (76%)**, and whose companion "activation
check" reads `$plan['dDisabled']` — a key present on **0 of 1177** rows, so that guard has never
done anything. Encoding a guess of that size as a rule mode is worse than not having the rule.
Both fields are published on every row.

---

## Verification

Three columns, joined per unit, as the tier-rate work established.

### Column 1 — legacy, live: `._current/gate5-sitelink-crosscheck.php`

The twin of `._current/sp1261-sync-rates.php`. Bootstraps Laravel, makes the job's four reads
through the job's **own** `Sitelink` class — so the SOAP auth, the WSDL-derived namespace and the
envelope are identical — and transcribes every resolution line from `SitelinkFacilitiesSyncJob.php`
with its line number. Writes nothing: no DB write, no S3 export, no queue job. Re-counted
after every run including the negative control below — `site_locations` 1, `location_units` 13,
`discount_by_units` 161, unchanged throughout — and `git status` in that repo stays empty because
`._current/` is gitignored.

**This is the comparison the offline run cannot make.** The offline run fed legacy's own mirrored
rows into v4's normalizer, so it proved the NORMALIZER agrees using legacy's bytes. This runs
legacy's PHP `SoapClient` and v4's hand-built transport independently against the same facility
minutes apart, so it also proves the two TRANSPORTS agree — which mattered more than expected,
because v4's signed every envelope with the wrong namespace until this session and only a live
call could have shown it. It also removes the drift the offline columns carry.

```
14 unit type(s) · UnitsInformation_v2 Table=277 Table4=72 Table5=24 · 12 plan(s)
legacy resolved 14 unit(s) · 6 discount row(s) · 0 DB dimension overrides

both sides publish the same unit ids
both sides publish the same (unit, concession) pairs

CLEAN — 48 fields, 354 comparisons, 0 mismatches
```

**The two columns are 20 minutes apart, not three days.** The v4 side is not the manual sync from
the 28th — it is the scheduler's own output from `20:00:12Z`, read at `20:20Z`. Rates HAD moved in
between (unit `44198`'s push rate went 83 → 84), and the comparison is clean because both sides saw
the moved value. A stale v4 artifact would have failed this, which is what makes the zeros mean
something.

Worth checking that yourself before trusting a future run: compare the artifact's mtime against
the run you think produced it. A silently stale copy is the one way this script can report clean
for the wrong reason.

#### The detector was proved to fire

**48 zeros is not evidence until the check has been shown capable of failing** — troubleshooting.md's
own rule, that a grep which can only produce good news is not a check. So one value was perturbed
in each of eleven places in the staged v4 copy and the script re-run:

| Perturbation | Caught as |
|---|---|
| a rate +7 | `rates.push_rate` 1 mismatch |
| a unit name replaced | `unitName` 1 |
| a vacancy count +3 | `vacantCount` 1 |
| a joined boolean flipped | `derived.climate` 1 |
| a fabricated feature | `features` 1 |
| a unit id renamed | `only in legacy: 4709` / `only in v4: 999999`, and `checked` fell 14 → 13 |
| city replaced | `location.city` 1 |
| latitude zeroed | `location.latitude` 1 |
| a real hours window nulled | `location.weekday_start` 1 |
| a plan name replaced | `discount.name` 1 |
| a discounted rate +11 | `discount.discounted_rate` 1 |

**All eleven caught, exit code 1.** Restoring the copy returned CLEAN and exit 0. The `checked`
counts falling with the renamed id also matter: they show the tally counts real joins rather than
iterating a set it built from one side.

| Group | Fields | Comparisons | Mismatch |
|---|---|---|---|
| units (incl. the joined per-unit record) | 22 — identity, dimensions, all three rates, occupancy, concession, `derived.*`, `bExcludeFromWebsite`, `features` | 308 | **0** |
| location | 22 — identity, address, contact, coordinates, all six hours | 22 | **0** |
| discounts | 4 — `name`, `discount`, `fixed_discount`, `discounted_rate` | 24 | **0** |
| **total** | **48** | **354** | **0** |

`location.fax` matching is worth its own line: legacy reads `sSiteFax` off the corp-wide list and
v4 reads `sSiteFAX` off `SiteInformation`, and both resolve to the same value — the dual-spelling
read is doing its job rather than sitting there untested.

#### The finding the script made first: legacy cannot read Gate 5 at all

`configures.sitelink_corp_pass` is **NULL** for `users_id=103`, and
`Sitelink::__construct` turns that into `''` (`Sitelink.php:106`). SiteLink answers an empty
password with **`Ret_Code -98`** and an empty result set — isolated independently with
`probe-sitelink-facilities.mjs`, which returns 1 site with the password and 0 without it on the
same corp code and login. So legacy's `get_storage_locations()` returns `false` and its SiteLink
sync for Gate 5 cannot succeed from this database.

That is a fact about the **local snapshot**, not proof about production — this MySQL is a dev copy
and prod's row may carry the password. Nothing here can see prod, and the script says only what it
can prove. The comparison above was run by substituting that one field from `GATE5_CORP_PASS`
through a subclass that overrides `sCorpPassword` and nothing else; the substitution is printed in
the output so no run can quietly look like an unaided one.

### Why the Gate 5 page import was not needed

Resolved and inventoried, but its v4 website reports `hasApiPath: false` — no FMS connector, so it
would have brought down **no FMS artifacts at all**. The prompt's premise that the import gives
"half the verification corpus for free" does not hold for this operator.

A far better corpus was already local: `safeguard-self-storage` is an imported SiteLink operator
with **89 facilities, 6784 unit rows, 1177 discount plans and 5603 published discount rows** of
real production data. Its mirrored `fms_api_*` files ARE legacy's raw upstream rows.

### Column 2 — legacy, as published

`v2_api_location*.json` for those 89 facilities.

### Column 3 — apex v4

The **real normalizer functions** run over the **same raw rows**, offline. This is stronger than
the prompt's plan: comparing two live runs leaves temporal drift in every rate and count, and
feeding both columns from one snapshot removes it.

### Results — units, 6574 joined rows

| Field | Mismatch | |
|---|---|---|
| `unitName`, `typeToken`, `area` | **0** | |
| `raw.UnitTypeID`, `raw.dcAdminFee`, `raw.iFloor` | **0** | |
| `width`, `length` vs legacy's ROUNDED value | **0** | the `dimension-rounding` rule reproduces `number_format` exactly; it fires on 450 rows (6.8%) |
| `rates.standard_rate` | 267 (4.1%) | drift |
| `rates.push_rate` | 312 (4.7%) | drift |
| `rates.web_rate` | 238 (3.6%) | drift |
| `vacantCount` | 195 (3.0%) | drift |
| `available` (= legacy `is_rentable`) | 20 (0.3%) | drift |
| `raw.iTotalUnits` / `iTotalOccupied` / `iTotalReserved` | 127 / 137 / 39 | drift |
| `raw.ConcessionID` | 19 (0.3%) | drift |

**The drift is proven, not assumed.** Every count above matches, exactly, an independent count of
the same disagreement taken straight from the raw JSON before any v4 code ran. The two artifacts
in the prod snapshot were written by different sync runs — which the discount check below settles
beyond doubt.

### Results — detail, 89 facilities

`site_name`, `address1`, `address2`, `city`, `region`, `postal_code`, `country`, `phone`, `fax`,
`email`, `website`, `legal_name`, `latitude`, `longitude`, `business_type`: **0 mismatches, all 89.**

`closed_sunday`: 2 of 89 — both facilities where legacy's CMS override disagrees with the FMS.
Hours are not compared against legacy's, because legacy overrode them on 89 of 89; what IS checked
is that the wrap rule nulls exactly when the FMS window wraps — **89 of 89**.

### Results — discounts, 5307 joined rows

| Field | Mismatch |
|---|---|
| `name`, `discount`, `fixed_discount` | **0** |
| `discounted_rate` | 135 (2.5%) |

And the decisive check: recomputing legacy's formula against **legacy's own unit rate** — removing
v4 from the comparison entirely — reproduces legacy's own published `discounted_rate` on
**5360 of 5467** rows. Of the 107 that do not, **107 have a unit `updated_at` differing from the
discount row's `updated_at`.** Zero exceptions. The residue is legacy disagreeing with itself
across two of its own tables, written by different runs — not an arithmetic divergence.

### The live run — and 10 unattended ones since

Credentials confirmed as Gate 5's by SHA-256 against legacy's own `configures` row (never
printed). Written to `kv_store` through the sanctioned
`PUT …/api-sources/{id}/credentials` route — `fms_sitelink_corp_code`,
`fms_sitelink_corp_username` (secret), `fms_sitelink_corp_password` (secret). Per Chrys, the three
dead `SITELINK_CORP_*` lines in `packages/api/.env` are **left in place for now**; nothing reads
them and they are the wrong lane.

Then, against the live CallCenterWs 3.5 API:

```
verify   ok: true — "1 location(s) reachable"        ← the first SiteLink verify that could ever pass
sync     1 location, 14 unit types read, 14 kept, 0 dropped, 480ms
```

Artifacts written to `fms/client_urls/gate-5/locations/l001/`:

| Artifact | Bytes | Contents |
|---|---|---|
| `v4_api_location` | 1216 | real facility, `gmt_offset: -5`, `observes_dst: true`, no licensing block |
| `v4_api_location_units` | 30912 | 14 types; `derived` on 14/14, `features` on 3/14 |
| `v4_api_location_discounts` | 12631 | 6 rows with a plan (all `sChgCategory: Rent`), 8 default rows |
| `v4_api_location_insurance` | 2873 | |
| `v4_api_location_catalog` | 143280 | the undifferentiated charge feed — expected, see `normalize/sitelink.ts` |

**Staleness check passed**: api pid started 17:15:18, latest source mtime 17:14:12 — the running
process had the code.

**Then it kept running.** The source is enabled, so the half-hourly scheduler has been syncing it
since — **10 recorded runs, 2026-08-28 through 2026-08-31, every one `success` with `failed=0`**,
`conditionEffect` steady at `read: 14, kept: 14, dropped: []`. That is a better result than the
manual run: the lane has survived three days of real feed movement unattended, and the live
cross-check above compares against the scheduler's output rather than against a hand-triggered
one.

### The bug the cross-check caught

Plan rows were emitted without `location_units_id`. `readDiscountArtifact` returns null without it,
so **every SiteLink discount row would have been silently discarded by every consumer** — an
artifact that looks full and reads empty. No test would have caught it; the field-by-field
comparison against legacy did, before one was written. It is now asserted *through*
`readDiscountArtifact` rather than against the object.

### The probe

`apex-app/scripts/probe-sitelink-facilities.mjs` — new, read-only, standalone, five SOAP reads.
It found the namespace bug, and it measured the two shapes nobody here had ever seen:
`UnitsInformation_v2`'s five nodes (**no `Table2`**, so legacy's choice of 4 and 5 is right rather
than lucky) and `DiscountPlansRetrieve`'s `ConcessionUnitTypes`. It prints field names, types and
fill counts, and withholds staff names, tenant occupancy and the operator's funnel counters by
name.

---

## Files

**Server**

| File | Change |
|---|---|
| `fms-sitelink/transport.ts` | **the namespace fix** — with the WSDL evidence |
| `syncs/fms/normalize/sitelink.ts` | `normalizeSitelinkDetail`, `normalizeSitelinkUnits`, `normalizeSitelinkDiscounts`, `indexSitelinkUnitInfo`, four allow-lists, `officeHours`, the census types |
| `syncs/fms/sitelink.ts` | rewritten: five reads, rule resolution, two census notes |
| `syncs/fms/client.ts` | `FMS_LANE_SUPPORT.sitelink` — five lanes true |
| `syncs/fms/normalize/shared.ts` | `sortCanonicalUnits` + `round` extracted here from storEDGE, so unit ORDER cannot drift between providers |
| `syncs/fms/normalize/storedge.ts` | uses the extracted sort; no behaviour change |
| `rental-contract/sync-rules.ts` | `SYNC_RULE_SUPPORT.sitelink` (six rules, with the eleven omissions reasoned); `exclude-from-api` blurb de-vendored |

**Docs**

| File | Change |
|---|---|
| `docs/fms/sitelink/README.md` | the namespace, and why a hand-built envelope must be told |
| `docs/fms/sitelink/endpoints/*.md` | **55 files** — corrected `SOAPAction` header + envelope `xmlns` in every copy-paste cURL |
| `…/SiteInformation.md` | its "captured" response was a `SiteSearchByPostalCode` row; three nodes, 86 fields, the withheld block |
| `…/UnitsInformation_v2.md` | the five nodes, the tick-count cursor, why `Table3` is not a substitute |
| `…/DiscountPlansRetrieve.md` | `ConcessionUnitTypes`, the two joins, the 69%, `iShowOn`/`iAvailableAt` |
| `helix/docs/troubleshooting.md` | the SOAPAction symptom |

**Legacy** (`app-storagely-io`, in gitignored `._current/` — that repo's tree stays clean)

| File | What |
|---|---|
| `._current/gate5-sitelink-crosscheck.php` | the live cross-check above. Read-only; four reads through the job's own `Sitelink`; `--verbose`, `--json=`, `--user=`, `--location=`, `--v4=` |

**Tests**: `__tests__/services/api-sources/fmsNormalizeSitelinkUnits.test.ts` — 52 tests.
Root-suite guards updated: `tests/fms-sync-rules.test.ts` and
`tests/api-source-sync-pipeline.test.ts` both used `sitelink` as their "provider with no rules"
example. Moved to `ssm`/`yardi` and given positive assertions for SiteLink's six, rather than
weakened.

---

## Gates

```
npx vitest run                   451 files, 8680 passed, 11 skipped
packages/api jest                229 suites, 2962 passed, 2 skipped
pnpm -r --if-present typecheck   7/7 clean
```

The root suite caught **6** drift guards this session — the fourth session running in which
`packages/api`'s jest suite alone would have shipped a gap.

`packages/rental-contract` was rebuilt. Restart the dev servers before eyeballing the board.

---

## What is still missing

1. **The real-unit lane.** The only fix for the stale `UnitID_FirstAvailable` (109 of 6784 rows).
   Its own key — `v4_api_sitelink_units` — never a second grain under `v4_api_location_units`.
2. **The wide discount join**, gated on a `sChgCategory` filter. `ConcessionUnitTypes` is read and
   counted but not used; the census says how many promotions it would add.
3. **A SiteLink `discount-visibility` rule**, once `iShowOn` / `iAvailableAt` are confirmed against
   SiteLink's own documentation rather than one operator's subclass.
4. **`rate-source` for SiteLink.** It has five rates (`dcStdRate`, `dcPushRate`, `dcWebRate`,
   `dcBoardRate`, `dcPreferredRate`) and legacy has a `$user_id == 16` branch publishing the push
   rate as standard. That is a rate policy and belongs in a rule with SiteLink's own modes.
5. **The discount base.** Priced off `standard_rate` (legacy-exact); the storEDGE lane prices off
   its resolved `web_rate`. The two rates differ on 133 of 6784 rows. Reconciling them is a rule.
6. **`listLocations` on a large portfolio is still unconfirmed** for SiteLink. The corp-wide search
   returned the one site a one-site corp has, which does not prove it does not cap or geo-filter.
   Compare the count against the operator's own the first time it runs for a portfolio.
   *Answered for SSM, on a five-facility portfolio, in
   [handoff-ssm-v4-sync.md](handoff-ssm-v4-sync.md) — no cap, no geo-filter, and the apparent
   short count was legacy carrying a ghost row for a facility that had left the feed. Still open
   for SiteLink, whose search takes a postal filter SSM's does not have.*
7. **The `corpUsername` is not actually per-operator.** Gate 5's and Safeguard's are byte-identical
   (SHA-256 checked) — it embeds Storagely's own API key. Only `sCorpCode` differs. That makes it a
   candidate for an env default like storEDGE's, which is a change to the credential contract, not
   to this lane.
8. **Check Gate 5's `sitelink_corp_pass` in PRODUCTION.** It is NULL in the local snapshot, and an
   empty password gets `Ret_Code -98` from SiteLink. If prod's row is the same, legacy's SiteLink
   sync for that client has been failing silently and the v4 lanes are the only thing that can
   read it. One `SELECT` answers it; nothing in this workspace can.
9. **`detail`, `units` and `discounts` are still off for SiteLink.** They are built and measured —
   this document is the guide — but they never went to main. Turning `units` on also arms the
   consumer-shape gap recorded as open item 10 in
   [handoff-ssm-v4-sync.md](handoff-ssm-v4-sync.md): `readRate` and `discountId` read a raw row
   with v2 field names, which the canonical shape does not use. That gap is provider-independent
   and would bite SiteLink the moment its units artifact stops being empty.
10. **The catalog filter is validated on one facility.** `sChgCategory` values are SiteLink system
   enums so they should be universal, but only Gate 5's charge feed was available. The first time
   it runs for another operator, read the `catalogNote` census — particularly its
   `uncategorised` list, which is the bucket that can withhold something an operator sells.
11. **`Auction Unit (Abandoned units)` at $0 still publishes**, from `POSItemsRetrieve`, which
   carries no `sDefChgDesc`. Low severity; no structural signal exists for it.
12. Two repos, two commits, never one — and `atlas/` pushes to `storagely-home-base`.
