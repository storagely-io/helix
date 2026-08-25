# Helix workspace — two repos, one product.
#
# Deliberately a thin dispatcher; the logic lives in scripts/ so it can be read
# and debugged on its own. Nothing here is git-tracked: the workspace root is not
# a git repo. Keep it that way.

SHELL := /usr/bin/env bash
S     := ./scripts

.PHONY: help setup dev dev-core dev-full restart up attach down status sync-atlas supabase-up supabase-down supabase-wire doctor install wire logs import supabase-help clean-logs

help:
	@printf "\n  \033[1mHelix workspace\033[0m  (apex-app + atlas)\n\n"
	@printf "    make setup          fresh machine: clone both app repos, scaffold env\n"
	@printf "                        files, install deps, seed a local login\n"
	@printf "    make dev            EVERYTHING: local Supabase, api :9600, platform :9720,\n"
	@printf "                        atlas :9730, editor :9700, webpage :9701, dev SSR :9702\n"
	@printf "    make dev-core       api + platform + atlas only (the Atlas embed loop)\n"
	@printf "    make up / attach    same as dev, detached in tmux / re-attach\n"
	@printf "    make restart        stop whatever is running, then start fresh\n"
	@printf "    make down           graceful SIGTERM teardown (never kill -9)\n"
	@printf "    make status         what is listening, plus per-repo git state\n"
	@printf "    make doctor         check prerequisites, change nothing\n"
	@printf "    make install        pnpm deps, bun, atlas deps, embed wiring\n"
	@printf "    make wire           (re)write the Atlas embed env override\n"
	@printf "    make logs           tail per-service logs\n"
	@printf "    make import CMD=..  run the import tool safely (stops the API first)\n"
	@printf "    make supabase-help  Atlas data-target status and how to go local\n"
	@printf "    make sync-atlas     run Atlas's real Helix page-catalog sync (prod path)\n\n"
	@printf "  Repos: apex-app -> storagely-io/apex-app\n"
	@printf "         atlas    -> storagely-io/storagely-home-base  (name differs!)\n\n"

# The full stack is the DEFAULT. The platform shell iframes the editor (:9700)
# and the editor's canvas iframes the renderer (:9701), so a core-only start
# leaves those surfaces showing a browser connection error rather than a page.
# Starting everything costs ~2GB more RSS and two more ports that can conflict;
# that trade is worth it over losing time to a half-started stack.
# Fresh-machine bootstrap: clones apex-app/ and atlas/ (they are NOT part of
# this repo — see .gitignore), scaffolds the untracked env files, installs
# dependencies, stages the Supabase migrations, seeds a local login. Idempotent.
setup:
	@$(S)/setup.sh

dev:
	@HELIX_FULL=1 HELIX_HOST=$(HOST) $(S)/dev.sh

# Opt out: api + platform + atlas only. Enough for Atlas embed work, and skips
# the two heaviest processes in the stack.
dev-core:
	@HELIX_FULL=0 HELIX_HOST=$(HOST) $(S)/dev.sh

# Retained as an alias for muscle memory — same as `make dev`.
dev-full: dev

restart:
	@$(S)/down.sh
	@HELIX_FULL=1 HELIX_HOST=$(HOST) $(S)/dev.sh

up:
	@command -v tmux >/dev/null || { echo "  tmux not installed"; exit 1; }
	@if tmux has-session -t helix 2>/dev/null; then echo "  session already up — make attach"; exit 1; fi
	@tmux new-session -d -s helix -n dev "HELIX_FULL=1 HELIX_HOST=$(HOST) $(S)/dev.sh"
	@printf "  started detached — make attach\n"

attach:
	@tmux attach -t helix

down:
	@$(S)/down.sh
	@tmux kill-session -t helix 2>/dev/null || true

status:
	@$(S)/status.sh

doctor:
	@$(S)/preflight.sh

install:
	@$(S)/install.sh

wire:
	@$(S)/wire-embed.sh

logs:
	@mkdir -p .logs && tail -n 40 -F .logs/*.log

import:
	@$(S)/import.sh $(CMD)

supabase-help:
	@$(S)/supabase.sh status

supabase-up:
	@$(S)/supabase.sh up

supabase-down:
	@$(S)/supabase.sh down

supabase-wire:
	@$(S)/supabase.sh wire

# Populate Atlas's local data by running the sync PROD runs hourly, rather than
# hand-writing rows: it reconciles Helix's page catalog into atlas_locations and
# sets the fields (helix_tags) every locations list filters on. Takes no
# arguments -- it discovers accounts and websites from Helix itself.
sync-atlas:
	@$(S)/sync-atlas.sh

clean-logs:
	@rm -f .logs/*.log && echo "  logs cleared"
