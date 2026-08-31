# Prompt — implement the v4 SSM location + unit sync

Paste the block below into a fresh session started in `/var/www/Storagely/helix`.

---

Read these first, in order. None of them auto-load except the first.

1. `CLAUDE.md` here (workspace root) — three repos, which one owns what, the process-safety rules.
2. `docs/troubleshooting.md` — before diagnosing ANY symptom. Nearly every failure in this stack
   is silent. Two entries earn their place before you start: the `.env` one (`apex-app/**/.env` is
   CRLF **and** quoted, so `set -a; . packages/api/.env` corrupts every value it exports and the
   result looks exactly like a dead credential — use the `val()` helper), and **"Every SiteLink
   call fails, and the error names an HTTP header"**, which is the shape of mistake this job is
   most likely to repeat.
3. `apex-app/CLAUDE.md` — architecture, storage philosophy, and the **credentials doctrine**.
4. **`docs/handoff-sitelink-v4-sync.md`** — the immediately preceding piece of this work, and your
   template. It settles the grain question, the availability question, the raw-allow-list rule and
   the three-column verification method. Then `docs/handoff-tier-rate-crosscheck.md` and
   `docs/handoff-discount-lane.md` for the storEDGE lanes.
5. `apex-app/docs/fms/ssm/` (README + `endpoints/`) and
   `apex-app/packages/api/app/services/fms-ssm/`.

## The job

`v4_api_location` (detail) and `v4_api_location_units` are **not implemented for SSM**.
`FMS_LANE_SUPPORT.ssm` (`syncs/fms/client.ts`) has `detail: false, units: false,
discounts: false`; only `insurance` and `catalog` are true. `syncs/fms/ssm.ts:131-133` returns
`detail: {}` and `units: []` behind a `TODO(ssm)`.

Implement those lanes, plus discounts if the evidence supports it, and **verify against legacy**.

SSM is now the LAST provider with a stubbed units lane: storEDGE, Monument and SiteLink all
publish one. Yardi is entirely stubbed and is a separate, larger job.

## Step 0 — credentials, and confirm the lane before writing code

Read `apex-app/docs/credentials.md`, put the pattern to the operator, and confirm before writing
any credential code. The SiteLink session's answer was "kv_store, and leave the dead `.env` lines
alone for now" — do not assume it carries over.

SSM keys live in `kv_store` per `fms/systemKeys.ts` (`SSM_KEYS`) and `fms/fmsConfig.ts`
(`resolveSsmConfig`). The three map one-to-one onto legacy's `configures` columns, and all three
are populated for YourWay — so unlike Gate 5, whose `sitelink_corp_pass` was NULL and blocked
legacy's own live run until it was supplied out of band, this operator's credential is complete:

| v4 `kv_store` key | legacy column | YourWay |
|---|---|---|
| `fms_ssm_api_url` | `configures.ssm_api_url` | set (36 chars) |
| `fms_ssm_api_username` | `configures.ssm_api_username` | set (9 chars) |
| `fms_ssm_api_password` | `configures.ssm_api_password` | set (22 chars) |

Note SSM carries an **`api_url` per operator** where SiteLink has one shared endpoint — so the
base URL is part of the credential, and a wrong one fails in a way that looks like a dead account.
Confirm `resolveSsmConfig`'s default (if any) rather than assuming the operator's value is
optional. Write them through the sanctioned route, not by hand:

```
PUT /api/v1/users/{userId}/accounts/{accountId}/api-sources/{sourceId}/credentials
```

**Check for an env fallback before assuming there is none.** storEDGE has one because that key is
ours; SiteLink has none because the key is the operator's. Establish which SSM is from
`resolveSsmConfig`, and say so in the handoff.

## Step 1 — get the data locally

**There is no SSM operator imported locally.** `fms/client_urls/` holds `safeguard-self-storage`
(SiteLink, 89 facilities) and `storagelyselfstorage` (storEDGE) and nothing SSM. So unlike the
SiteLink job, the mirrored corpus is not free — you have to create it.

## The target is `yourway-storage` (YourWay Storage), legacy `users.id = 492`

Chosen deliberately. Five facilities is the smallest portfolio that is still a PORTFOLIO, which is
where this provider's open questions live — the SiteLink job ran against a one-site corp and
therefore could not test enumeration at all, and said so as an open item. Its inventory is also
lopsided enough to be interesting rather than uniform:

