#!/usr/bin/env bash
# Start the Helix workspace in the foreground with aggregated, prefixed logs.
# One Ctrl-C stops everything gracefully.
#
# Ordered on purpose: `pnpm -r --parallel dev` has no readiness ordering, but the
# platform shell and Atlas both call the API during boot, so the API goes first
# and we WAIT for its health endpoint before starting the others.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Default is the FULL stack: the platform shell iframes the editor (:9700), and
# the editor's canvas in turn iframes the renderer (:9701), so a core-only start
# leaves those surfaces showing a connection error rather than a page. Opt out
# with `make dev-core` (HELIX_FULL=0) when you only want the Atlas embed loop.
FULL="${HELIX_FULL:-1}"
mkdir -p "$LOGDIR"
# A previous down/cleanup leaves the sentinel behind; a fresh start means "run".
rm -f "$STOP_SENTINEL"

if ! HELIX_FULL="$FULL" "$HELIX_ROOT/scripts/preflight.sh" --ports-fatal; then
  echo; bad "refusing to start — preflight failed"; exit 1
fi

# Wire the embed BEFORE anything starts: Vite reads env only at boot, and the
# Atlas iframe origin embeds the LAN IP, which changes across reboots.
"$HELIX_ROOT/scripts/wire-embed.sh"

# Local Supabase is part of the stack: Atlas boots fine without it and then
# fails every read as 'TypeError: fetch failed' / UNKNOWN_ACCOUNT — the classic
# silent failure. Start it here (idempotent) rather than hoping it's up.
# Opt out with HELIX_SKIP_SUPABASE=1 (e.g. deliberately targeting the hosted
# project). The stack has its own lifecycle: `make down` leaves it running.
if [ "${HELIX_SKIP_SUPABASE:-0}" != "1" ]; then
  if curl -fsS --max-time 3 "http://127.0.0.1:54321/rest/v1/" -o /dev/null 2>/dev/null; then
    ok "local Supabase already up (127.0.0.1:54321)"
  else
    head1 "Starting local Supabase (Atlas's database)"
    if ! "$HELIX_ROOT/scripts/supabase.sh" up; then
      bad "local Supabase failed to start — refusing to boot Atlas dataless"
      say "     Every Atlas read would fail silently (UNKNOWN_ACCOUNT / fetch failed)."
      say "     Fix the error above, or HELIX_SKIP_SUPABASE=1 make dev to skip."
      exit 1
    fi
    # supabase.sh wire may have rewritten the keys in helix/.env.local after
    # lib.sh already sourced it — re-export so the services get current values.
    set -a; . "$HELIX_ROOT/.env.local"; set +a
  fi
fi

SERVICES=("${CORE_SERVICES[@]}")
[ "$FULL" = "1" ] && SERVICES+=("${EXTRA_SERVICES[@]}")

STARTED_PORTS=()
CHILD_PIDS=()

