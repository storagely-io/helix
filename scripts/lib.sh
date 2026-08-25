#!/usr/bin/env bash
# Shared helpers for the Helix workspace dev scripts.
# Sourced, never executed directly.

HELIX_ROOT="${HELIX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APEX="$HELIX_ROOT/apex-app"
ATLAS="$HELIX_ROOT/atlas"
LOGDIR="$HELIX_ROOT/.logs"
RUNDIR="$HELIX_ROOT/.run"
# Written by down.sh / dev.sh's cleanup BEFORE ports are stopped; dev.sh's API
# restart loop checks it so a deliberate stop doesn't get "helpfully" undone by
# an automatic restart. dev.sh clears it on startup.
STOP_SENTINEL="$LOGDIR/.stop-requested"

# bun installs to ~/.bun/bin and only appends to interactive shell profiles, so a
# `make` subshell won't see it. Put it on PATH here so every target works whether
# or not the profile has been re-sourced.
[ -d "$HOME/.bun/bin" ] && case ":$PATH:" in *":$HOME/.bun/bin:"*) ;; *) PATH="$HOME/.bun/bin:$PATH";; esac
# Same for the Supabase CLI, installed as a user-local binary.
[ -d "$HOME/.local/bin" ] && case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH";; esac
export PATH

# --- bind host -------------------------------------------------------------
# The Vite dev servers bind 127.0.0.1 by default (the platform's package script is
# a bare `vite --port 9720`; Atlas's dev:local hardcodes `--host localhost`).
# Inside WSL2 that is frequently NOT reachable from a Windows browser: WSL's
# localhost port-proxy is unreliable for listeners bound only to 127.0.0.1 in the
# VM, so the page fails with ERR_CONNECTION_REFUSED while curl inside WSL gets 200.
# Binding 0.0.0.0 is the standard fix, so we default to it under WSL.
#
# Override: HOST=127.0.0.1 make dev   (or any address)
#
# NOTE: this makes the dev servers reachable on your LAN. It does NOT mean you
# should browse via the WSL IP — Atlas's parent-origin allowlist is exactly
# http://localhost:9720, so any other host breaks the embed handshake. Bind wide,
# browse on localhost.
if [ -z "${HELIX_HOST:-}" ]; then
  if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
    HELIX_HOST="0.0.0.0"; HELIX_HOST_REASON="WSL detected"
  else
    HELIX_HOST="127.0.0.1"; HELIX_HOST_REASON="default"
  fi
else
  HELIX_HOST_REASON="HOST override"
fi
HOSTFLAG="--host $HELIX_HOST"

# --- workspace-local secrets / overrides ------------------------------------
# helix/.env.local is gitignored in the workspace repo and outside both app
# repos — the right home for local-only values. `make setup` scaffolds it.
#
# It exists because Vite surfaces only VITE_-prefixed entries to the app, and
# NOTHING from a .env file reaches process.env for Atlas's SERVER code. Verified:
# putting SUPABASE_SERVICE_ROLE_KEY in atlas/.env.local left the server still
# reporting it missing. Exporting into the process is the mechanism that works
# (same as HELIX_BASE_URL below).
#
# Anything set here is exported to every service this workspace starts.
if [ -f "$HELIX_ROOT/.env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$HELIX_ROOT/.env.local"
  set +a
fi

# --- Atlas server-side Helix base -------------------------------------------
# The browser's ?apiBase= override only steers Atlas's CLIENT-side calls. Atlas
# also talks to Helix from its SERVER (TanStack Start server functions): the
# session verify, the access oracle, page/theme/brand reads — 28 modules, all
# reading process.env.HELIX_BASE_URL and all defaulting to
# https://api.getstoragely.com.
#
# Unset, that means a LOCAL session token gets verified against PRODUCTION Helix,
# which fails as "session verify rejected (401)". Vite does not copy non-VITE_
# entries from .env files into process.env, so this has to be exported into the
# process rather than written to atlas/.env.local.
HELIX_API="${HELIX_API:-http://localhost:9600}"

# Service table: name|port|dir|command
# Ordered — api first because everything else wants it ready.
#
# The Vite services are invoked directly rather than through their package `dev`
# scripts so we can set --host. `exec vite` runs the workspace's own vite binary,
# so this is the same server with one extra flag. The API (Hapi) already binds
# 0.0.0.0 and needs no flag.
CORE_SERVICES=(
  "api|9600|$APEX|pnpm dev:api"
  "platform|9720|$APEX|pnpm --filter @storagely/platform exec vite --port 9720 --strictPort $HOSTFLAG"
  "atlas|9730|$ATLAS|HELIX_BASE_URL=$HELIX_API bun x vite dev --port 9730 --strictPort $HOSTFLAG"
)
EXTRA_SERVICES=(
  "editor|9700|$APEX|pnpm --filter @storagely/editor exec vite --port 9700 --strictPort $HOSTFLAG"
  # The package's own dev script is `vite --port 9701 & tsx dev-ssr.ts & wait`,
  # which takes no --host — so :9701 bound 127.0.0.1 while every other service
  # bound $HELIX_HOST (unreachable from a Windows browser under WSL). Recreate
  # the same two servers with the host flag on the vite half.
  "webpage|9701|$APEX/packages/webpage|pnpm exec vite --port 9701 $HOSTFLAG & pnpm exec tsx dev-ssr.ts & wait"
)

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'
else
  C_RESET=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_BOLD=
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s  ok %s%s\n'   "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%swarn %s%s\n'   "$C_YELLOW" "$C_RESET" "$*"; }
bad()  { printf '%sFAIL %s%s\n'   "$C_RED" "$C_RESET" "$*"; }
head1(){ printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# Pids listening on a TCP port, newline separated. Empty if free.
pids_on_port() {
  local port="$1"
  ss -ltnpH "sport = :$port" 2>/dev/null \
    | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
}

port_free() { [ -z "$(pids_on_port "$1")" ]; }

# Does this pid look like one of OUR services? Every workspace service runs from
# under $HELIX_ROOT, so the path in its command line is a reliable signal. Used to
# tell "a previous `make dev` is still up" apart from "something else took the
# port" — those need completely different advice.
is_workspace_pid() { ps -o args= -p "$1" 2>/dev/null | grep -q -- "$HELIX_ROOT/"; }

port_held_by_workspace() {
  local pid
  for pid in $(pids_on_port "$1"); do is_workspace_pid "$pid" && return 0; done
  return 1
}

# Poll the Helix API health endpoint until it answers. Returns 1 on timeout.
wait_for_api() {
  local tries="${1:-60}" i=0
  while [ "$i" -lt "$tries" ]; do
    if curl -fsS --max-time 2 "http://localhost:9600/api/v1/health" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1)); sleep 1
  done
  return 1
}