| `site_id` | `location_code` | Units |
|---|---|---|
| 100002 | `004` | 679 |
| 100003 | `005` | 491 |
| 100001 | `003` | 417 |
| 100000 | `002` | 253 |
| 99999 | `001` | 40 |

1880 units and 2489 discount rows across the five — a real corpus, and a 40-unit facility beside a
679-unit one, which is the shape that exposes a per-facility assumption.

**The location codes are `001`–`005`.** Bare, zero-padded numeric strings. Worth noticing before
they cost you something: they are the storage-key segment for every artifact this lane writes, and
anything that reads one back as a NUMBER loses the padding and addresses `1` instead of `001`.
`site_id` is a separate 99999–100003 space; do not cross them.

The other SSM operators, for context — `storage-star` (115 facilities, 62k units) and
`my-garage-self-storage` (48 / 10.9k) are the ones a per-facility mistake gets expensive on, and
`ssmdemo` (6 / 234) and `smart-self-storage-ohio` (1 / 258) are smaller. A "Storage Star" account
already exists in the local v4 database; leave it alone until YourWay is clean.

Before running `/import`, **check `hasApiPath` in the inventory output**. Gate 5's was `false`,
which meant the import would have brought down no FMS artifacts at all and the prompt's premise
that it gives "half the verification corpus for free" was simply wrong for that operator. Confirm
YourWay has one before spending an import on it — and if it does not, the mirrored corpus has to
come from somewhere else and Step 5's column 2 is not available.

`PROD_USER_API_EMAIL` / `PROD_USER_API_PASSWORD` are already set in `apex-app/.env`. The import CLI
talks HTTP to the **running** API — never stop the API for it.

## Step 2 — what already exists, so you build only what is missing

`packages/api/app/services/fms-ssm/` owns the transport, the token auth and `studlyKeys`. These
ops are **implemented and uncalled** — the work is wiring, not a new client:

| Legacy call (`SsmFacilitiesSyncJob.php`) | Endpoint | v4 function | Status |
|---|---|---|---|
| `:204` | `GET /api/OnlineRental/GetAllUnits?facilityId=` | `getAllUnits` | **uncalled** |
| `:210` | `GET /api/OnlineRental/GetUnitsList?facilityId=` | `getUnitsList` | **uncalled** |
| `:211` | `GET /api/OnlineReservation/GetInsuranceSchemes?storeId=` | `getInsuranceSchemes` | called |
| — | `GET /api/OnlineReservation/GetLocationList` | `getLocationList` | called |
| `:250` | `GET /api/OnlineRental/GetAllDiscounts?facilityId=&unitTypeId=` | `getAllDiscounts` | **uncalled** |
| `:246` | `GET /api/OnlineReservation/GetUnitTypeDiscounts?facilityId=&unitTypeId=` | `getUnitTypeDiscounts` | **uncalled** |
| — | `GetPosItems` | `getPosItems` | called |
| — | `GetMoveInSettings`, `GetStates` | | uncalled; probably not this lane's business |

**There is no obvious facility-detail endpoint.** `GetLocationList` is the only thing that
describes a facility, and legacy builds its whole `site_locations` row from one entry of it
(`:259-284`). That is the SiteLink problem in reverse: SiteLink had a per-location call
(`SiteInformation`) legacy never used, and SSM may have none at all. **Settle this before
designing the detail lane** — if the list is the only source, the per-location child sync cannot
read it without one corp-wide request per facility, and the answer is either to pass the summary
row down from the parent `locations` sync or to accept the extra call and say why. Do not invent a
third option silently.

## Step 3 — settle the GRAIN before writing the normalizer

SSM looks like the first provider where the grain is genuinely per-REAL-unit, which would make it
the second after storEDGE — but confirm it rather than assuming.

Legacy drives its loop from **`GetUnitsList`'s `UnitDetailLists`** and keys
`LocationUnit::updateOrCreate` on the unit (`:317`), while **`GetAllUnits`'s
`allUnitsLevelModels`** is indexed by `UnitId` (`:214-216`) and joined on top for flags. So there
are two unit feeds and legacy reads both — establish which is authoritative for what, the way the
SiteLink lane established `UnitTypePriceList_v2` vs `UnitsInformation_v2`.

Then check the decision against, exactly as the SiteLink job did:

- every `packages/components/base/*unit-card*` reader, and **`components/sdk/unit-data-mapping.ts`
  plus `snap-sizer-engine.ts`, which already branch on `apiType === "ssm"`** — read those branches
  first, they tell you what the consumers already believe about SSM's grain;
- `sdk/checkout-unit-context.ts` (`fromV4Unit`, `matchRequestedUnit`);
- `rental-contract/units.ts` `CanonicalUnit` — and note its `rank` docblock already claims
  *"SSM: `tier.PricingCategoryId` 1-3 → `PricingCategoryId - 1`"*, so unlike SiteLink this provider
  may genuinely publish a tier. Verify that field exists before emitting a rank;
- what `checkout-submit/ssm/` and `reservation-submit/ssm/` send as the unit id — that is the
  contract `CanonicalUnit.id` must satisfy, and it is the argument that settled SiteLink's grain.

## Step 4 — the conditions legacy applies, which are NOT `if`s here

SSM's job carries at least three real filters, and each is a candidate `SYNC_RULE_SUPPORT.ssm`
entry rather than an anonymous branch:

| Legacy | Where | Note |
|---|---|---|
| `UnitStatus` not in `COMPANY_UNIT` / `UNAVAILABLE` | `isStatusAllowed`, `:80-83` | maps onto `unit-status` — but check the mode vocabulary fits before claiming the rule |
| `DoNotDisplayforOnlineReservations` | `isHiddenFromOnlineReservations`, `:91-94` | a genuine website-exclusion flag ⇒ `exclude-from-api`. **Its own docblock says the flag exists on `GetAllUnits` and NOT on `GetUnitsList`** — so it is only readable through the join |
| the per-user discount-API branch | `:243-252` | `$discountApiException = [187]` — user 187 (`storage-star`) calls `GetUnitTypeDiscounts`, everyone else calls `GetAllDiscounts`, under a literal *"I don't know why this logic exists"* comment. **Do not carry a user id into v4.** Two endpoints answering one question is a rule if the answers differ, and dead code if they do not — find out which |

`SYNC_RULE_SUPPORT` now has `storedge` (21 rules) and `sitelink` (6). Add an `ssm` key listing
**only** the rules its normalizer really reads, and reason each omission in the table's own
comment the way the `sitelink` entry does. Do not copy either list.

Every rule default must reproduce today's behaviour exactly.

## Step 5 — verification, three columns

The SiteLink session's method, which is the one to reuse:

1. **Legacy, as published.** The `v2_api_location*.json` the import brings down. Free, high volume,
   but both sides are snapshots taken at different times so every rate and count carries drift.
2. **Apex v4, offline.** Run the REAL normalizer functions over the REAL mirrored `fms_api_*` rows
   and compare field by field. This is stronger than comparing two live runs because the drift
   disappears — but it only proves the NORMALIZER, since it uses legacy's own bytes.
