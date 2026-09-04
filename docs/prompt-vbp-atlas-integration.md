# Prompt — move legacy VBP behaviour into Atlas, one slice at a time

**Written** 2026-09-04, from a session that read the three legacy handlers end to end
(`columbia-self-storage`, `mini-mall-storage`, `safeguard-self-storage`) against the v4 lane and
Atlas's VBP surface. This file is the brief. It is not a handoff — write that at the end.

**Repos.** Atlas work is `atlas/` (remote `storagely-home-base`). Reader/renderer/contract work is
`apex-app/`. Anything spanning both is **two commits in two repos**. Read `atlas/CLAUDE.md` before
your first edit there.

---

## 1. What the legacy handlers actually do

Three PHP subclasses, one consumer: `StepFourController.php:213` hands `vbp` to the Inertia
checkout, and `resources/js/stores/checkout.ts:121` seeds `location_unit_id` from whichever card
carries `selected_by_default`. **The tier cards are a unit swap, not a price toggle** — the same
thing the v4 contract doc says. Registry: `ValueBasePricingService.php:28-38`.

| Behaviour | Where | Notes |
|---|---|---|
| Card price = `web_rate` if `> 0` else `tiered_rate` | `ColumbiaSelfStorageVbpHandler.php:18-26` | parent formats `tiered_rate` then this overwrites it |
| Candidate ordering by that same expression | same, `:13-16` | only picks *which* unit fills a rank; `$processed_ranks` is first-wins and the arrived unit is `prepend`ed |
| Preselect the middle card when >2 tiers | same, `:28-39` | ≤2 tiers falls back to the parent's rank-0 rule |
| Delta pricing: base card absolute, upgrades `+$X more /4 wks` | `MinimallStorageVbpHandler.php:121-172` | one ladder, two display modes |
| Weekly rate × 4, `'/4 wks'` suffix | same, `:144-172` | billing schedule hard-coded to `7` in `MinimallRentalHandler` |
| 26-location "monthly pilot" switching the rate column | same, `:95-100`, `:285-288` | also drives the location-page partial (`LocationPageController.php:783`) |
| `usePushRate()` → SiteLink `bUsePushRate` at move-in | same, `:269-275` → `SitelinkRentalHandler.php:271` → `Sitelink.php:1693` | true when <3 tiers **or** the pick isn't the base unit. The breakdown quote (`getMoveInCostWithDiscount`) carries no such flag — shown and charged can diverge |
| Discounted card price + strike-through "Standard Rate" / "Discounted Rate" | `SafeguardSelfStorageVbpHandler.php:99-134` | the only handler that reads `$this->discount` |
| Short-ladder label shift (`2 - $base_price_index`) | same, `:105` | a 2-card ladder reads Best/Better |
| Tier-conditioned add-ons | `ColumbiaSelfStorageRentalAddonHandler.php` (Smart Unit at rank 2), `SafeguardSelfStorageRentalAddonHandler.php:32-48` (24 Hour Access at `order === 3`) | the add-on reads the VBP result |

Two defects worth carrying, because they change what "parity" means:

- **`SitelinkVbpHandler` reads `self::VBP_ATTRIBUTES`** (`:187`, `:305`), not `static::` — so
  Mini-Mall's and Safeguard's own Best/Better/Good constants are dead and both render the parent's
  Premium/Enhanced/Basic. Don't port a label set by reading the child constant; read what the page
  serves.
- **Mini-Mall assigns `tier_number` ascending over a descending price list** (`:119-135`), the
  opposite of Safeguard's `2 - $base_price_index`. Either the client's `vbp_tier_name` rows were
  entered inverted to compensate, or the priciest unit is being sold as "Basic". Settle this against
  the live tier names before treating either as the spec.

The VBP feature flag is **not** a gate on display: `isVbpFeatureEnabled()` is commented out in both
`StoredgeVbpHandler.php:158-160` and `SitelinkVbpHandler.php:243-250`. `is_tier_enabled` still gates
whether the sync writes `tiered_rate` (`StoredgeFacilitiesSyncJob.php:333`).

## 2. What the v4 + Atlas lane already has

- **Contract** (`apex-app/packages/rental-contract`): `VbpTierSpec` = rank, enabled, name, ideal,
  badge, bullets, **`rateSource`** (`types.ts:346-354`); `unitLocation.settings` = tiers,
  `preselect`, `priceDisplay`, `allowZeroRate`, `floorPlan` (`types.ts:392-420`, read by
  `tiers.ts:138`). `resolveRate` (`units.ts:589`) tries the named column then falls through
  `tiered_rate → web_rate → standard_rate → push_rate`, `> 0` only — which is already Columbia's
  "else" leg.
