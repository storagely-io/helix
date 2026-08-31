# HANDOFF — the sync conditions pipeline (UI)

Session of 2026-08-27, evening. Successor to
[docs/handoff-scoped-sync-rules.md](handoff-scoped-sync-rules.md), whose two parts shipped the
rule + condition **engine**. This session built the **screen** the engine was always for.

Approved design: <https://claude.ai/code/artifact/6511ba6c-3df4-439d-bf7d-5bf3fed8f489> — page 1
(direction A) is what was built; page 2 records the three directions not taken.

**Everything is still uncommitted, in `apex-app`** — 47 changed/new files now. Nothing pushed.
Pushing `apex-app` main deploys prod via CircleCI with no approval gate.

---

## What the screen is

One board — **What this connection publishes**: every condition, in the order the sync applies it,
with what it did on the last run.

It opens as a **dialog off the location sync card**, and from nowhere else. Everything on it is
that one sync's doing — `fmsLocationsSync` decides which facilities exist, its `location.detail`
child decides which of each facility's units are published — so the card is where it belongs, and
that is also what makes the reader look at the right card when a number surprises them. The card
wears a one-line summary above the file list (*"4 of 18 conditions are narrowing this feed · 28
units removed on the last run"*) so nobody has to open a dialog to learn there was nothing in it;
the numbers come from `pipelineSummary`, which reads the same two sources the board does.

It replaces two surfaces that were together answering *why is this unit not on my site?* and could
not finish the sentence:

| Was | Now |
|---|---|
| A lane list with a conditions chip per artifact | `ApiSourceSyncTree` keeps the file inventory, provenance line and failed locations — and nothing about rules, beyond a `banner` slot the caller fills |
| `LaneConditionsModal` — 15 rule cards per artifact, exceptions nested inside them | **Deleted.** One dialog for the whole sync: the board + a step inspector |

The shape, and why:

- **Two groups**, because the sync has two grains — `scope: 'location'` rules are decided once for
  the connection, `scope: 'unit'` rules are decided again at every facility. The contract already
  said so (`rulesForProviderInScope`); the old flat list quietly asserted the wrong one about both
  halves.
- **Live counts per step**, from the run's own census.
- **Exceptions as a chip row inside the step's own border** — one level of nesting. They were four
  (page → row → modal → rule card → exception).
- **Inert rules collapsed** behind one line that *names* them.
- **A step inspector on the right**: the connection-wide value, the exceptions in full, and what
  the step removed at each facility.

## The one backend change

`aggregateConditionEffect` now carries each facility's own `dropped` array into its `byLocation`
row. It was already on the per-location job row and was being flattened into the sum on the way
out; the sum cannot answer *where*, and once an exception lets two facilities disagree that is the
only question worth asking. Parsed once and used twice, so the per-facility numbers and the total
beside them can never disagree about which rows were well-formed enough to count.

`byLocation`'s appearance gate is **unchanged**: it still rides only when an exception decided
something. The board degrades with it — no facility switcher, and "28 across every facility — they
all apply this the same way" instead of a breakdown. That is the honest reading, and it is the same
argument the existing docblock makes.

## Two judgement calls worth knowing about

1. **What "inert" means.** A step collapses when it is narrowing nothing, carries no exception in
   force, and removed nothing last run. "Narrowing" is `syncRuleChips`' answer — the same function
   the health strip's *"4 narrowing"* tile counts — **not** `resolved.changed`. The difference is
   load-bearing: `unit-status` drops every reserved unit at its shipped default, so a board keyed on
   `changed` would hide the single most surprising thing the sync does, on exactly the runs where
   nothing happened to be reserved. Reading the same function is also what stops the tile saying
   "4 narrowing" over a board showing one step.

2. **The facility switcher was in the design's "still open" column. It is built**, and it changes
   the **counts only** — it does not re-resolve the rules. Which exception wins at a facility is a
   server-side answer that needs that facility's feed row, and the browser has none; a switcher that
   pretended otherwise would show the wrong resolved value for every condition-bearing exception.
   It appears only when the run reported per-facility numbers, and a facility the run did not report
   on reads *"not recorded for this facility"* rather than falling back to the connection's figures
   with one site's name on them.

## Verified live, against the two sandbox facilities

`storagelyselfstorage` · `25e2ece8-…` and `c93036ab-…`. **Sandbox restored to baseline afterwards**
(config carries no overrides; 140 → 112; 51 + 61 published — verified by counting the artifacts).

Driven in a real browser at `:9720`, screenshotted at every step.

| Check | Result |
|---|---|
| The card, closed | Trigger reads *"4 of 18 conditions are narrowing this feed · 28 units removed on the last run"* |
| Baseline board | 5 facility steps, 4 unit steps, `unit-status −28`, *"show 9 that changed nothing"*, no switcher |
| Selecting a step | Inspector shows the value, an empty exception list, and *"28 across every facility"* |
| Adding an exception from the step row | Chip appears on the step immediately; the editor opens in the inspector; the step turns red and Save says *"1 exception needs fixing"* until it is named |
| Exception in force + sync | `140 → 131`, step badge `−9`, `byLocation` carries `dropped` per facility |
| Facility switcher | Picking the sibling re-reads the board at `70 read · 61 published`, `unit-status −9` |
| *"What it removed"* | Two bars, most-withheld first, from the new per-facility `dropped` |
| Collapse toggle | Expands all 13 unit steps in catalog order, collapses again |
| Restore | 140 → 112, 51 + 61, no `byLocation` |

### Three defects the screenshot caught that the tests did not

All three were invisible until the board was looked at, which is the previous handoff's lesson
holding for a third cycle.

1. **The exception summary row overflowed the inspector.** `RuleOverrides`' expander button is
   `flex-1` with the default `min-width: auto`, so the unbreakable facility UUID in its summary line
   pushed the button — and the 380px panel around it — past its own width. Invisible in the
   `max-w-3xl` modal it used to live in. Fixed with `min-w-0`, and the reason is in the code.
2. **The facility switcher's `<Select>` filled the header.** `Select` starts its class list with
   `w-full`; a `w-auto` passed in `className` resolves by stylesheet order, not by which was passed.
   The width went on a wrapper.
3. **The dialog grew past the viewport and took the save bar with it.** Fixed by capping the panel
   at `xl` and scrolling the two columns inside it, header and save bar pinned. Below `xl` the
   columns stack, so the dialog grows and its wrapper scrolls instead — two short scroll panes one
   above the other are worse than one long page.

One thing that looked like a defect and is not: a `fullPage: true` Playwright screenshot paints a
`position: fixed` scrim once, over the first viewport only, so the page below it photographs
undimmed. Measure the scrim's rect before believing the picture.

## The gap the design assumed and the sandbox does not have

**Facilities render as UUIDs, not names.** `stepByLocation`, the switcher and `describeScope` all
name facilities from `useScopeSources`, and for this connection the server returns `name === code`.
That is a documented pre-existing condition, not new: `checkoutCatalog.ts:160-168` says the Storedge
sync "enumerates from the configured facility UUIDs and has no names lane yet" and borrows names
from the legacy v2 export when one exists. The sandbox has no legacy export and uses the configured
list rather than company discovery, so nothing has a name to borrow.

Names appear by themselves on a connection using **company discovery** (`normalizeStoredgeLocations`
carries them) or one with a legacy export. Closing it for configured-list connections means reading
each facility's `v4_api_location` artifact for a dropdown — N reads per page load, which is the cost
that comment declined. Left alone deliberately; it is the one place the board reads worse than the
design does.

## How to verify

```bash
cd apex-app
pnpm typecheck                                    # 7 packages
npx vitest run                                    # 8637 pass
pnpm lint:primitives                              # clean
cd packages/api && NODE_OPTIONS='--experimental-vm-modules' \
  npx jest --config jest.config.main.js           # 2846 pass — the env var is required
```

Baselines moved by exactly the new tests: 8612 → **8641** (+29, `tests/api-source-sync-pipeline.test.ts`)
and 2842 → **2846** (+4, the per-facility half of `conditionEffect.test.ts`).

The gotchas from the previous handoff all still bite, and two of them bit again this session:

- **`rental-contract` is a built dist.** `npm run build` in `packages/rental-contract` before
  trusting any live measurement. Note that the rebuild `rm -rf dist` **kills the running API** —
  `scripts/dev.sh` restarts it within ~10s, but `make status` will show `api down` in between.
- **`packages/api/.env` has CRLF.** Strip `\r` off `STORAGE_API_KEY`.
- **Platform login:** `POST /api/v1/auth/login` takes `{ email, password }` (not `identifier`);
  patch `storagely.auth.user.forcePasswordReset` to `false` in `localStorage`; the session key is
  `storagely.auth.token`; the route is under `/admin/accounts/`.
- **Two overlays swallow clicks**, not one: `[data-stg-popup]` and the Wingman updates panel
  (`#wingman-bell`, which also mounts a sibling into `document.body`). Remove both before driving.
- Playwright: the workspace has no local install; the npx cache does
  (`~/.npm/_npx/e41f203b7505f1fb/node_modules/playwright`). Use `/usr/bin/chromium-browser` with
  `--no-sandbox`.
- **PGlite is single-writer** — `kill -TERM`, never `kill -9`.

## Where things live

**New**
```
packages/platform/.../syncPipeline.ts              the model: groups, steps, counts, quiet, summary
packages/platform/.../ApiSourceSyncPipeline.tsx    the board
packages/platform/.../SyncStepInspector.tsx        the right-hand panel + save bar
packages/platform/.../SyncPipelineModal.tsx        the dialog shell + the card's trigger row
tests/api-source-sync-pipeline.test.ts             29 tests, all about not inventing a number
```

The model is a `.ts` beside the components because the root vitest runs `environment: "node"` —
the same call `syncRulesDraft.ts` and `scopeRules.ts` make. The inspector is its own module because
the board was 769 lines with it inlined, past CLAUDE.md's ~750 threshold.

**Changed**
```
apiSourcesController.ts        per-facility `dropped` on ConditionEffectLocation
data/api-sources.ts            ConditionEffect / ConditionEffectLocation types (byLocation was
                               never on the platform's copy of the wire type at all)
ApiSourceDetailPage.tsx        `LaneConditionsModal` gone; one `conditionsOpen` dialog opened from
                               the location card. Page layout otherwise unchanged — the health
                               strip is back in the right column where it was
ApiSourceSyncTree.tsx          conditions affordance and the units count line removed; it is the
                               file inventory again. It gained one `banner?: ReactNode` slot,
                               rendered between the provenance line and the file list, so the
                               caller can put the card's trigger where it reads right without this
                               module having to know sync rules exist
syncRuleOverrides.tsx          `min-w-0` on the row button; `blankOverride`/`newOverride` exported
                               so the board can add an exception from a step row; `openException`
                               prop so a chip click opens that exception here
```

**Deleted**
```
packages/platform/.../LaneConditionsModal.tsx
```

## What is NOT done

Unchanged from the previous handoff except where noted.

1. **Nothing committed.** Two commits owed — workspace `docs/` and `apex-app`, separately.
2. **`SECURITY.md` owes two entries**: the `raw` allow-list, and that a condition on a withheld
   field (`max_rate`) renders that value in the platform UI and the run log.
3. **The three missing units lanes** (SiteLink, SSM) and the **Yardi client**. Still the reason the
   catalog has one provider — and now also the reason the board renders for one provider.
4. **MyGarage's substring match** — [open-items.md §5](open-items.md).
5. **Facility names on a configured-list connection** — see the gap section above. *New this
   session.*
6. **No per-step count for the facility group.** `facility-filter` skips are logged
   (`storedge.ts:711`) and recorded nowhere, so a facility step never shows a badge. The design's
   *"−1 skipped · Old Mill — store number is empty"* is the one thing on the board that is not on
   the wire; putting it there means writing the skip list onto the parent sync's job row. *New this
   session.*
7. **`PromoCondition` is still not consolidated** — the fifth copy, deliberate and recorded in
   `sync-conditions.ts`'s docblock.
8. **A field-coverage probe** (`validateFieldMappings`) — still the difference between a filter that
   is wrong and one that is merely inert.

## The lesson worth carrying

Unchanged, and paid for twice more: **compilation is not verification for UI work.** 8,637 vitest,
2,846 Jest and a clean 7-package typecheck all passed over a panel whose exception rows were
spilling out of it, because neither the overflow nor the select width is a thing a test in a node
environment can see. Both died on the first screenshot.
