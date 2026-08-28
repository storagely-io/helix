# HANDOFF — per-location and per-unit sync rules

Session of 2026-08-27. Successor to
[docs/handoff-storedge-lanes-and-conditions.md](handoff-storedge-lanes-and-conditions.md), which
shipped the 15-rule catalog. This session made those rules **scopeable**.

Approved plan: `~/.claude-orgs/storage/plans/swift-launching-perlis.md`.

**Everything is uncommitted, in `apex-app`** — 43 changed/new files now. Nothing pushed. Pushing
`apex-app` main deploys prod via CircleCI with no approval gate.

**Two sessions are recorded here.** Part 1 made the rules scopeable. Part 2 (below) made the
CONDITIONS arbitrary, which is what was actually asked for.

---

## The question this answered

*"How do we filter what each sync does per location, or even per unit?"* — and the legacy census
that framed it. Legacy's answer was **1,369 hardcoded unit ids in three operator-named classes**:

| Legacy | Grain | Size |
|---|---|---|
| `Storedge/…/Clients/TheNestStorageLocationUnitHandler.php` | 4 facilities → id lists | 963 lines, **796** UUIDs |
| `Sitelink/…/Clients/EasyStopStorageLocationUnitHandler.php` | 2 facilities → id lists | **495** ids |
| `Ssm/…/Clients/MyGarageSelfStorageLocationUnitHandler.php` | 4 facility pairs → type substring | see open-items §5 |
| `YardiFacilitiesUnitSyncJob.php:32` `EXCLUDED_UNITS` | global per unit | **78** ids |

Only **3 of 15** conditions were ever operator-editable in legacy, all account-scoped
(`storedge_facilities`, `is_tier_enabled`, `is_disable_rounding_unit_size`).

Two legacy findings shaped the design:

- **Legacy's per-unit operator control never reaches the JSON.** `LocationUnit.is_show`
  (`LocationController::unit_status($id)`) and `exclude_website` are applied at **read** time in
  six duplicated predicates, never at sync — and the SiteLink sync overwrites `exclude_website`
  from `bExcludeFromWebsite` on every run, silently reverting the operator.
- **Legacy's one two-rung ladder blends at the SET level and is buggy.** `AdvancedConfigure` is
  keyed on `users_id` *and* `site_locations_id`, but `lugbFormatCheckbox`
  (`LocationPageController:906`, duplicated at `ShowHideElementController:505`) says *"if local
  data exists, always prioritize it"* — one location key discards every global key.

⇒ scoping is **per rule, never per rule-set**.

---

## What shipped

| | |
|---|---|
| **Scoped rules** | `fmsConfig.syncRuleOverrides` — a sibling array beside `syncRules`, so every stored record round-trips byte-identically. Each row: one rule, one `RentalScope`, one value. |
| **Resolution** | `resolveSyncRulesAt()` wraps `resolveSyncRules()` and re-decides **only** rules with an exception, through the shipped `resolveScopedSetting` ladder. |
| **`named-units`** | New unit rule: `all` / `only-listed` / `exclude-listed`, with a bulk id list (cap 2000). The port of legacy's 1,369 ids. |
| **`inventory-source`** | New location rule: `own` / `borrow`. A facility publishes another facility's feed under its own path. Reproduces TheNest and EasyStop. |
| **Honest rollup** | `conditionEffect` gains `byLocation` **only when an exception decided something** — a sum is a lie once two facilities legitimately disagree. |
| **UI** | Exceptions live *inside* each rule's card, reusing the shipped `ScopePicker` wholesale. |

`SYNC_RULE_SUPPORT` still lists `storedge` only. Sitelink/SSM/Yardi stay **absent, not `[]`** —
the file's own documented convention (absent = no normalizer; `[]` would read as a coverage
decision). The plan said `[]`; the codebase's rule is better and was followed instead.

---

## The three things that would have shipped broken

