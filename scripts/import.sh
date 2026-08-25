#!/usr/bin/env bash
# Wrapper around apex-app's existing import-operator-data plugin.
#
# The plugin script itself is TRACKED, so we do not modify it. This wrapper adds
# the two things it has no reason to know about:
#   1. The CLI talks to the RUNNING local API over HTTP for EVERY subcommand
#      (dev-import.mjs's own header: PGlite is single-writer, so a script that
#      opened the DB while the dev server was up would corrupt it — hence HTTP).
#      So the API must be UP; we start it if it isn't.
#      (A previous version of this wrapper had it backwards and STOPPED the API
#      before 'import', which guaranteed the CLI died with "Cannot reach the
#      local API". Do not reintroduce that.)
#   2. The Atlas-side checks for this workspace (:9730 up, embed wired).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLUGIN="$APEX/tools/claude-plugins/plugins/import-operator-data/skills/import-operator-data/scripts/dev-import.mjs"
[ -f "$PLUGIN" ] || { bad "import plugin not found at $PLUGIN"; exit 1; }

CMD="${1:-}"; shift || true

if [ -z "$CMD" ] || [ "$CMD" = "help" ]; then
  cat <<USAGE

  make import CMD='<subcommand> [args]'

  Passed straight through to the existing plugin:
    preflight                      check env, API, gate, local login
    resolve   <operator name>      name -> opaque token
    inventory <token>              what's importable
    import    <token> <req.json>   run an import (async job — poll with status)
    status    <jobId>              poll a run
    remove    <websiteId>          tear down an import

  Every subcommand talks to the RUNNING local API on :9600 over HTTP. If the
  API is down this wrapper starts it and leaves it running (import jobs execute
  inside the API process — stopping it would kill them). Stop later with
  'make down'.

USAGE
  exit 0
fi

head1 "Atlas-side checks"
if port_free 9730; then warn "atlas not running on :9730 (fine for import, needed to view the result)"; else ok "atlas up on :9730"; fi
grep -qE '^[[:space:]]*VITE_ATLAS_IFRAME_URL=' "$APEX/packages/platform/.env.local" 2>/dev/null \
  && ok "embed wired" || warn "embed not wired — run 'make wire'"

if port_free 9600; then
  # A running dev.sh has a health watchdog that recovers the API on its own —
  # starting a second one here would race it (both children fight over :9600
  # via assertPortAvailable and the loser leaves an orphaned tsx supervisor).
  # Defer to the watchdog when a dev session is live; start our own only when
  # nothing else will.
  DEV_PID="$(pgrep -f "scripts/dev.sh" 2>/dev/null | while read -r p; do pid_in_workspace "$p" && echo "$p" && break; done)"
  if [ -n "${DEV_PID:-}" ]; then
    head1 "API down but 'make dev' is running — waiting for its watchdog to recover it"
    if wait_for_api 90; then
      ok "api recovered by the dev session's watchdog"
    else
      bad "api did not come back in 90s — see $LOGDIR/api.log (and 'make status')"
      exit 1
    fi
  else
    head1 "Starting API (the import CLI talks to it over HTTP)"
    # Append, never truncate: api.log may hold the crash evidence explaining WHY
    # the API is down right now.
    (cd "$APEX" && nohup pnpm dev:api >> "$LOGDIR/api.log" 2>&1 &)
    if wait_for_api 90; then
      ok "api up on :9600 — left running afterwards (import jobs run inside it; 'make down' stops it)"
    else
      bad "api did not become healthy in 90s — see $LOGDIR/api.log"
      exit 1
    fi
  fi
else
  ok "api already up on :9600"
fi

head1 "Running: dev-import.mjs $CMD"
(cd "$APEX" && STORAGELY_LOCAL_API="${STORAGELY_LOCAL_API:-http://localhost:9600}" node "$PLUGIN" "$CMD" "$@")
exit $?
