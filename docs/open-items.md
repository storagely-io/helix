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

# Security items awaiting your decision

Neither has been touched.

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