1. **`viaOverrides` counted only per-ROW exceptions.** A *facility*-scoped exception — the common
   case and every legacy port — left it at zero, so `byLocation` never appeared and the rollup
   reported one aggregate for two facilities that had stopped agreeing. Caught by the **live
   run**, not by 8,563 tests. Now seeded from the facility-grain answer.
2. **Exceptions rendered between cards.** With a top border and sibling positioning they read as
   belonging to the card *below* — an operator would attach an exception to the wrong rule. Caught
   by **looking at the screenshot**. Now inside the card's border.
3. **A placeholder leaked a real legacy facility name.** Caught on re-read; `apex-app/CLAUDE.md`
   forbids operator names in shipped strings.

---

## Verified live, against the two sandbox facilities

`storagelyselfstorage` · `25e2ece8-…` and `c93036ab-…`. Sandbox was **restored to baseline
afterwards** (config carries no overrides; 51 + 61 published).

| Check | Result |
|---|---|
| Baseline, no exceptions | 140 read → **112** published, 28 by `unit-status`, no `byLocation` — identical to before |
| `unit-status` excepted at facility one | facility one **51 → 70**, facility two **unchanged at 61**, in ONE run |
| Rollup honesty | `byLocation: [{c93036ab, 61/70, via 0}, {25e2ece8, 70/70, via 1}]`, most-withheld first |
| `named-units` `only-listed` × 3 real ids | facility two published **exactly those 3**, 67 dropped by "Named units" |
| `inventory-source: borrow` | facility two published **facility one's units** under its own `locationCode` |
| `raw` allow-list | `grep -cE "current_tenant_id\|combination_lock_number\|overlock_lock_number\|max_rate\|managed_rate"` = **0** on both lanes, both facilities |

**The stacking that will surprise someone:** naming a unit says which candidates a facility
considers; it does **not** exempt them from the other rules. A named unit that is `reserved` still
meets the connection-wide status rule and goes. Observed live (5 named ids → 3 published) and
pinned in a test.

---

## How to verify

```bash
cd apex-app
pnpm typecheck                                    # 7 packages
npx vitest run                                    # 8612 pass
cd packages/api && NODE_OPTIONS='--experimental-vm-modules' \
  npx jest --config jest.config.main.js           # 2842 pass — the env var is required
```

`packages/api/.env` has **CRLF endings**; `set -a; . .env` leaves a `\r` on the OAuth key and
every storEDGE request 401s. Source it as:

```bash
export STORAGE_API_KEY="$(grep '^STORAGE_API_KEY=' packages/api/.env | cut -d= -f2- | tr -d '\r' | sed 's/^"//; s/"$//')"
```

**Driving the platform UI locally** (this cost 30 minutes to work out):

- The seeded local operator carries `forcePasswordReset: true`, so the SPA bounces to
  `/login/change-password`. The token from `POST /api/v1/auth/login` is fully valid — only the
  client-side guard blocks. Patch `storagely.auth.user` in localStorage to `forcePasswordReset:
  false` for a drive-through rather than changing the password.
- The session key is **`storagely.auth.token`**.
- The route is `/users/:userId/**admin**/accounts/:accountId/api-sources/:sourceId` — note
  `admin/`.
- A `[data-stg-popup]` overlay swallows clicks; remove it before driving.
- Playwright: use the system chromium (`executablePath: '/usr/bin/chromium-browser'`,
  `args: ['--no-sandbox']`) — the cached ms-playwright builds do not match the npm versions here.

---

## What is NOT done

1. **Nothing committed.** Two commits owed — workspace `docs/` and `apex-app`, separately.
2. **`SECURITY.md` entry for the `raw` allow-list** — owed since the previous session, still not
   written.
3. **The three missing units lanes.** SiteLink, SSM and Yardi write `detail: {}` / `units: []`
   (`sitelink.ts:112`, `ssm.ts:125`, `yardi.ts:53`) and Yardi's `listLocations` is a stub
   returning `[]` (`yardi.ts:30`). The contract and resolver are provider-neutral and ready;
   nothing applies them there because there is nothing to filter. **This is the named next phase**
   — and the honest reason "all four providers" was not delivered this session.