- **Ladder** (`apex-app/packages/components/sdk/vbp-tiers.ts`): ported from
  `LocationUnit::buildVbpQueryCondition`; dedupes on provider rank when the feed has one and on
  **rate** otherwise, re-indexes to a contiguous 0…n-1 (`buildVbpTiers:191`, `clampRank:400`). This
  is what covers SiteLink, which publishes no tiers.
- **Atlas block**: `value_based_pricing` with an `fms_api` half (read-only gate +
  `allow_enterprise_tiering` + the provider's tiers) and an `atlas` half (heading, supporting,
  `price_labels`, `highlight`, and per-tier `fms_id`/`enabled`/`name`/`ideal_for`/`badge`/`bullets`/
  `icon`/`display_rate_source`). Record: **`apex-app/docs/helix-contracts/value-based-pricing.md`**
  — read it first, it is 227 lines and answers most of what you would otherwise re-derive.
- **Readers**: `edge-checkout-v2-1/vbp-block.ts` parses it, `vbp-overlay.ts` joins Atlas cards to the
  priced ladder on `fms_id` (rank is a fallback), `sections/Vbp.tsx:185-210` applies `highlight`,
  `price_labels`, `heading`, `supporting`. **`base/checkout` has no Atlas reader at all** — contract
  only.
- **Atlas surface**: `ValueBasedPricingConfigPanel.tsx` (rendered from
  `DerivedSettingsPages.tsx:536`, fed `EdgeTiersBlock` from `edge-settings.server.ts:160`) renders
  per-rank copy, a rate-source select, a highlight select and a price-label select — and ends with
  *"Not saved yet — this panel is a layout scaffold while the tier feed is wired up."* Recent Lovable
  commits (`Added Configure tier data`, `Added real tiers to config panel`, `Made FMS tiers
  read-only`, `Moved VBP to subpage`) are the live edge of that work.
- **Persistence pattern to copy**: `atlas_checkout_settings` — one row per `location_id`, one jsonb
  column per block (`autopay`, `move_in`, `tenant_info`, `payment`, `insurance`, `rental_summary`),
  written through `atlas-checkout-settings.functions.ts`, emitted by a
  `helix-<block>-payload.server.ts` builder, assembled in
  `routes/api/public/atlas.accounts.$accountId.locations.$locationCode.ts` behind the same pilot gate
  as `unit_grid`. **There is no `value_based_pricing` column and no VBP payload builder in this
  clone.**

## 3. Slices. One per session-chunk, in this order.

Each slice is independently shippable and independently verifiable. Do not start the next one until
the previous is verified in a browser, not just in tests.

**Cadence, set by Chrys 2026-09-04.** Every slice that touches an Atlas surface opens with **UI
variations to choose from** — sketch the options, get the pick, then build the picked one. Do not
start implementing a panel, control or card layout before that choice exists. Slices with no UI
surface (S0, and the contract-only half of S4.1) skip it and say so.

### S0 — Reconcile prod against this clone. No code. **ANSWERED 2026-09-04.**

Prod emits a populated `atlas` half, and it is written from Atlas's own editor. Nothing is dead and
the panel is not a replacement for the writer — **the panel *is* the writer.**

| | |
|---|---|
| **Table (location rung)** | `atlas_checkout_settings.value_based_pricing jsonb` — added by `supabase/migrations/20260824201658_8c732b78-…sql`, a one-line `ALTER TABLE`, timestamped ~6h after this clone's HEAD |
| **Table (company rung)** | `atlas_company_checkout_settings.value_based_pricing jsonb` — new table, `20260828005931_f45fb819-…sql`, PK `company_id`. Its own `COMMENT` states the rule: a location block that is `NULL` inherits from here, non-`NULL` is a location override |
| **Writer** | `saveCheckoutSettings` (`atlas-checkout-settings.functions.ts:724`, `patch.value_based_pricing` at `:754`, upsert on `location_id`) and `saveCompanyCheckoutSettings` (`:880`, upsert into `atlas_company_checkout_settings` at `:921`) |
| **Caller** | `ValueBasedPricingConfigPanel.tsx:428` — `save({ valuePricing: v })` under `useAutosave`, through `use-checkout-settings.ts`. `CheckoutDefaultsPage.tsx:120` is the company-rung surface |
| **Resolver** | `atlas-checkout-settings-resolve.server.ts` — coalesces the two rungs block by block and reports which one won as `rungs.value_based_pricing` |
| **Emitter** | `helix-value-based-pricing-payload.server.ts` → `buildLocationValueBasedPricingBlock`, wired into **both** public endpoints (location detail `…locations.$locationCode.ts:53,507,579` and the checkout slice) |

**Why the clone showed neither.** `atlas/` HEAD is `38ddfff2a`, 2026-08-24 14:21 UTC; `origin/main`
is `5ffecee03`, 2026-09-04 14:02 UTC — **659 commits behind.** Every file above landed 2026-08-28
(schema, resolver, emitter) and 2026-08-29 (panel, defaults page). The prompt's premise that "this
clone has no emitter and no column" was correct about the clone and wrong about prod, exactly as the
slice predicted. `git fetch` first; anything written against this working tree would have been built
twice.

