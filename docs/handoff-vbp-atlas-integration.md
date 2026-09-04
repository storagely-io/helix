# HANDOFF — value-based pricing, moved into Helix checkout settings

Session of 2026-09-04. Answers [prompt-vbp-atlas-integration.md](prompt-vbp-atlas-integration.md),
whose nine slices are annotated in place with what actually happened.

**Uncommitted, in `apex-app`.** Nothing pushed. Pushing `apex-app` main deploys prod via CircleCI
with no approval gate. `atlas/` was fast-forwarded to `5ffecee03` and otherwise untouched.

**Three files in `apex-app` were already modified before this session and are not part of this
work** — `packages/api/app/services/imports/atlasMirror.ts`, `packages/webpage/globals.d.ts`,
`packages/webpage/src/data-loader.ts` (mtimes ~10:47, ahead of the first edit here). A bare
`git add -A` sweeps them into this commit.

---

## The one thing that changed the shape of everything

**Mid-session the target moved from Atlas to Helix checkout settings, and that is the only reason
this work reaches the operators it is for.**

The brief's plan was Atlas-first: persist the tier copy in `atlas_checkout_settings`, emit it on the
public location payload, let `edge-checkout-v2-1`'s existing `vbp-block.ts` + `vbp-overlay.ts` read
it. Every part of that is technically sound, and the conclusion still fails — because those readers
live in a component almost nobody runs.

Counted over the local mirror's live page artifacts (`packages/api/.local-storage`, `pages/` only —
version history inflates every count several-fold):

| Website | Account | `checkout` | `edge-checkout-v2-1` |
|---|---|---|---|
| Mini Mall Storage | `account_VpRr3kk08TJWZ9x` | **3** | 0 |
| Safeguard Self Storage | `account_ss3hh77hR_CbHCD` | **1** | 0 |
| storagelyselfstorage.com — Storagely's own | `account_FDL4h_6DC5C8Ftp` | 2 | **2** |
| sandbox-testing | `account_ZlfyJ_5YxLPyJzd` | 1 | 0 |
| Local Dev Site | `account_WmMmV9SBCGMH7Yy` | 1 | 0 |

`edge-checkout-columbia-v1` and `cubby-checkout`: **zero** live pages anywhere.

**`edge-checkout-v2-1` ships on exactly one website, and it is Storagely's own sandbox.** Every
legacy operator present ships `base/checkout`, which contains no `readVbpBlock` and no
`overlayAtlasTiers` — grepped, empty. Built as briefed, the operator copy would have resolved,
emitted, synced and rendered nowhere.

**Caveat, and it matters.** This is the local mirror, populated by import from prod, **not a prod
census**. Columbia Self Storage is absent from it entirely — the `columbia` hits in the tree are a
city in two operators' location lists, not the operator — so **Columbia's component is unverified**.
Mini-Mall and Safeguard are verified.

---

## What shipped

Five slices, `apex-app` only, one repo. Every one display-only except S7.

| Slice | What | Tests |
|---|---|---|
| **S5** | `deltaBaseline: 'arrived' \| 'lowest'` — which card the signed price differences are measured FROM | 13 |
| **S6 ¹⁄₃** | `pricePeriod: 'month' \| 'fourWeeks'` — provider default, operator override. Fixes a live defect | 18 + 1 api |
| **S7** | `CatalogItemSpec.tierStates` — an add-on whose state changes with the chosen tier | 20 |
| **S8** | `unitLocation.dualPrice` + labels — discounted price over a struck-through standard rate | 13 |
| **S2/S3** | Answered and closed on evidence; no code | — |

Full suite green at each step. Final: root vitest **554 files / 10,571 tests**, `packages/api`
**244 suites / 3,312** main + **46 / 753** wasm, plus all five lint gates and both typechecks.

### The decisions worth inheriting

**S5 — the baseline, not a third token.** `priceDisplay: 'delta'` *already* rendered the mixed shape
(`showRate || option.isSelected ? money(rate) : deltaLabel(delta)`), which is base-absolute /
upgrades-signed. What differed was the reference point: legacy measured from the cheapest sibling,
v4 from the arrived unit. Same rates, opposite offers — a cheaper tier reads `−$16/mo` (a saving)
from one and every card reads `+$16/mo` (an upgrade) from the other. `resolveDeltaBaseline` reads
**rates, not ranks**, because a provider-ranked feed plus a mid-month rate change can leave rank
order non-monotonic, and "cheapest by rank" would then mislabel every other card by the difference.