cleanup() {
  trap '' INT TERM
  # BEFORE any port is stopped: the API supervisor loop restarts the API when it
  # exits, and this file is how it tells a deliberate stop from a crash.
  touch "$STOP_SENTINEL"
  head1 "Stopping"
  # Stop by port: SIGTERM, one pid at a time. See lib.sh stop_port for why this
  # is never kill -9 — PGlite is single-writer and a hard kill can corrupt it.
  local i
  for ((i=${#STARTED_PORTS[@]}-1; i>=0; i--)); do
    IFS='|' read -r n p <<< "${STARTED_PORTS[$i]}"
    stop_port "$p" "$n" || true
  done
  for pid in "${CHILD_PIDS[@]:-}"; do kill -TERM "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  say ""
  ok "workspace stopped"
}
trap cleanup INT TERM EXIT

# The two contract packages are tsc-only and other packages import their compiled
# output, so it must be COMPLETE before anything starts. Root `predev` rebuilds
# every time; we rebuild only when the entry point is actually missing — checking
# for the directory alone would accept a dist/ caught mid-rebuild, which is what
# takes the API down with ERR_MODULE_NOT_FOUND.
if ! contracts_built; then
  head1 "Building contract packages (first run)"
  (cd "$APEX" && pnpm --filter @storagely/rental-contract build && pnpm --filter @storagely/workflow-contract build) \
    || { bad "contract build failed"; exit 1; }
fi

# Launch one service, backgrounded. The captured pid is the SERVICE subshell
# itself (which exec's into the real command) — not the tail of a log pipeline.
# The previous `... | sed | tee &` form put tee's pid in CHILD_PIDS, so the
# cleanup kill only ever reached the log writers; process substitution keeps the
# same prefixed/tee'd logging while leaving the service as the job bash reports.
launch() {
  local name="$1" dir="$2" cmd="$3"
  ( cd "$dir" && exec stdbuf -oL -eL bash -lc "$cmd" ) \
    > >(stdbuf -oL sed -u "s/^/$(printf '%-9s' "$name")| /" | tee -a "$LOGDIR/$name.log") 2>&1 &
}

start_service() {
  local name="$1" port="$2" dir="$3" cmd="$4"
  : > "$LOGDIR/$name.log"
  launch "$name" "$dir" "$cmd"
  CHILD_PIDS+=("$!")
  STARTED_PORTS+=("$name|$port")
}

# The API gets a supervisor loop instead of a one-shot start. Why: anything that
# rewrites a contract package's dist/ while the API runs (a stray build, the
# root pnpm dev's tsc -w) makes tsx restart the API mid-wipe and it dies with
# ERR_MODULE_NOT_FOUND — which used to leave the whole workspace headless until
# a human noticed.
#
# The watchdog is HEALTH-based, not process-exit-based, and that is load-bearing:
# `tsx watch` survives its child's crash (it only respawns on the next file
# change), so the process tree stays alive while :9600 is dark — waiting on the
# process would never fire. Verified live: the 11:53 crash left tsx (pid 15171)
# running for two hours over a dead API.
# api_tree_down lives in lib.sh (setup.sh uses it too).
api_supervisor() {
  local boot_failures=0 api_pid started healthy_once misses i
  while :; do
    started=$SECONDS
    launch "api" "$APEX" "pnpm dev:api"
    api_pid=$!
    healthy_once=0; misses=0
    while kill -0 "$api_pid" 2>/dev/null; do
      [ -f "$STOP_SENTINEL" ] && return 0
      sleep 5
      if curl -fsS --max-time 2 "http://localhost:9600/api/v1/health" >/dev/null 2>&1; then
        healthy_once=1; misses=0
      else
        misses=$((misses + 1))
      fi
      # Once healthy: 4 consecutive dark checks (~20s) = crashed or wedged.
      # Never healthy: give a cold boot (incl. a predev contract build) 120s.
      if { [ "$healthy_once" = "1" ] && [ "$misses" -ge 4 ]; } \
         || { [ "$healthy_once" = "0" ] && [ $((SECONDS - started)) -ge 120 ]; }; then
        warn "api health dark on :9600 — recycling the api process tree"
        api_tree_down
        break
      fi
    done
    # Give the wrapper a moment to unwind after the tree came down.
    i=0; while kill -0 "$api_pid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
    [ -f "$STOP_SENTINEL" ] && return 0
    # Our tree is gone but :9600 is bound and healthy → some OTHER process owns
    # the API (e.g. one started standalone while ours was recovering). Restarting
    # here would churn forever: each new child dies on assertPortAvailable while
    # the health check keeps passing against the foreign API. An API is serving,
    # which is the job — stand down instead of fighting it.
    if ! port_free 9600 && curl -fsS --max-time 2 "http://localhost:9600/api/v1/health" >/dev/null 2>&1; then
      warn "a healthy API this session does not own is on :9600 — api watchdog standing down ('make restart' to reclaim)"
      return 0
    fi
    if [ "$healthy_once" = "0" ]; then boot_failures=$((boot_failures + 1)); else boot_failures=0; fi
    if [ "$boot_failures" -ge 3 ]; then
      bad "api failed to become healthy $boot_failures starts in a row — giving up. See $LOGDIR/api.log"
      return 1
    fi
    if ! contracts_built; then
      warn "api down with stale/incomplete contract dist — rebuilding before restart"
      (cd "$APEX" && pnpm --filter @storagely/rental-contract build \
                  && pnpm --filter @storagely/workflow-contract build) \
        || warn "contract rebuild failed — restarting api anyway"
    fi
    warn "restarting api (crash evidence kept in $LOGDIR/api.log)"
    sleep 2
    [ -f "$STOP_SENTINEL" ] && return 0
  done
}

head1 "Starting Helix workspace"
say "logs: $LOGDIR"
say "bind: $HELIX_HOST  ($HELIX_HOST_REASON)"

# --- API first, then gate on health -----------------------------------------
: > "$LOGDIR/api.log"
api_supervisor &
CHILD_PIDS+=("$!")
STARTED_PORTS+=("api|9600")
say ""
say "waiting for api health on :9600 ..."
if wait_for_api 90; then
  ok "api ready (GET /api/v1/health)"
else
  bad "api did not become healthy in 90s — see $LOGDIR/api.log"
  exit 1
fi

# --- everything else ---------------------------------------------------------
for svc in "${SERVICES[@]:1}"; do
  IFS='|' read -r n p d c <<< "$svc"
  start_service "$n" "$p" "$d" "$c"
  # `webpage`'s dev script forks TWO servers (packages/webpage/package.json:
  # `vite --port 9701 & tsx dev-ssr.ts & wait`, the latter on :9702), but
  # start_service registers only the port it was handed. Without this, Ctrl-C
  # swept :9701 and left dev-ssr orphaned on :9702 — and dev-ssr.ts's
  # server.listen() has no EADDRINUSE handler, so the NEXT start crashed it.
  # down.sh already special-cases 9702; this makes Ctrl-C match `make down`.
  [ "$n" = "webpage" ] && STARTED_PORTS+=("dev-ssr|9702")
done

for svc in "${SERVICES[@]:1}"; do
  IFS='|' read -r n p d c <<< "$svc"
  wait_for_port "$p" 90 && ok "$(printf '%-9s :%s' "$n" "$p")" || warn "$(printf '%-9s :%s never bound' "$n" "$p")"
done

if [ "$FULL" = "1" ]; then
  wait_for_port 9702 90 && ok "$(printf '%-9s :%s' "dev-ssr" "9702")" \
    || warn "$(printf '%-9s :%s never bound' "dev-ssr" "9702")"
fi

EXTRA_BANNER=""
if [ "$FULL" = "1" ]; then
  EXTRA_BANNER="    editor     http://localhost:9700   <- what the platform /helix route iframes
    webpage    http://localhost:9701   (the editor canvas renderer)
    dev SSR    http://localhost:9702   (published-site render path)"
else
  EXTRA_BANNER="    editor/webpage NOT started (core-only). The platform /helix route will
    show a connection error until you restart with: make dev"
fi

cat <<BANNER

$C_BOLD  Helix workspace up$C_RESET
    platform   http://localhost:9720   <- use localhost, not the WSL IP:
                                        Atlas only accepts localhost:9720 as parent
    atlas      http://localhost:9730   (top-window = synthetic preview user)
    api        http://localhost:9600/api/v1/health
$EXTRA_BANNER

  Sign in at :9720, then open the Atlas surface for the local account:
    /users/<userId>/accounts/account_FDL4h_6DC5C8Ftp/atlas/website_g_cNyzHQqzPXKsB

  Verify the embed is local: DevTools Network should show the handshake verify as
    GET http://localhost:9600/api/v1/users/<userId>

  Ctrl-C stops everything gracefully.

BANNER

wait