# Wait for any TCP port to accept connections.
wait_for_port() {
  local port="$1" tries="${2:-90}" i=0
  while [ "$i" -lt "$tries" ]; do
    port_free "$port" || return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}

# Stop lingering SUPERVISOR processes for workspace services.
#
# Why this exists: stopping by port only kills the process that BOUND the port.
# The Helix API runs under `tsx watch`, which is a supervisor — kill the child and
# the watcher respawns it on the next file change, silently re-taking :9600. Vite
# behaves similarly. So after freeing the ports we sweep the supervisors.
#
# Order matters and is deliberate: callers must port-stop FIRST so the API child
# gets its own SIGTERM and runs deactivateServices() (clean PGlite shutdown),
# THEN sweep. Killing the supervisor while the child is live risks the supervisor
# hard-killing it, which is the corruption case we're avoiding.
#
# Only processes whose command line is under $HELIX_ROOT are touched, and shell /
# make wrappers are deliberately left alone — one of those may be the user's own
# terminal.
sweep_supervisors() {
  local pats=(
    "tsx/dist/cli.mjs watch app/server.ts"
    "vite dev --port 973"
    "packages/platform/node_modules/.bin/../vite"
    "packages/editor/node_modules/.bin/../vite"
    "packages/webpage/node_modules/.bin/../vite"
    "dev-ssr.ts"
    "tee -a $LOGDIR"
  )
  local pat pid
  local -a targets=()
  for pat in "${pats[@]}"; do
    while read -r pid _; do
      [ -z "$pid" ] && continue
      # Never touch shell/make wrappers — could be the caller's own terminal.
      ps -o args= -p "$pid" 2>/dev/null | grep -qE '(^|/)(bash|sh|make) ' && continue
      is_workspace_pid "$pid" || continue
      case " ${targets[*]:-} " in *" $pid "*) continue ;; esac
      targets+=("$pid")
    done < <(pgrep -af -- "$pat" 2>/dev/null | grep -F -- "$HELIX_ROOT/" || true)
  done

  if [ "${#targets[@]}" -eq 0 ]; then
    printf '  %sno orphaned supervisors%s\n' "$C_DIM" "$C_RESET"
    return 0
  fi

  for pid in "${targets[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done

  # Verify rather than assume: a supervisor can take a beat to unwind, and
  # reporting "swept" while one is still alive is how a respawned server ends up
  # holding a port nobody expects.
  local i=0 alive
  while [ "$i" -lt 20 ]; do
    alive=()
    for pid in "${targets[@]}"; do kill -0 "$pid" 2>/dev/null && alive+=("$pid"); done
    [ "${#alive[@]}" -eq 0 ] && { ok "swept ${#targets[@]} orphaned supervisor process(es)"; return 0; }
    i=$((i + 1)); sleep 0.25
  done
  warn "swept ${#targets[@]}, but ${#alive[@]} still alive: ${alive[*]}"
  say "     Left alone deliberately — inspect with: ps -o pid,args -p ${alive[0]}"
  return 1
}

