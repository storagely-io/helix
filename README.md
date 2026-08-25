# Helix workspace

Local-dev tooling for running the whole Storagely product — **Helix/Flex**
(`apex-app`) and **Atlas** (`atlas`) — as one stack, plus Claude Code commands for
mirroring an operator's production data locally.

The two app repos are **not** part of this repo. `make setup` clones them
side-by-side into `apex-app/` and `atlas/` (both gitignored here).

## Quickstart

```bash
git clone <this repo> helix && cd helix
make setup      # clones both app repos, scaffolds env files, installs deps,
                # seeds a local login. Asks for the FontAwesome Pro token once.
make dev        # local Supabase + api + platform + atlas + editor + webpage + SSR
```

Then open http://localhost:9720 and sign in with the `LOCAL_USER_API_*`
credentials `make setup` wrote into `apex-app/.env`.

Prerequisites: git, node, pnpm, docker, the [supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started);
`make setup` installs bun itself. You also need the team's FontAwesome Pro npm
token (setup tells you exactly where to put it) and read access to both GitHub
repos.

## Importing production data

With `PROD_USER_API_EMAIL` / `PROD_USER_API_PASSWORD` set in `apex-app/.env`:

- `/import <operator name>` (in Claude Code) — mirror an operator's prod site
  locally: pages, theme, redirects, Atlas metadata, FMS units/pricing mirrors.
- `/update-import <operator name>` — re-pull the latest prod data for an
  operator you already imported (overwrite in place).
- Or drive the CLI directly: `make import CMD='...'` (see `make import`).

## Day to day

```bash
make dev        # everything, foreground; Ctrl-C stops it all
make up/attach  # same, detached in tmux
make status     # what's listening, data health, embed readiness
make sync-atlas # reconcile Helix's page catalog into Atlas's local DB
make down       # graceful stop (leaves Supabase running; make supabase-down stops it)
make doctor     # prerequisite check, changes nothing
```

**Read `CLAUDE.md` before working here** — it routes to the deeper docs
(`docs/`), including the troubleshooting guide that maps every known silent
failure to its real cause.