4. **MyGarage's substring match** — [open-items.md §5](open-items.md).
5. **The per-facility inventory matrix** (Option E). Only the narrow `byLocation` breakdown
   needed to keep the rollup honest was built.
6. **`CanonicalLocation` / `LOCATION_SOURCES`** — phases 0–2 of
   [v4-location-cutover.md](v4-location-cutover.md), untouched.

## Where things live

**New**
```
packages/platform/.../syncRuleOverrides.tsx              the exception editor
packages/api/__tests__/.../fmsStoredgeScopedRules.test.ts
tests/fms-sync-rule-overrides.test.ts
```

**Changed, notably**
```
rental-contract/sync-rules.ts          named-units, inventory-source, 2 new param kinds
rental-contract/sync-rules-resolve.ts  SyncRuleOverride, resolveSyncRulesAt, validate, authored
syncs/fms/storedge.ts                  rulesAt(code) memo, unitRulesFor, the borrow redirect;
                                       the constructor docblock arguing AGAINST per-location
                                       resolution is rewritten
syncs/fms/normalize/storedge.ts        unitRuleView + deriveUnitFields (probe hoisted before the
                                       gates), named-units gate, per-facility census
apiSourcesController.ts                byLocation + CONDITION_LOCATIONS_CAP
apiSources.ts                          SyncRuleOverridesInvalidError + the facilityIds check the
                                       contract package cannot make
```

## The lesson worth carrying

The previous handoff's lesson was *"compilation is not verification for UI work — drive a browser
or say plainly that it has not been looked at."* Followed this time, and it paid twice: the
`viaOverrides` bug survived 8,563 green tests and died on the first real sync, and the
exception-attachment defect survived a clean typecheck and died on the first screenshot.


---

# PART 2 — sync conditions

## The ask, in Chrys's words

> *"on sync php files we can easily do `if ($location_code == 'xxx') do xxx` — we need this same
> filter capability"*