**Evidence, on the wire.** `GET /api/public/atlas/accounts/account_SsTtwJgWkFksSxX/locations/25e2ece8-668b-467d-934b-81dd0024edbc`
(Clemmons Towncenter Drive, storEDGE, `api_path: storagelyselfstorage`) → 200, 73.6 KB. Top-level
keys include `value_based_pricing` **and** `add_on_services`; both halves present. `atlas.source:
"location"`, `atlas.updated_at: "2026-09-02T17:29:46.529+00:00"` — written two days ago, five days
*after* apex-app's 2026-08-27 observation. Three tiers, each carrying `fms_id` matching an
`fms_api.tiers[].id`, `price_labels: "absolute"`, no `highlight` key.

The same account's Winston-Salem West 3rd Street (`c93036ab-…`) returns 200 with **no**
`value_based_pricing` key at all — and no `unit_grid`, `fms_api` or any other checkout block. That is
the `if (unit_grid)` pilot gate, doing what §"Nothing here fails loudly" says it does. An absent key
here means "not in the pilot", never "misconfigured".

Not re-fetchable: `https://atlas.apps.storagely.io/api/public/atlas/checkout/contracts/value-based-pricing`
still 404s — *"Unknown contract. Available: receipt, payment, storing, add-on-services"*, unchanged
since 2026-08-27. `apex-app/docs/helix-contracts/value-based-pricing.md` remains our record, not
Atlas's word.

Prod's Atlas DB is not readable from here for corroboration: the anon key in `atlas/.env` has no
grants (`42501`, *"permission denied for table atlas_companies"*), so the two-rung storage claim is
**verified in code and in the migrations, inferred on the wire** — the Clemmons payload shows the
`location` rung only. A `source: "company"` payload was not directly observed this session.

#### Five things S0 changes downstream

1. **`display_rate_source: "tiered_rate"` on 87 of 87 tiers is the emitter's default, not authored
   data.** `validRateSource` (`helix-value-based-pricing-payload.server.ts:121`) coerces anything
   outside `tiered_rate | web_rate | standard_rate | push_rate` to `tiered_rate`, and the panel seeds
   `rateSource: t.rateSource || "tiered_rate"`. The contract doc infers from the uniformity that the
   value has not been "authored deliberately"; that inference is now confirmed by construction.
   **S4.2 would therefore be dereferencing a default.**
2. **A disabled tier never reaches the wire.** The emitter ends its tier map with
   `.filter((t) => t.enabled)`, so `enabled: false` is unobservable downstream — the card is simply
   absent. Any reader treating `enabled` as a rendering flag is coding for a state it cannot see.
3. **`atlas.updated_at` is the settings *row*'s timestamp, not the block's.** It comes from
   `row.updated_at` on the resolved row, so saving `payment` or `move_in` moves the VBP block's
   `updated_at` too. Do not use it as a VBP change signal.
4. **`highlight` and `price_labels` are omitted when unauthored**, not emitted as `none`. So Atlas
   can genuinely store and emit `none`, the contract still lacks the token, and **S3 stands as
   written.**
5. **`add_on_services` is live in prod too** (both halves, on the same location) and equally absent
   from this clone. S7 is not starting from zero either — check `origin/main` before designing it.

`offered` is still emitted (`true` on all three Clemmons tiers) and still ignored per Revision 2 Q7.
Unchanged.

### S1 — ~~Persist and emit what the panel already renders.~~ Shipped in Atlas, and **irrelevant here.**

**Every bullet this slice asked for exists on `origin/main` and is live.** Schema (both rungs), write
layer, emitter, `fms_id` on the wire, panel autosaving, scaffold line gone — the remaining
*"Not saved — open this page on a location…"* string at `ValueBasedPricingConfigPanel.tsx:1152` is a
company-scope guard, not the old disclaimer. There is nothing to build here and the original bullets
are struck rather than deleted so the next reader can see what was assumed.

What replaces the slice, in order:

- **Pull first.** `git -C atlas fetch && git -C atlas pull` before reading anything else in that
  repo. 659 commits is not a rebase risk, it is a "you will rewrite work that already shipped" risk.
- **The parity question this slice existed for is answered by S2, not by a curl.** The point of S1
  was to replace the three handlers' `VBP_ATTRIBUTES` constants with operator-editable data. It
  cannot do that for these operators at all: Mini-Mall and Safeguard both ship `base/checkout`,
  which has no Atlas reader, so whether Atlas serves them a populated `atlas` half is **moot** —
  nothing on their pages would read it. Do not spend a session establishing it.
