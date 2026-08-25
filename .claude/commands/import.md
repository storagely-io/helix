---
description: Import an operator's production data into the local stack (Flex + Atlas, 1:1)
argument-hint: <operator name>
---

Import the operator "$ARGUMENTS" from production into the local environment so that BOTH
surfaces work: Flex (editor/webpage with real pages, units, pricing) and the Atlas embed
(company + locations visible). Follow these steps in order. Read
`apex-app/tools/claude-plugins/plugins/import-operator-data/skills/import-operator-data/SKILL.md`
if any step here is ambiguous — this command wraps that skill's flow through `make import`.

## Non-negotiable rule

**Never put a production URL, hostname, subdomain, or website id in front of the user** — not in
match lists, progress updates, reports, or errors. Resolve results and job reports may contain
them; show only account name, website name, and page count. At the end, print the LOCAL editor
URL only. (A clickable prod editor link once nearly led to a live site being edited — this rule
is why the underlying skill exists.)

## Notes on the argument

- The argument is a free-text operator NAME, fuzzy-matched against prod account/website names.
  It is NOT a slug and NOT an FMS apiPath. If the user typed something slug-like (e.g.
  "storagelyselfstorage"), try it as given first; if resolve returns nothing, retry with a
  humanized form (e.g. "storagely self storage" / "Storagely") before asking the user.

## Flow

1. **Stack check** — run `make status`. Everything needed must be up: api :9600 healthy, atlas
   :9730, platform :9720, local Supabase answering. If services are down: `make down` first if
   the state is half-dead (ports held but api unhealthy), then start detached with `make up`
   (tmux). If tmux is unavailable, ask the user to run `make dev` in another terminal and wait.
   Do NOT proceed with a dead API — every import subcommand talks to it over HTTP.

2. **Preflight** — `make import CMD='preflight'`. Stop at the first failure and surface it;
   do not work around a failing preflight. (Missing prod credentials → tell the user which key
   to set in `apex-app/.env`; the error names it.)

3. **Resolve** — `make import CMD='resolve "<operator name>"'`. The returned token lives in
   the API process's memory (1h TTL) and dies on any API restart — if the import later fails
   with an unknown/expired token, resolve again rather than debugging.
   - One match → use its token.
   - Several → AskUserQuestion with a numbered list of account name / website name / page count.
     Nothing else — no subdomains, no URLs, no ids.
   - None → show the `nearest` names and stop.

4. **Existing-copy check (the "clean out existing records" question)** — before importing, check
   whether this operator already exists locally: read the provenance records in
   `apex-app/packages/api/.local-storage/default/system/imports/*.json` (fields: `websiteId`,
   `accountId`, `atlasApiPath`, `importedAt`) and cross-check the account name via the local API
   if needed. If a local copy exists, ask the user (AskUserQuestion):
   - **Overwrite in place** (recommended, the convention) → `mode: "overwrite"` +
     `targetWebsiteId` from provenance. Warn plainly: overwrite deletes every page on the local
     target in phase 1, before anything is fetched, with no rollback.
   - **Remove then fresh import** → `make import CMD='remove <websiteId>'`, then `mode: "create"`.
   - **Abort.**
   If nothing exists locally → `mode: "create"` with a new local account.

5. **Inventory + selection** — `make import CMD='inventory <token>'`. Summarize page counts by
   tag and asset totals, state the defaults, then let the user adjust conversationally or via
   AskUserQuestion:
   - Pages: default everything non-scaffolding.
   - Media: default **keep prod CDN links** (`"assets": "none"` — renders 1:1, images load from
     the public CDN). Offer re-hosting (`"assets": "referenced"`) as the opt-in, noting it took
     ~23 minutes on a 609-page reference site.
   - Always keep `"atlasEndpoints": true` and `"fmsEndpoints": true` — these mirrors are what
     make Atlas metadata and FMS units/pricing work locally; without them every
     `v4_api_atlas_*` key is empty locally, forever.

6. **Import** — write the request JSON to the scratchpad, e.g.:
   ```json
   {
     "targetAccountId": "<from resolve/create or provenance>",
     "createdAccount": true,
     "mode": "create",
     "targetSubdomain": "<operator-slug>-local",
     "selection": { "assets": "none", "atlasEndpoints": true, "fmsEndpoints": true }
   }
   ```
   (`createdAccount: true` only when the account was created for this import; omit
   `targetSubdomain` and set `targetWebsiteId` instead when overwriting.)
   Run `make import CMD='import <token> <file>'`, then poll
   `make import CMD='status <jobId>'` every ~10s until phase `done` (or failure). Phases:
   preparing-target → fetching-pages → (rehosting-assets) → writing-website → writing-pages →
   writing-extras → mirroring-atlas → (mirroring-fms) → done.

7. **Atlas side** — the import wrote Helix data + mirrors, but the Atlas embed needs its own
   rows in local Supabase:
   a. Ensure an `atlas_companies` row exists for the imported account. Check:
      `docker exec -i supabase_db_supabase-local psql -U postgres -d postgres -qAt -c
      "select id, slug from atlas_companies where platform_account_id = '<accountId>'"`.
      If missing, load the account's Atlas surface once in the platform
      (`http://localhost:9720/users/<userId>/accounts/<accountId>/atlas/<websiteId>` — sign in
      first) so `ensureAtlasCompanyForAccount` provisions it; a headless alternative is hitting
      the embed context endpoint via the platform, but browser provisioning is the paved path.
      Re-check the row after.
   b. `make sync-atlas` — populates `atlas_locations`, `fields.helix_tags`,
      `atlas_companies.platform_website_id`, and binds `fields.fms_location`. It prints the
      listable locations; confirm the imported operator's location pages appear. 0 listable
      locations for this company = the sync didn't cover it; diagnose before declaring success
      (an Atlas page returning HTTP 200 proves nothing — routes are ssr:false).

8. **Verify + report** — tell the user, with the LOCAL editor URL only
   (`http://localhost:9700/websites/<localWebsiteId>/pages` or the platform route):
   - counts imported (pages, atlas files/locations, fms files/locations from the job report),
   - the verification steps: open the site locally — FMS components should show real units and
     pricing; Atlas components should show real facility metadata. **Both blank → apiPath didn't
     get set. FMS-only → the Atlas mirror came up empty.**
   - that the Atlas embed for the company now lists its locations.
   Suggest `/update-import $ARGUMENTS` for pulling future prod changes.