Part 1 gave 18 named rules, each scopeable to a facility. The **conditions** were still limited to
eight closed unit fields inherited from the CHECKOUT scope grammar — and every reason those eight
are narrow is checkout-specific. `scope-types.ts` excludes availability (*"changes hourly, so terms
would shift as units rented out"*), price (*"circular — the checkout is partly what presents the
price"*) and tier rank (*"a tenant clicking a higher tier mid-checkout"*), plus the header's real
invariant: *"the same risk of the page and the server disagreeing"*. **A sync condition runs once,
server-side, with no page.** None of the four risks exist, and reusing `RentalScope` wholesale had
imported constraints belonging to a different problem.

## The instance that exposed it

*"At location X, disable tiered pricing."* Run live: the exception **was** in force
(`viaOverrides: 1` at that facility, `0` at its sibling) and **nothing changed** — unit 506 still
published `web_rate: 140` against `standard 125 / tiered 145`. Three reasons:

1. `rates.tiered_rate` was published verbatim; `rate-source` only picked the *ladder*.
2. `web_rate` comes from `channel_rate`, which storEDGE derives from the tier upstream, so the
   ladder was never consulted.
3. `rank` was still published, so the VBP tier ladder still had its rungs.

And two more rules — **`unit-sort` and `dimension-rounding`** — had **no implementation at all**.
Three of eighteen dials read as decisions and did nothing.

## Legacy census, corrected upward

Part 1 reported 1,369 hardcoded unit ids. There are three more sets in `app/Custom/helpers.php`
(`storage_depot_unit_id_set` **1,261**, `all_purpose_unit_id_set` **785**, `hearthfire_unit_id_set`
**174**), called from `LocationPageController:440,452,569,580` behind
`if ($user_id == 213 && in_array($loc, $…_location_codes))`. **3,589 hardcoded unit ids total.**

## What shipped

| | |
|---|---|
| `rental-contract/sync-fields.ts` | The field catalog — ~47 storEDGE fields, typed and grouped, with **measured** enum option lists. `SYNC_FIELDS_FORBIDDEN` keeps tenant/lock fields unmatchable. |
| `rental-contract/sync-conditions.ts` | The grammar: `when <field> <comparison> <value>`, ANDed, closed, one row per field, fails closed on a missing value. |
| `SyncRuleOverride.when` | Replaces `scope.unit`, which is now **refused** — one way to say which records. |
| `facility-filter` rule | `sync-all` / `only-matching` / `skip-matching` over facility conditions. The general form of `if ($location_code == 'xxx')`. |
| `rate-source: no-tiering` | Nulls `tiered_rate` and `rank` and ignores the tier-derived channel price. |
| `unit-sort`, `dimension-rounding` | Implemented. |

**Keys are namespaced** — `unit.name` vs `facility.name`. A bare path is not unique across records,
and looking up by path resolved a facility condition as a unit one. A test caught it.

## Verified live

Sandbox restored to baseline afterwards (140 → 112; 51 + 61; feed order).

| Check | Result |
|---|---|
| Baseline, no exceptions | 140 → **112**, no `byLocation` — unchanged |
| **The ask** — `no-tiering` at one facility | unit 506 **140 → 125**, `tiered_rate` null, `rank` null; sibling untouched |
| Unit condition `unit.tier.rank equals 2` + a $200 floor | all **19** rank-2 units dropped; ranks 0 and 1 kept; sibling untouched |
| Facility condition `facility.store_number is-set` + `only-matching` | manifest **1 location**, not 2 — the unnumbered facility skipped entirely |
| Withheld-field condition (`unit.max_rate`) | accepted, and `grep -c max_rate` on the artifact = **0** |
| Forbidden field (`unit.current_tenant_id`) | refused at save, 400 |
| `facility-filter` set to narrow with no condition | refused at save — a dial that would do nothing |

## Two things a live run caught that tests did not

1. **`unit-sort`'s default reordered every facility.** Implementing it with `web-rate` as the
   default (what the catalog said, and what legacy did *at render*) reordered a sandbox facility
   **whose rules had not changed**. This lane has never sorted, so the honest default is a new
   `feed-order` mode. Shipping the other way would have reordered every storEDGE unit grid on the
   next sync with no deploy and nothing to point at.
2. **`rental-contract` is consumed as a BUILT DIST, not source.** `package.json` resolves
   `node → ./dist/index.js`. A contract change is invisible to the running API until
   `npm run build` in `packages/rental-contract`, and there is **no error** — the sync just applies
   the old catalog. This silently invalidated one measurement mid-session (a stale dist still had
   `unit-sort` defaulting to `web-rate`). **Rebuild the contract before trusting any live sync
   measurement.**

## What is NOT done

- **Nothing committed.** Still two commits owed, still separate repos.
- **`SECURITY.md`** — now owes two entries: the `raw` allow-list, and that a condition on a
  withheld field (`max_rate`) renders that value in the platform UI and the run log.
- **`PromoCondition` is not consolidated.** `components/sdk/promo-pricing.ts:103` is the same shape
  shipped — a dot-path predicate over a raw FMS unit row — with a free-text field, one condition
  per slot, and no validation or readback. This is now the **fifth** copy of an operator-comparison
  list (`promo-pricing.ts:93`, `IWebsite.ts:65`, `editor/store.ts:323`, `PromoPricingTab.tsx:48`).
  Deliberate and recorded in `sync-conditions.ts`'s docblock, not an oversight.
- **The three missing units lanes** (SiteLink, SSM) and the **Yardi client** — unchanged from
  Part 1, and still the reason the catalog has one provider.
- **A field-coverage probe.** `sdk/unit-data-mapping.ts:419`'s `validateFieldMappings` returns
  `{ missing, total }` per path over real rows; pointed at the last sync it would let the builder
  say *"this field is empty on all 70 units here"* — the difference between a filter that is wrong
  and one that is merely inert.