**S6 — the ×4 was already done, and the suffix was the bug.** `normalizeYardiUnits` publishes
`web_rate = web_weekly_rate × 4`, exact on **3890 / 3890** rows, and says so itself: *"four weeks is
not a month"*. Nothing to port. But `pricePeriod` was read in three render sites and **declared in
neither checkout component** — no default, no schema entry — so it was always `"mo"`. Every
four-week card read `$120/mo` for a price that is `$30 × 4 weeks`. Provider supplies the default
because weekly pricing is a fact of the feed; the operator can override because the period varies
*within* that provider (legacy's 26-location monthly pilot).

**S7 — state, not visibility, and the untiered clause.** Neither legacy add-on is ever hidden; both
are offered at every tier and change state. The storEDGE rule is
`isBestTier() || !hasVbpTier()` — and that second clause is not an edge case, because a ladder
collapses to one card whenever the siblings rent. So `tierStates` keys are `'0' '1' '2'` **plus
`untiered`**. All three accessors (`itemStartsSelected` / `itemIsLocked` / `itemIsChargeable`) go
through one merge, which is what lets the server read the same answer off the same validated
`tierRank`.

**S8 — per card, and `null` when there is no concession.** Legacy called `getDiscountedRate` per
sibling unit, so the resolver is keyed by unit id. It returns `null` rather than the base price when
there is no discount **and** when the discounted figure is not strictly below the base: a
struck-through price equal to its neighbour is noise, one lower than it reads as an error.

**S4 — decided, not applied.** `web_rate` on the Edge lane, SSM left alone. The blast radius differs:
on Edge the provider prices its own rental so `rateSource` moves the card and `prepared.total` but
not the charge; on SSM it is sent as `Rent:` and does move what the tenant pays. Nothing to build —
the per-tier `rateSource` select exists and `ICheckoutSetting` is already `fmsType`-scoped. **Do not
reorder `resolveRate`'s fallback** (`tiered_rate → web_rate → …`): that would move prices on every
account that never named a source, SSM included.

---

## Three premises of the brief were wrong

That section has earned its keep on every previous handoff and did again.

1. **S1's "pays for itself" argument.** True in every particular, wrong in conclusion — see the table
   above. The readers exist; the component does not ship.
2. **S5 "needs a third token in both the contract and Atlas's `price_labels`."** It needed neither.
   `delta` was already the mixed shape; the gap was the baseline, which the brief mentioned in its
   own last line and did not act on.
3. **S6 "starts in the units lane" because "`CANONICAL_RATE_FIELDS` has no weekly column."** The
   units lane had already settled it, deliberately, with the reason written down: canonical weekly
   fields would have been four new keys with no consumer. The weekly originals ride in `raw`.

S7's summary of the two handlers was also incomplete — it omitted `!hasVbpTier()`, which decides the
key set.

## Four things a gate caught that review did not

Worth reading as a list of what this codebase's guards are actually for.

1. **`setItemFlag` would have silently dropped `tierStates`.** It rebuilds the spec key by key and
   its own comment already warns about exactly this. A lost tier rule unlocks a charge.
2. **`tierStates` was missing from the item's recognised-keys list**, so a valid setting was refused
   as unknown. The new test caught it; the typechecker could not.
3. **`useAddOnTier` was placed after an early return in all five call sites.** `lint:hooks` refused
   it. A conditional hook passes typecheck and every unit test and fails when render order changes.
4. **A blanket string replace hit a standalone helper** that had no tier in scope. Typecheck caught
   that one — but only because the name was undefined; a same-named variable would have compiled.

Also of note: `authoredFields` in `checkoutSettings.ts` is where `copy`, `thankYouPath`, `chrome` and
`requireCaptcha` were each accepted, validated and then dropped on the way to storage. `pricePeriod`
is wired through it **and tested end to end** for that reason.

## The read-but-never-written pattern, three instances

This work turned up three keys that something wrote or offered and nothing read:

| Key | Where | Status |
|---|---|---|
| `applyDiscount` | `layouts.ts` `DROPPED_TIER_KEYS` | already known |
| `display_rate_source` | Atlas's VBP block, parsed and never applied | S0 also established it would have been dereferencing the **emitter's own default** (`validRateSource` coerces to `tiered_rate`), not an operator choice |
| `pricePeriod` | read in three render sites, declared in neither component | **fixed by S6** |

Worth a standing check: a contract key with no reader, and a reader with no writer, are the same
defect from opposite ends.

---

## Open items the next session inherits

**Could make shipped code behave wrongly:**

- **`untiered` fires on "has not clicked yet", not only "no ladder".** The browser posts a rank only
  once the tenant clicks and the server reads that field — so the two **agree**, which is the
  property that matters, but it diverges from legacy's `$unit->tier` (a row that exists regardless
  of clicking). Closing it means making an unclicked preselect contribute a selection, which
  `rental-contract/tiers.ts` refuses as *"a price change wearing a presentation setting's clothes"*.
  The key is therefore **named** for the tenant's state — "No tier chosen".

**Work not started:**

- **S4's application.** Which settings instances, by whom, with a before/after on one facility.
- **S6's pilot.** `RentalScope` is per-facility so a 26-facility subset is ordinary — but nobody has
  enumerated *which* 26 bill monthly.
- **S6's `bUsePushRate`.** v4 hardcodes `usePushRate: false` in
  `checkout-submit/sitelink/submit.ts:146` — and that is the **SiteLink** path while the operator in
  question is now on **Yardi**, so establish whether the behaviour has a provider left to apply to
  before treating it as a gap.
- **Columbia's checkout component**, per the caveat above.
- **S8's label shift.** Legacy's `2 - $base_price_index` makes a two-card ladder read Best/Better.
  Not ported: v4's `clampRank` already re-indexes a short ladder, so the two would fight, and
  whether a two-card ladder should relabel is a copy decision nobody has taken.

**Answered this session, recorded so nobody re-derives it:**

- **`order === 3` is canonical rank 2 (best).** `buildVbpList` ends with `krsort` ⇒ descending by
  rate ⇒ first entry is priciest; `tier_number = 3 - attribute_index` gives it 3; and
  `buildVbpPriceWithFallback` passes `order: $tier_number`. A legacy defect found on the way and
  **not** ported: `krsort` sorts the *string* keys `number_format` produces, so `"99.00"` sorts above
  `"129.00"` — a ladder straddling a power of ten orders wrongly. v4 sorts numerically.
- **Mini-Mall and Safeguard's account ids**, from the mirror's own website records:
  `account_VpRr3kk08TJWZ9x` and `account_ss3hh77hR_CbHCD`.
- **Atlas is not behind on VBP.** `atlas_checkout_settings.value_based_pricing` +
  `atlas_company_checkout_settings.value_based_pricing`, written by `saveCheckoutSettings` /
  `saveCompanyCheckoutSettings`, emitted by `helix-value-based-pricing-payload.server.ts`. The clone
  was 659 commits behind; the panel **is** the writer, not a scaffold. All live and unused by the
  operators this work is for.