- The operator-to-account mapping that blocked this earlier is now known, from the local mirror's
  own website records: **Mini Mall Storage** is `account_VpRr3kk08TJWZ9x`, **Safeguard Self
  Storage** is `account_ss3hh77hR_CbHCD`. Columbia is not in this mirror.

**Verify**: curl the public location endpoint for each legacy operator's account and record which
return the key, which return it with `atlas: null`, and which omit every checkout block (= not in the
pilot). An Atlas route returning 200 proves nothing; the three outcomes look identical from the
status line.

### S2 — Which checkout the block reaches. **ANSWERED 2026-09-04. `base/checkout`, and it has no Atlas reader.**

Counted over the local mirror's page artifacts (`packages/api/.local-storage`), live `pages/` only —
version history excluded, since it inflates every count several-fold:

| Website | Account | `checkout` | `edge-checkout-v2-1` |
|---|---|---|---|
| Mini Mall Storage | `account_VpRr3kk08TJWZ9x` | **3** | 0 |
| Safeguard Self Storage | `account_ss3hh77hR_CbHCD` | **1** | 0 |
| storagelyselfstorage.com — Storagely's own | `account_FDL4h_6DC5C8Ftp` | 2 | **2** |
| sandbox-testing | `account_ZlfyJ_5YxLPyJzd` | 1 | 0 |
| Local Dev Site | `account_WmMmV9SBCGMH7Yy` | 1 | 0 |

`edge-checkout-columbia-v1` and `cubby-checkout`: **zero** live pages anywhere, consistent with
apex-app/CLAUDE.md calling the first a frozen one-off mockup.

**So `edge-checkout-v2-1` ships on exactly one website, and it is Storagely's own sandbox.** Every
legacy operator present ships `base/checkout`, and `base/checkout` contains no `readVbpBlock` and no
`overlayAtlasTiers` — grepped, empty.

**This is the load-bearing finding of the whole run.** The original plan put S1 (persist and emit the
Atlas copy) first and called it "the slice that pays for itself … it needs **no apex-app change** on
the Edge lane, because `vbp-block.ts` + `vbp-overlay.ts` already read every leaf." Both halves of that
are true and the conclusion still fails: the readers exist, they are just in the component **none of
these operators load**. Had the Atlas path been built as written, the operator copy would have
resolved, emitted, synced and rendered nowhere for Mini-Mall and Safeguard both.

The pivot to Helix checkout settings did not make S2 moot — **it resolved it.** `base/checkout` reads
the contract (`readUnitLocationRules`, and `CheckoutProvider` at `render.tsx:421`), so S5's baseline
and S6's price period reach these operators on the component they actually ship. That is luck as much
as design: the pivot was asked for on other grounds and happened to land on the only lane that works.

**Caveat, stated rather than buried.** This is the local mirror, populated by import from prod, and
it is **not a prod census**. Two limits: **Columbia Self Storage is absent entirely** — the `columbia`
matches in the tree are a city in Mini-Mall's and Storage Star's location lists, not the operator — so
its component is **unverified**; and a website with no imported checkout page contributes no row rather
than a zero. Verified for Mini-Mall and Safeguard; open for Columbia.

### S3 — Vocabulary parity for `highlight` and `price_labels`. **CLOSED 2026-09-04: drop it.**

The slice asked whether to add Atlas's five `highlight` tokens and three `price_labels` tokens to the
contract, or drop them from Atlas. **Drop.** S2 is the argument: those tokens are read only by
`edge-checkout-v2-1/sections/Vbp.tsx:188-209`, which no legacy operator loads, so adding `none` to a
contract vocabulary would be widening an interface for a reader none of them reaches.

The contract keeps `'unitTier' | 0 | 1 | 2` and `'delta' | 'rate'` (`layouts.ts`), both now joined by
`deltaBaseline` from S5 — which is the token that actually earns its place, because it changes what a
card says rather than restating what another token already covers.

Columbia's middle-tier preselect needs nothing from this: `preselect: 1` in the contract does it, the
control has been in `TierRules.tsx` all along, and the plan already noted it "works today either way".

### S4 — The rate column. **DECIDED 2026-09-04: per provider.** Config, not code.

Chrys's call: **`web_rate` on the Edge lane, SSM left alone.** The reason the decision splits is
that the same field has two different blast radii — on Edge the provider prices its own rental, so
`rateSource` moves the card and `prepared.total` but not the charge; on SSM it is sent as `Rent:`
into `GetCostForRental` and does move what the tenant pays. Same key, two risks, so two answers.

