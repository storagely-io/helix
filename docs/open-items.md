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
