# CLAUDE.md — Helix workspace root

**One product, three git repos.** This directory is the **workspace repo**: it tracks only the
tooling (`CLAUDE.md`, `Makefile`, `scripts/`, `docs/`, `.claude/commands/`, the `.supabase-local/`
skeleton). The two **app repos** are cloned inside it by `make setup` and are gitignored here
(`/apex-app/`, `/atlas/`) — never commit them into this repo, not even as submodule gitlinks, and
never move workspace tooling into either app repo. `.logs/` and `.env.local` stay untracked.

## Read this first (the `docs/` here are NOT auto-loaded)

This file loads automatically for any session whose working directory is this workspace or
anything under it. **`docs/*.md` does not** — it is reachable only by opening it. So:

- **Before diagnosing any local-dev symptom** (Atlas blank, a 401/403/503, "Select a location",
  an env var that looks set, a port that looks free), read **[docs/troubleshooting.md](docs/troubleshooting.md)**
  before forming a theory. Nearly every failure mode in this stack is silent or misattributing,
  and that file lists the ones already paid for — including the wrong first guesses.
- **Before touching the local Atlas database, the embed, or any secret**, read the matching doc in
  the [Deeper docs](#deeper-docs) table below.
- **Before calling something a bug**, check [docs/open-items.md](docs/open-items.md).

## The two repos

| Dir | App | Serves | Git remote |
|---|---|---|---|
| `apex-app/` | **Helix** — API, component library, website editor, SSR renderer, operator dashboard | `9600` api · `9700` editor · `9701` webpage · `9702` dev SSR · `9720` platform | `storagely-io/apex-app` |
| `atlas/` | **Atlas** — data source-of-truth for companies, locations, websites, FAQs, media, tags | `9730` | `storagely-io/`**`storagely-home-base`** |

⚠️ **The Atlas directory name is not its repo name.** `atlas/` pushes to **`storagely-home-base`**.
Never infer a remote from a directory name here.

## Which repo owns the change

Atlas is embedded in the Helix platform shell as a **full-bleed iframe** (`AtlasRoute.tsx`: *"the
iframe fills the full content area; Atlas owns all chrome inside"*). That iframe boundary is the
ownership seam:

- **Inside the frame** — the page body, Atlas's own nav, lists, forms, company/location/FAQ/media/tag
  surfaces ⇒ **`atlas/`**
- **Around the frame** — the shell, top nav, website + location switchers, scope, URL mirroring, the
  handshake, error overlays, and every `/api/v1` endpoint Atlas calls ⇒ **`apex-app/`**
- Editor, component library, published-site rendering, checkout, reservations ⇒ **`apex-app/`**

If a change spans both, it is **two commits in two repos**. There is no combined history.

## Git rules

- A bare `git …` at this root targets the **workspace repo** (tooling only). App changes always go
  through `git -C apex-app …` / `git -C atlas …` — never rely on cwd to pick the repo.
- The workspace repo must never contain app code: `/apex-app/` and `/atlas/` are gitignored; if
  `git status` here ever shows either directory, stop and fix `.gitignore` rather than committing.
- Never author one commit intended to cover more than one of the three repos.
- Verify before pushing: `git -C <repo> remote -v` and confirm it is the remote you meant
  (`atlas/` pushes to `storagely-home-base` — the name differs from the directory).

## Atlas rules that bite (read `atlas/CLAUDE.md` before working there)

- **Lovable owns deploys.** There is no CI in that repo. A git push alone does **not** deploy.
- **Lovable owns the Supabase schema.** Never apply migrations directly to the hosted project.
- **`rm` does not work** on that mount (`Operation not permitted`). Dead code moves to `_to_delete/`.
- **Lovable regenerates whole files; Claude patches them.** Concurrent edits erase work silently with
  no merge conflict. Check `.lovable/` state before large edits.
- Several paths have named human owners (`src/routes/**`, `src/components/atlas/**`,
  `PlatformShell.tsx`, the `*.server.ts` / `*.functions.ts` write layer). Ask before restructuring.
- A pre-push hook (`scripts/check-invariants.mjs`) guards tool overlap. Don't bypass it.
- Atlas uses **bun**, not pnpm. `npm install` there would create a *tracked* lockfile — don't.

## Local ports

```
9600  helix api        (pnpm dev:api)        <- the readiness signal: GET /api/v1/health
9700  helix editor     (pnpm dev:editor)
9701  helix webpage    (vite)
9702  helix dev SSR    (dev-ssr.ts)
9720  helix platform   (pnpm dev:platform)   <- the ONLY origin Atlas accepts as a dev parent
9730  atlas            (bun run dev:local)
```

**`9710` is production-only** (nginx → SSR cluster). `apex-app/CLAUDE.md` lists it under SSR; locally
the dev SSR server is **`9702`** (`packages/webpage/dev-ssr.ts:63`). Both `9720` and `9730` are
`--strictPort`: a collision is a hard failure, not a fallback.

## Process safety — this can destroy local data

The local Helix database is **PGlite, single-writer**:

- Stop services with **`kill -TERM`, one pid at a time**. Never `kill -9`, never `pkill -f node` — a
  hard kill skips `deactivateServices()` and can corrupt the database.
- The import CLI opens PGlite **directly**, so it cannot run while the API is up. Stop the API first
  (`make import` does this for you).
- The API refuses to boot if `9600` is already bound (`assertPortAvailable`), which is usually an
  orphaned process from a failed run — find it with `make status`.

## Running it

```bash
make setup     # FRESH MACHINE: clone both app repos, scaffold env files,
               #   install deps, stage Supabase migrations, seed a local login
make doctor    # check prerequisites, change nothing
make install   # bun + atlas deps, pnpm deps
make dev       # EVERYTHING — local Supabase (if down), api, platform, atlas,
               #   editor, webpage, dev SSR. The api runs under a supervisor:
               #   if it dies (e.g. a contract dist rebuilt under it), dev.sh
               #   rebuilds stale contracts and restarts it automatically.
               #   Skip the Supabase step with HELIX_SKIP_SUPABASE=1.
make dev-core  # api + platform + atlas only — the Atlas embed loop, ~2GB lighter
make status    # what's listening, and which pid holds it
make sync-atlas # populate Atlas's local data via the sync prod runs hourly
make down      # graceful SIGTERM teardown
make logs      # tail per-service logs
```

Two workspace slash commands (untracked, `.claude/commands/`) wrap the import machinery:
`/import <operator name>` mirrors an operator's prod data locally (Flex + Atlas), and
`/update-import <operator name>` re-pulls the latest via an overwrite re-import. Both drive
`make import` / `make sync-atlas`; the import CLI talks HTTP to the **running** API — never
stop the API for it.

The embed is wired by `apex-app/packages/platform/.env.local` (gitignored):
`VITE_ATLAS_IFRAME_URL=http://localhost:9730?apiBase=http://localhost:9600`. Atlas honours that
`apiBase` **only** when the parent origin is exactly `http://localhost:9720`, so it cannot leak to
production. Vite reads env at boot only — restart the platform after changing it.

## Nothing here fails loudly — read this before diagnosing

Four separate mechanisms in this stack respond to misconfiguration by going **quiet** rather than
erroring. Each has cost hours at least once:

| Silent failure | What you see instead | Detail |
|---|---|---|
| Untagged `atlas_locations` rows | lists are empty; the switcher names a facility while the body says "Select a location" | [docs/atlas-local-data.md](docs/atlas-local-data.md) |
| Missing/mismatched HMAC key | Helix 503s; Atlas says "Atlas signing secret is not configured" — or, mismatched, `Invalid signature` | [docs/secrets-and-env.md](docs/secrets-and-env.md) |
| Missing Supabase grants | every Atlas read is `42501`, logged only to the **browser** console | [docs/local-supabase.md](docs/local-supabase.md) |
| Unmapped nav `section` | a location switch silently drops you to Overview | [docs/embed-and-scope.md](docs/embed-and-scope.md) |

Two corollaries:

- **`make sync-atlas` populates Atlas's local data by running the sync prod runs hourly.** Prefer
  it over writing rows by hand: the lists filter on `fields.helix_tags`, which only the sync
  writes, so hand-written rows are invisible without being missing.
- **An Atlas route returning HTTP 200 proves nothing** — those routes are `ssr: false`, so the
  server returns the SPA shell for a nonexistent path too. Verify the data chain instead.

Start any symptom at **[docs/troubleshooting.md](docs/troubleshooting.md)**.

## Deeper docs

Read the repo's own CLAUDE.md before working in it — they are authoritative and this file is only a
router:

- `apex-app/CLAUDE.md` — architecture, storage philosophy, component/primitive rules, credentials
  doctrine, checkout contract, deploy hosts
- `atlas/CLAUDE.md` — Lovable workflow, ownership table, the in-progress remediation audit
- `atlas/README.md` — the local-dev-against-a-Helix-API flow this workspace automates
- `atlas/docs/iframe-embed.md` — the handshake protocol spec

Workspace-local notes (untracked, this directory) — `docs/`:

| Doc | Covers |
|---|---|
| [docs/troubleshooting.md](docs/troubleshooting.md) | **Any symptom starts here.** Symptom → real cause for every failure this workspace has produced |
| [docs/atlas-local-data.md](docs/atlas-local-data.md) | Where Atlas's local rows come from, the visibility filter, the two homes of the FMS code, derived display names |
| [docs/secrets-and-env.md](docs/secrets-and-env.md) | Three env destinations with three audiences; the shared HMAC key with two names; signing a request by hand |
| [docs/local-supabase.md](docs/local-supabase.md) | Rebuilding the local Atlas DB: why not `db reset`, the grant step, the cron jobs that would POST prod |
| [docs/embed-and-scope.md](docs/embed-and-scope.md) | The handshake, `lock`, how `?pageId=` resolves, and where the section round-trip stops |
| [docs/open-items.md](docs/open-items.md) | Known gaps and the two security items awaiting a decision |