**There is nothing to build.** The lever already exists as the per-tier `rateSource` select in
`TierEditor.tsx`, and `ICheckoutSetting` is already `fmsType`-scoped (`types.ts:605` — "a setting
authored against Storedge cannot be assumed valid for Sitelink", and the provider guard is the
matcher's *first* gate). So "per provider" needs no provider dimension added: it is one value set on
the storEDGE settings and not on the SSM ones.

**Do NOT change `resolveRate`'s fallback order.** With no named source it tries
`tiered_rate → web_rate → standard_rate → push_rate` (`units.ts:595`). Reordering that to put
`web_rate` first would move prices on every account that has never named a source — including SSM,
where it moves the charge. The decision is per-setting precisely so it cannot leak that way.

Evidence behind the column choice, unchanged and still the strongest measurement in this file: on one
29-location storEDGE account `tiered_rate` exceeds the provider's whole *taxed* bill on 22 of 22
units (a ratio below 1.0, which no billed rate can produce), while `web_rate` lands 1.0000–1.0663 on
multipliers that cluster on real tax rates the quote itself reports. 699 of 699 cards overstate,
median +$16.

**Still open:** who applies it, and to which settings instances. It is an operator-facing config
change on live accounts, so it wants a named owner and a before/after on one facility rather than a
bulk write.

S4.2 — whether Atlas's `display_rate_source` is ever dereferenced — is **closed by the pivot to
Helix.** S0 also established it would have been dereferencing the emitter's own default
(`validRateSource` coerces to `tiered_rate`), not an operator choice.

### S5 — ~~Mini-Mall's mixed price display.~~ The baseline, not a token. **SHIPPED 2026-09-04.**

**The premise was wrong and the slice got smaller.** This slice said mixed display "needs a third
token in both the contract and Atlas's `price_labels`". It needs neither: `priceDisplay: 'delta'`
**already** renders the mixed shape. Both readers do
`showRate || option.isSelected ? money(rate) : deltaLabel(delta)` — the baseline card prints an
absolute price and every other card prints a signed difference, which is exactly the base-absolute /
upgrades-signed ladder legacy rendered (`base/checkout/sections/Vbp.tsx:214`,
`edge-checkout-v2-1/sections/Vbp.tsx:407`, both as they stood before this change).

What actually differed is the sentence this slice buried in its own last line: **v4's delta baseline
is the arrived unit, legacy's was the cheapest sibling.** That is the whole gap, and it is a real
one — measured from the arrived unit a cheaper tier reads `−$16/mo` and the page offers a saving;
measured from the cheapest card that card becomes the baseline and every other reads `+$16/mo` and
the page sells an upgrade. Identical rates, opposite offers. So the slice is a baseline setting, not
a display token.

**Shipped** (`apex-app`, one commit — no Atlas, no second repo):

| | |
|---|---|
| Contract | `TierDeltaBaseline = 'arrived' \| 'lowest'` + `TIER_DELTA_BASELINES` + `isTierDeltaBaseline` in `rental-contract/tiers.ts`; `deltaBaseline` on `UnitLocationRules`, `DEFAULT_UNIT_LOCATION_RULES` (`'arrived'`) and `readUnitLocationRules` |
| Resolution | `resolveDeltaBaseline(baseline, entries, arrivedRank)` — reads **rates, not ranks**, because a provider-ranked feed plus a mid-month rate change can leave rank order non-monotonic, and "cheapest by rank" would then name a card that isn't the cheapest and mislabel every other card by the difference |
| Validation | `deltaBaseline` added to `validateVbpTierSettings`'s allowed keys and refused at save if it is not one of the two (`layouts.ts`) |
| Panel | `TierRules.tsx` — a select under Price labels, rendered **only** when `priceDisplay === 'delta'`, with a hint that states both readings and their consequence |
| Renderers | both lanes. `current` stays identity (confirm row, clear-back-to-arrived, preselect fallback); only the arithmetic moved to `baseline` |

**Two decisions worth carrying forward.** The default is `'arrived'`, so no existing checkout moves —
the setting is stored-as-nothing like its neighbours. And **Atlas gets no say**: it publishes
`price_labels` (which reading) and has never published a baseline, so this stays the contract's
alone. If Atlas ever adds one, that is a new decision, not a fallback.

**Left open.** The confirm row's price chip is still gated on
`active.option.rate !== current.option.rate` — "does this pick change what I arrived paying" — while
its *number* now comes from the baseline. Under the default they are the same card and the behaviour
is byte-identical to before. Under `'lowest'`, a tenant who keeps their arrived unit sees a `+$16/mo`
card and a confirm row with no chip. That is defensible (nothing changed) and deliberate, but it is
the one place the two readings sit side by side.

### S6 — Billing period and weekly rates. **PREMISE CORRECTED + CHUNK 1 SHIPPED 2026-09-04.** Two parts still open.

This slice said *"`CANONICAL_RATE_FIELDS` has no weekly column, so this starts in the units lane"*.
The units lane **already dealt with it, deliberately, and wrote down why** —
`syncs/fms/normalize/yardi.ts:697-726`:

- **Yardi is the weekly provider, not SiteLink.** Mini-Mall migrated (`mini-mall-storage-yardi`).
- **The ×4 already happens in the normalizer**, measured exact on every published row:
  `web_rate = web_weekly_rate × 4`, **3890 / 3890**. There is no arithmetic left to port.
- **The weekly originals ride in `raw`** under legacy's own spellings, and that was a decision with a
  stated reason: `CanonicalUnit.rates` is a closed set and no reader knows a weekly rate exists, so
  canonical fields would have been four new keys with no consumer. Adding them now would repeat the
  exact failure this package exists to remove.
- The normalizer names the consequence itself: **"Four weeks is not a month."** The number on a Yardi
  unit card is a four-week price sitting in a monthly field, reproduced on purpose because correcting
  it would move prices on **284 facilities** on the next sync with nothing to point at.

**So the whole of S6's chunk 1 is the suffix, and the suffix is a live defect.** `pricePeriod` is
read in three places — `base/checkout/sections/Vbp.tsx:62`, `edge-checkout-v2-1/sections/Vbp.tsx:178`,
`edge-checkout-v2-1/mobile/Hero.tsx:62` — and **declared in neither checkout component's `index.ts`**:
no default, no schema entry. So it is always `undefined`, always falls back to `"mo"`, and no operator
can set it. Every Yardi checkout card reads `$120/mo` for a price that is `$30 × 4 weeks`.

That is read-but-never-written — the same class of defect as `applyDiscount` (`layouts.ts`'s
`DROPPED_TIER_KEYS`) and Atlas's `display_rate_source`, and the third instance found in this work.

**The decision that gates the build.** Where does the period come from?

- **From the provider.** It is a fact of the feed, measured 3890/3890, and an operator cannot make a
  four-week price monthly by choosing a label. But it hardcodes a provider name into render code.
- **From the operator, per setting.** Follows the platform's own display-only-setting doctrine
  (`apex-app/CLAUDE.md` §"A redesign is presentation") and is the only shape that expresses legacy's
  **26-location monthly pilot** — those Mini-Mall facilities are billed monthly, so the period varies
  *within* Yardi and is not provider-derivable after all. But it lets an operator label a Yardi card
  `/mo`, which would be the same lie, now sanctioned.
- **Both.** Provider-derived default, operator override for the pilot. Most honest, most machinery.

`ICheckoutSetting` has the right shape for the second and third either way: a top-level key beside
`sections`, like `copy` / `errorMessages` / `thankYouPath`, because the period is read by the ladder
*and* the mobile hero and describes the rate rather than any section. **Not** `chrome` — its reader
is boolean-only and "only an explicit `true` counts" is load-bearing there.

**DECIDED 2026-09-04 (Chrys): both halves — provider default, operator override.** Shipped as
chunk 1:

| | |
|---|---|
| New module | `rental-contract/price-period.ts` — `CheckoutPricePeriod = 'month' \| 'fourWeeks'`, labels (`mo` / `4 wks`, no leading slash — the render sites own it), `providerPricePeriod` (Yardi ⇒ `fourWeeks`, measured, case-insensitive), `readPricePeriod` (unset ⇒ `null`, never `'month'`), `resolvePricePeriod` = the one place both halves meet |
| Setting key | `ICheckoutSetting.pricePeriod`, beside `sections` like `copy` / `chrome`. **Not inside `chrome`** — that reader counts only an explicit `true`, which a string would break |
| Resolver | seventh arm, and the only one returning the operator's half rather than a resolved value: resolution needs the provider, `fmsType` is on `setting` (null for defaults *and* every preset), and adding an argument would change the signature whose whole guarantee is browser/server identity |
| Context | `CheckoutContext.pricePeriod`, resolved once with the provider applied, because three sites print it and three copies of the rule is how a card and its summary come to disagree |
| Wire + storage | Joi `.valid('month','fourWeeks')` and `authoredFields` — the function whose own docblock records `copy`, `thankYouPath`, `chrome` and `requireCaptcha` each being accepted, validated and then dropped. Tested end to end for that reason |
| Control | `PricePeriodRules.tsx` in the checkout-wide pane. First option is "Use the provider's (4 wks)", stored as nothing; the hint names the provider's own answer and warns that overriding a four-week price to a month states a period the tenant is not on |
| Presets | deliberately **null**. A preset is shipped code shared by every operator, and the period is a fact of one provider's feed — a preset naming one would assert it for all five |

Two decisions worth carrying: absent means "the provider's" at every layer (draft → wire → storage →
resolution), so the key can never be the fifth casualty of `authoredFields`; and `FOUR_WEEK_PROVIDERS`
holds Yardi alone, with the docblock stating that adding a provider is a claim about its feed wanting
the same 3890/3890 evidence.

Still open in S6: the 26-location pilot itself. The mechanism now exists — `atlas_checkout_settings`
is irrelevant here, but `RentalScope` is per-facility, so a 26-facility subset is ordinary — and
nobody has enumerated which 26.

Also still open, and explicitly deferred rather than settled: Mini-Mall's `bUsePushRate`. v4
hardcodes `usePushRate: false`
(`packages/api/app/services/checkout-submit/sitelink/submit.ts:146`) — and note this is the SiteLink
submit path while Mini-Mall is now Yardi, so the legacy behaviour may be unreplicated because it no
longer has a provider to apply to. Confirm which before treating it as a gap.

### S7 — Tier-conditioned add-ons. **SHIPPED 2026-09-04.** Design A of three.

**The plan's summary of the two handlers was incomplete, and the missing clause decides the shape.**
Read in full:

| Item | Condition | When it fires | Otherwise |
|---|---|---|---|
| Smart Unit (storEDGE) | `isBestTier() \|\| !hasVbpTier()` | `required_at_move_in` + `strike_through` + "First full month free" | `pre_selected` only |
| 24 Hour Access (SiteLink) | `vbp->order === 3` | `included_in_price` + `included_with_unit` + "Included" | ordinary paid row |

Two consequences. **Neither item is ever hidden** — both are offered at every tier and change
*state*, so a field deciding which ranks an item appears at would have covered neither. And
**`!hasVbpTier()` is a real branch**, not an edge case: a ladder collapses to one card whenever the
siblings rent, so "no tier" happens on tiered facilities constantly.

**Shipped: per-rank state overrides** (`apex-app`, one commit).

| | |
|---|---|
| Contract | `AddOnTierRank = 0 \| 1 \| 2 \| null`, `AddOnTierState` (the three flags a tier may change), `AddOnTierStates` (string keys `'0' '1' '2'` + `untiered`, because jsonb has no numeric keys), `CatalogItemSpec.tierStates` |
| Merge | `specForTier` + `effectiveSpecFor` — one place, spread over the base so an absent flag inherits and an **explicit `false` turns one off**. `specFor` unchanged for the editors, which show what was typed rather than what a tenant on some tier would see |
| Accessors | `itemStartsSelected` / `itemIsLocked` / `itemIsChargeable` take an optional tier. All three go through `effectiveSpecFor`, so the section, the summary, the Edge surface and the server cannot disagree |
| Server | `priceAddOns` takes the tier; both callers pass `input.tierRank ?? null` — already validated against the offered ranks by `prepareSubmission`, which refuses `tier_not_offered` first |
| Browser | one hook, `sdk/addon-tier.ts`, read by all four surfaces |
| Validation | unknown tier key, unknown flag, non-boolean, and `required`+`included` together all refused — plus `tierStates` added to the item's recognised-keys list |
| Control | a 4×3 matrix at the foot of the item's expanded panel in `CatalogPickerRow`, last because it is the only control there that changes what the tenant is charged |

**Three things this slice got wrong first, all caught by a gate rather than by review:**

1. **`setItemFlag` would have silently dropped `tierStates`.** It rebuilds the spec key by key, and its
   own comment already warns about this ("the bug the earlier `{ id, ...oneFlag }` rebuild had"). A
   lost tier rule unlocks a charge. Now carried through, with a comment naming the trap.
2. **`tierStates` was missing from the item's recognised-keys list**, so a valid setting was refused as
   an unknown key. Caught by the new test, not by the typechecker.
3. **`useAddOnTier` was placed after an early return in all five call sites.** `lint:hooks` refused it.
   That is the gate earning its keep: a conditional hook survives typecheck and every unit test, and
   fails when a render order changes.

**Two deliberate exclusions.** The **free-first-month credit** is a concession — the server re-prices
every add-on from the catalog artifact and no provider payload carries a per-item one, so it belongs
in a real FMS discount plan. The **one-location branch** is `RentalScope`'s job; a facility-scoped
setting already expresses it and needs no contract field.

**Two open items this inherits.**

- **`untiered` fires on "has not clicked yet", not just "no ladder".** The browser posts a rank only
  once the tenant clicks, and the server reads that field — so the two agree, which is the property
  that matters, but the semantics differ from legacy's `$unit->tier` (a row that exists regardless of
  clicking). Closing it means making an unclicked preselect contribute a selection, and `tiers.ts`
  refuses that as "a price change wearing a presentation setting's clothes". The key is therefore
  **named** for the tenant's state — "No tier chosen" — rather than the facility's.
