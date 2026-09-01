# Helix workspace — local-development knowledge

These notes are **workspace scaffolding, not product documentation.** They live at the
untracked workspace root on purpose (see `../CLAUDE.md`): neither `apex-app` nor `atlas` has
a history that should carry them, and the local-dev arrangement they describe is not how
production is assembled.

`../CLAUDE.md` is the router a session reads first. These are the long-form versions of the
things it can only summarise.

| Doc | Read it when |
|---|---|
| [troubleshooting.md](troubleshooting.md) | **Start here for any symptom.** Symptom → real cause, for every failure mode this workspace has actually produced. Most of them are silent or misattributing. |
| [atlas-local-data.md](atlas-local-data.md) | Atlas shows nothing, shows "Select a location", or names a facility wrongly. Where Atlas's local rows come from, and the filter that makes a row **invisible without being missing**. |
| [secrets-and-env.md](secrets-and-env.md) | An env var "is set" but the app disagrees. The delivery model (three different destinations), the shared HMAC key with two names, and a copy-paste recipe for signing a request by hand. |
| [local-supabase.md](local-supabase.md) | Rebuilding or repairing the local Atlas database. Why `supabase db reset` cannot be used here, the grant step that is easy to omit and fails at 100%, and the cron jobs that would otherwise POST production. |
| [embed-and-scope.md](embed-and-scope.md) | The shell↔Atlas iframe: the handshake, what `lock` carries, how `?pageId=` resolves to a location, and why the section round-trip drops some surfaces. |
| [open-items.md](open-items.md) | Before assuming something is broken. Known gaps, deliberate omissions, and the security items awaiting a decision. |

## The FMS sync-lane handoffs

One per session, newest first. Each records what shipped, the decisions and their evidence, the
verification numbers, and what it left undone — so the next provider starts from the last one's
open items rather than from the code.

| Handoff | Provider / subject |
|---|---|
| [handoff-ssm-v4-sync.md](handoff-ssm-v4-sync.md) | **SSM** — detail, units and discounts. Physical-unit grain; the location code that was addressing the wrong folder; the rent-roll exposure |
| [handoff-sitelink-v4-sync.md](handoff-sitelink-v4-sync.md) | **SiteLink** — the SOAP namespace that had made every SiteLink call fail; coverage and the catalog, the latter behind a filter that keeps `Late Fee` off a checkout. **Its "what shipped" section is superseded — read the banner at the top** |
| [handoff-tier-rate-crosscheck.md](handoff-tier-rate-crosscheck.md) | **storEDGE** — SP-1261, the `unit_group_tier_rates` cross-check |
| [handoff-discount-lane.md](handoff-discount-lane.md) | **storEDGE** — `v4_api_location_discounts`, and the audit that started this sequence |
| [handoff-storedge-lanes-and-conditions.md](handoff-storedge-lanes-and-conditions.md) | **storEDGE** — the first real detail + units lanes, and the conditions audit |
| [handoff-scoped-sync-rules.md](handoff-scoped-sync-rules.md) · [handoff-sync-conditions-ui.md](handoff-sync-conditions-ui.md) · [handoff-sync-pipeline-ui.md](handoff-sync-pipeline-ui.md) | the sync-rule contract and the operator surfaces that render it |
| [handoff-v4-location-cutover.md](handoff-v4-location-cutover.md) | the cutover this whole sequence serves |

**Yardi is the only provider left with nothing implemented.** Everything else publishes a real
units lane.

## Orientation in 60 seconds

```
make doctor       # prerequisites + config, changes nothing
make dev          # api :9600 + platform :9720 + atlas :9730
make sync-atlas   # populate Atlas's local data the way prod does
make status       # listeners, data verdict, embed verdict, git state
make down         # graceful SIGTERM (never kill -9 — PGlite is single-writer)
```

Then browse **`http://localhost:9720`** — `localhost`, not the WSL IP. Atlas only accepts
`http://localhost:9720` as a parent origin.

## The one thing worth internalising

Almost nothing in this stack fails loudly. A missing secret makes a route **dormant** (503 on
one side, a calm sentence on the other). A missing grant makes every read a permission error
the browser never shows. An untagged database row is **filtered out** rather than reported.
An unmapped nav section is **dropped** rather than rejected.

So the diagnostic habit that works here is: *reproduce the app's own query or request
yourself, at the layer that fails, and look at the raw answer.* Every fix in
[troubleshooting.md](troubleshooting.md) was found that way, and several wrong first guesses
were avoided by it — or, where they weren't, that is recorded too.