# Is the root `pnpm dev` (pnpm -r --parallel dev) running?
#
# This is the collision that is invisible to a port check: that command starts
# `tsc -w` watchers on rental-contract and workflow-contract, which WIPE and
# rewrite dist/ — and the API imports their compiled output, so it dies mid-rebuild
# with ERR_MODULE_NOT_FOUND. The watchers bind no port, so nothing else here would
# notice them. Running both orchestrators at once also means two API processes
# contending for single-writer PGlite.
# Is a pid running inside this workspace? Scoped by its CWD via /proc, not by
# argv: a process launched with relative paths (`node ../../node_modules/.bin/tsc`)
# has no absolute root in its command line at all, so argv matching silently misses
# it. argv is kept only as a fallback for a process that chdir'd elsewhere.
pid_in_workspace() {
  local cwd
  cwd="$(readlink -f "/proc/$1/cwd" 2>/dev/null)" || cwd=""
  case "$cwd" in "$HELIX_ROOT"|"$HELIX_ROOT"/*) return 0 ;; esac
  ps -o args= -p "$1" 2>/dev/null | grep -qF -- "$HELIX_ROOT/"
}

pnpm_dev_pids() {
  # NOTE on matching: `pgrep -af <pattern>` also matches any *wrapper* whose command
  # line merely CONTAINS the pattern — including the shell running this check and any
  # diagnostic command mentioning it. That false positive would refuse to start
  # `make dev` for no reason, so candidates are filtered by our own tooling first,
  # then scoped to the workspace by CWD.
  #
  # Shells are NOT excluded wholesale (unlike sweep_supervisors): the real root
  # orchestrator is literally `sh -c pnpm -r --parallel dev`.
  local pid args
  while read -r pid args; do
    [ -z "$pid" ] && continue
    [ "$pid" = "$$" ] && continue
    case "$args" in
      *pgrep*|*shell-snapshots*|*preflight.sh*|*lib.sh*|*down.sh*|*status.sh*) continue ;;
    esac
    pid_in_workspace "$pid" || continue
    echo "$pid"
  done < <( { pgrep -af -- "tsconfig.build.json" 2>/dev/null
              pgrep -af -- "parallel dev" 2>/dev/null; } ) | sort -u
}

# Do the contract packages have USABLE compiled output? Checking the directory is
# not enough: a dist/ caught mid-rebuild exists but has no entry point, and that is
# exactly what takes the API down.
contracts_built() {
  local p newer
  for p in rental-contract workflow-contract; do
    [ -f "$APEX/packages/$p/dist/index.js" ] || return 1
    # Existence is not freshness, and this is the failure it used to miss: a
    # dist/ built BEFORE the last source edit still resolves, so the start looks
    # clean, and then the API dies at runtime with "does not provide an export
    # named X" the first time anything imports a newly added symbol. Rebuild
    # whenever a source file is newer than the emitted entry point.
    newer="$(find "$APEX/packages/$p" -name '*.ts' \
      -newer "$APEX/packages/$p/dist/index.js" \
      -not -path '*/dist/*' -not -path '*/node_modules/*' -print -quit 2>/dev/null)"
    [ -n "$newer" ] && return 1
  done
  return 0
}

# Stop the whole API tree: the bound child first (so PGlite closes via
# deactivateServices), THEN its tsx-watch supervisor — which survives its
# child's death and would otherwise respawn onto :9600 on the next file change.
# Used by dev.sh's watchdog and by setup.sh's boot-once-then-seed step.
api_tree_down() {
  stop_port 9600 "api" >/dev/null 2>&1 || true
  local pid _args
  while read -r pid _args; do
    [ -n "$pid" ] && is_workspace_pid "$pid" && kill -TERM "$pid" 2>/dev/null
  done < <(pgrep -af -- "tsx/dist/cli.mjs watch app/server.ts" 2>/dev/null | grep -F -- "$HELIX_ROOT/" || true)
}

# Graceful stop. SIGTERM only, one pid at a time, then verify.
# NEVER change this to kill -9 or pkill: the Helix API runs PGlite as a
# single-writer embedded database, and a hard kill skips deactivateServices()
# and can leave the dev database corrupt.
stop_port() {
  local port="$1" label="${2:-$1}" pids pid i
  pids="$(pids_on_port "$port")"
  [ -z "$pids" ] && { printf '  %s%-10s :%-5s not running%s\n' "$C_DIM" "$label" "$port" "$C_RESET"; return 0; }
  for pid in $pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  i=0
  while [ "$i" -lt 20 ]; do
    port_free "$port" && { ok "$(printf '%-10s :%-5s stopped' "$label" "$port")"; return 0; }
    i=$((i + 1)); sleep 0.5
  done
  warn "$(printf '%-10s :%-5s still bound after SIGTERM (pids: %s)' "$label" "$port" "$(pids_on_port "$port" | tr '\n' ' ')")"
  say "     Left alone on purpose — a hard kill here can corrupt the PGlite dev DB."
  return 1
}