- ~~`order === 3` → rank 2 is unverified.~~ **CONFIRMED 2026-09-04, and it is rank 2 (best).**
  Traced through the handler rather than guessed: `buildVbpList` ends with **`krsort`**, so the list
  is **descending by rate** and its first entry is the most expensive. `get()` sets
  `$attribute_index = 2 - $base_price_index` (0 for a three-card ladder) and
  `$tier_number = 3 - $attribute_index`, so the first — priciest — entry gets `tier_number` 3. And
  `buildVbpPriceWithFallback` passes `order: $tier_number` (`SitelinkVbpHandler:292`). So
  **`order === 3` is the most expensive card**, which is canonical rank 2. The S7 assumption was
  right.

  One legacy defect found on the way and deliberately **not** ported: `krsort` sorts the *string*
  keys `number_format($rate, 2)` produces, so a ladder whose rates straddle a power of ten orders
  wrongly — `"99.00"` sorts above `"129.00"`. v4's `buildVbpTiers` sorts numerically and does not
  inherit it.

### S8 — Safeguard's dual price. **SHIPPED 2026-09-04.**

**What legacy does** (`SafeguardSelfStorageVbpHandler::get`): the card's price is
`getDiscountedRate($unit, $push_rate)` — the concession's own `discounted_rate` from the unit's
first discount period, or the one matching `$this->discount` by `concession_id` — with `push_rate`
carried as the original, under `price_label = 'Discounted Rate'` and
`original_price_label = 'Standard Rate'`. It is the only handler that reads `$this->discount`.

