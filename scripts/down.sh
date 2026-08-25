#!/usr/bin/env bash
# Graceful teardown of every workspace service.
#
# SIGTERM, one pid at a time, then verify the port actually freed.
# DO NOT "optimise" this into `kill -9` or `pkill -f node`: the Helix API runs
# PGlite as a single-writer embedded database. A hard kill skips
# deactivateServices() and can leave the dev database corrupt — which shows up
# later as a 500 on login, not as an obvious crash.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

head1 "Stopping Helix workspace"
# Tell a live dev.sh API supervisor this stop is deliberate BEFORE freeing the
# port, or it restarts the API right after we stop it. dev.sh clears the file
# on its next startup.
mkdir -p "$LOGDIR"; touch "$STOP_SENTINEL"
RC=0
# Reverse order: dependents before the API they talk to.
for svc in "${EXTRA_SERVICES[@]}" "${CORE_SERVICES[@]}"; do
  IFS='|' read -r name port dir cmd <<< "$svc"
  stop_port "$port" "$name" || RC=1
done
# The webpage package also runs a dev SSR server on 9702 (not 9710 — that's prod).
stop_port 9702 "dev-ssr" || RC=1

# Ports are free; now remove the watchers that would respawn onto them.
head1 "Sweeping supervisors"
sweep_supervisors

echo
[ "$RC" -eq 0 ] && ok "all services stopped" || warn "some ports still bound — 'make status' to inspect"
exit "$RC"