3. **Legacy, live.** A read-only PHP script in `app-storagely-io/._current/` (gitignored, so
   legacy's tree stays clean), modelled on **`._current/gate5-sitelink-crosscheck.php`** — copy its
   structure. Bootstrap Laravel, use the job's OWN client so auth and transport are identical,
   transcribe the resolution from `SsmFacilitiesSyncJob.php` **with line numbers**, and compare
   against v4's published artifacts. This is the only column that proves the two TRANSPORTS agree,
   which is exactly what caught the SiteLink namespace bug.

   Write nothing: no DB write, no S3 export, no queue job. Re-count the affected tables afterwards
   and say so. Run it with
   `docker compose exec -T laravel.test php ._current/<name>.php`.
   Do NOT dispatch the real job — it rewrites five tables and exports before you could read it.

**Then prove the comparison can fail.** Perturb one value in each of a dozen places in the staged
v4 copy and confirm every one is caught. A wall of zeros is not evidence until the detector has
been shown to fire — troubleshooting.md's own rule, and the SiteLink session reported 48 clean
fields before doing this, which was the one real gap in that verification.

**Confirm the running API has your code** before trusting a live sync: compare
`ps -o lstart= -p <api pid>` against the source mtimes. And check the artifact's mtime against the
sync run you think produced it — a silently stale copy is the one way a cross-check reports clean
for the wrong reason.

There are probe scripts worth copying for shape discovery:
`apex-app/scripts/probe-sitelink-facilities.mjs` (the closest model — it does credential-shape
checks, a per-node field census with NEW-field detection, and withholds PII by name) and
`probe-storedge-*.mjs`. All are standalone, import nothing from the repo, and print field
names/types/fill counts rather than values.

## Step 6 — the content boundary

`v4_api_location*` artifacts are **CDN-public at a derivable URL**. Both preceding lanes learned
this the same way, and both answers were an ALLOW-LIST, never a deny-list: a deny-list is correct
only against the field set someone looked at, and a new upstream field publishes on the day the
vendor ships it.

What the SiteLink lane found it had to withhold, as a guide to what to look for in SSM:

- **sitting-tenant data** — `dMovedIn` on 252 of 277 units, `iDaysRented`;
- **the operator's own vendor contract** — subscription flags, store tier, billing reference,
  feature entitlements (a third of `SiteInformation`'s 86 fields);
- **staff names** — `sDivName` read `"FL - <a named regional manager>"` on live data, and legacy
  published it;
- **the operator's conversion funnel** — inquiry/reservation/followup counters.

Assume SSM has equivalents and go looking. Report withheld-on-purpose separately from
unrecognised in the census: one is a decision already taken, the other is a prompt to read
something.

## The one thing SiteLink could not test, and this operator can

`listLocations` across a real portfolio. Gate 5 has ONE site, so the SiteLink lane shipped with
"whether the corp-wide search returns every facility rather than silently capping or geo-filtering"
as an open item — a verify passes on one row, but enumeration needs all of them, and a cap drops
facilities with no error anywhere.

YourWay has five and legacy names all five (`001` – `005`). **Compare `getLocationList`'s count
against that on the first run.** If it returns fewer, the fan-out syncs a subset and every missing
facility is indistinguishable from an operator who never configured one. Put the number in the
handoff either way — a confirmed five is as useful to the next provider as a discovered cap.

## Non-negotiables

- **Verify before you trust a green run.** The cross-package drift guards live in the ROOT vitest
  suite, not in `packages/api`'s jest suite. Run all three:
  ```
  cd apex-app && npx vitest run
  cd apex-app/packages/api && NODE_OPTIONS='--experimental-vm-modules' npx jest --config jest.config.main.js --maxWorkers=1
  cd apex-app && pnpm -r --if-present typecheck
  ```
  Baselines after the SiteLink work merged with `main` (2026-08-31): **521 vitest files / 9918
  tests**, **jest — re-measure, it was 229 suites / 2962 tests before the merge**, 7/7 typechecks.
  `pnpm lint` fails at HEAD with pre-existing problems — don't chase it.
- The two root guards `tests/fms-sync-rules.test.ts` and `tests/api-source-sync-pipeline.test.ts`
  used `sitelink` as their "provider with no rules" example until this session and now use `ssm`.
  **Adding an `ssm` key to `SYNC_RULE_SUPPORT` will break them again** — move the example to
  `yardi` or `monument` and add positive assertions for SSM's set, rather than weakening them.
- Touch `packages/rental-contract`? Rebuild its dist
  (`pnpm --filter @storagely/rental-contract build`) and restart the dev servers, or the platform
  renders stale rules and the API runs an old lane flag.
- Registering a NEW artifact lane means touching the hand-maintained lists in
  `endpoints/registry.ts`, `location-artifacts/artifactLanes.ts`, `imports/fmsMirror.ts`,
  `webpage/src/data-loader.ts`, `components/sdk/data-layer-endpoints.ts` and
  `editor/src/sidebar/panels/endpointUrls.ts`. The SiteLink lanes needed none of this because all
  three artifacts already existed; an `v4_api_ssm_*` lane would need all six.
- **Do not push.** `apex-app` main deploys prod via CircleCI with no approval gate. Two repos means
  two commits, never one. `atlas/` pushes to `storagely-home-base`.
- Never put a real operator's name into a shipped string.
- There is uncommitted work in `apex-app` that is not yours — the reservations /
  `checkout-destination` change. Leave it alone, and check `git status` before staging anything.

## Deliverable

Working `detail` + `units` lanes for SSM, the `FMS_LANE_SUPPORT` flags flipped only for what is
genuinely implemented, a `SYNC_RULE_SUPPORT.ssm` entry that claims only what it applies, tests, and
a `docs/handoff-ssm-v4-sync.md` in the workspace recording the grain decision, the verification
results field by field (including the proof that the detector fires), and what is still missing.