**Shipped** (`apex-app`, one commit):

| | |
|---|---|
| Contract | `unitLocation.dualPrice` (boolean, default **false**) + `dualPriceLabels: { discounted, standard }`, with `TierDualPriceLabels`, `DEFAULT_DUAL_PRICE_LABELS` (legacy's own words) and `readDualPriceLabels` — which falls back **per label**, so overriding one keeps the other, and treats a blank or non-string as unset rather than printing it |
| Discount lookup | `CheckoutProvider.discountedRateFor(unitId, basePrice)`, threaded from each lane's `render.tsx` — the only place that owns both the per-unit discount rows (`buildDiscountMap`, keyed by `location_units_id`) and the promo arithmetic (`resolveUnitPromo`). Absent resolver ⇒ every unit answers `null` ⇒ single figure |
| Render | a `DualPrice` node in both `Vbp.tsx` lanes. `CheckoutCardFooter.right` already accepts a `ReactNode`, so the primitive was untouched |
| Validation | non-boolean switch refused rather than coerced; unknown label key and non-string label refused |
| Control | `TierRules.tsx` — a checkbox that reveals the two label fields, indexed on the words an operator would search ("crossed out", "was", "sale") |

**Three rules the card follows, each with a reason:**

1. **Per card, not per checkout.** Legacy called `getDiscountedRate` per sibling unit, so the ladder
   can show a concession on one card and not another. The resolver is therefore keyed by unit id.
2. **`null`, not the base price, when there is no concession** — and also when the discounted figure
   is not strictly *below* the base. A struck-through price equal to the one beside it is noise; one
   *lower* than it reads as an error, and a feed producing that is not something to render.
3. **Dual price wins over `priceDisplay` on any card it applies to**, because it is the only one of
   the three readings that states a concession — a delta or a bare rate beside a struck-through
   figure would be two claims about one number. `price_labels: none` still wins over dual price: an
   operator who hid prices did not ask for two of them.

**Left open.** The label shift legacy pairs with this (`2 - $base_price_index`, so a two-card ladder
reads Best/Better rather than Best/Good) is **not** ported. It is a tier-copy concern rather than a
price one, and v4's `clampRank` already re-indexes a short ladder to a contiguous 0…n-1 — so the two
mechanisms would fight. Whether a two-card ladder should relabel is a copy decision nobody has taken.

## 4. Constraints that bite

- **Lovable owns Atlas deploys and the hosted schema.** A git push does not deploy; never apply a
  migration to the hosted project. Check `.lovable/` state before large edits — Lovable regenerates
  whole files and concurrent edits erase work with no merge conflict.
- **Owned paths.** `src/components/atlas/**` and `src/routes/**` are Tareq's; the `*.server.ts` /
  `*.functions.ts` write layer is owned. Ask before restructuring; patching is fine.
- `rm` does not work on that mount — dead code moves to `_to_delete/`. Atlas uses **bun**.
- Don't hand-write Atlas rows to test: the lists filter on `fields.helix_tags`, which only the sync
  writes, so a hand-made row is invisible without being missing. Use `make sync-atlas`.
- Legacy is a third repo (`/var/www/Storagely/app-storagely-io`) and is **not** in this workspace's
  history. Read it, cite it, don't commit into it as part of this work.

## 5. What to leave behind

`docs/handoff-vbp-atlas-integration.md`, in the house style of the sync-lane handoffs: what shipped,
each decision with its evidence, the verification numbers, and the open items the next slice
inherits. Add one row for it to `docs/README.md`, and record any premise of *this* prompt that turned
out to be wrong — that section has earned its keep on every previous handoff.
