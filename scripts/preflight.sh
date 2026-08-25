#!/usr/bin/env bash
# Non-mutating prerequisite check. Changes nothing; exits non-zero if `make dev`
# would fail. `make doctor` is exactly this.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FAILED=0
# dev.sh passes --ports-fatal: both :9720 and :9730 are --strictPort, so a
# collision genuinely blocks startup. Bare `make doctor` only warns, so that
# "already running" doesn't read as a broken workspace.
PORTS_FATAL=0
[ "${1:-}" = "--ports-fatal" ] && PORTS_FATAL=1
WORKSPACE_CONFLICT=0
FOREIGN_CONFLICT=0

# Full is the default (see dev.sh), so doctor checks the full set unless asked
# otherwise. 9702 is dev-ssr, forked by webpage's dev script — it is NOT
# --strictPort and its server.listen() has no EADDRINUSE handler, so an orphan
# there crashes the start instead of reporting a conflict. Check it up front.
WANT_PORTS=("9600" "9720" "9730")
[ "${HELIX_FULL:-1}" = "1" ] && WANT_PORTS+=("9700" "9701" "9702")

head1 "Toolchain"
for c in node pnpm; do
  if command -v "$c" >/dev/null 2>&1; then ok "$(printf '%-8s %s' "$c" "$($c --version 2>/dev/null | head -1)")"
  else bad "$c missing"; FAILED=1; fi
done
if command -v bun >/dev/null 2>&1; then
  ok "$(printf '%-8s %s' bun "$(bun --version 2>/dev/null)")"
else
  bad "bun missing — Atlas needs it (run: make install)"
  say "     Atlas's only lockfile is bun.lock, and neither package-lock.json nor"
  say "     pnpm-lock.yaml is gitignored there — npm/pnpm would add a TRACKED file."
  FAILED=1
fi

head1 "Dependencies"
[ -d "$APEX/node_modules" ] && ok "apex-app/node_modules" || { bad "apex-app/node_modules missing (make install)"; FAILED=1; }
[ -d "$ATLAS/node_modules" ] && ok "atlas/node_modules" || { bad "atlas/node_modules missing (make install)"; FAILED=1; }

head1 "Competing orchestrators"
PNPM_DEV="$(pnpm_dev_pids | tr '\n' ' ')"
if [ -n "${PNPM_DEV// /}" ]; then
  bad "a competing dev orchestrator is running (pids: $PNPM_DEV)"
  say "     Either root 'pnpm dev', or its contract tsc -w watchers."
  say "     It starts tsc -w watchers that rewrite the contract packages' dist/,"
  say "     which kills the API mid-rebuild (ERR_MODULE_NOT_FOUND) — and it starts"
  say "     a second API contending for single-writer PGlite."
  say "     Run ONE orchestrator. Stop it, then use 'make dev' (it also starts Atlas,"
  say "     which 'pnpm dev' cannot)."
  FAILED=1
else
  ok "no competing 'pnpm dev'"
fi

head1 "Contract packages"
if contracts_built; then
  ok "rental-contract + workflow-contract dist present"
else
  warn "contract dist incomplete — 'make dev' will rebuild before starting"
fi

head1 "Ports"
for p in "${WANT_PORTS[@]}"; do
  if port_free "$p"; then
    ok "$(printf ':%-5s free' "$p")"
  else
    # 9720 and 9730 are --strictPort: a collision is fatal, not a fallback.
    if [ "$PORTS_FATAL" = "1" ]; then
      if port_held_by_workspace "$p"; then
        bad "$(printf ':%-5s held by a workspace service already running (pid %s)' "$p" "$(pids_on_port "$p" | tr '\n' ' ')")"
        WORKSPACE_CONFLICT=1
      else
        bad "$(printf ':%-5s held by a process OUTSIDE this workspace (pid %s)' "$p" "$(pids_on_port "$p" | tr '\n' ' ')")"
        say "     $(ps -o args= -p "$(pids_on_port "$p" | head -1)" 2>/dev/null | cut -c1-80)"
        say "     Not ours to stop — investigate before freeing :$p."
        FOREIGN_CONFLICT=1
      fi
      FAILED=1
    else
      warn "$(printf ':%-5s already in use by pid %s (a running service?)' "$p" "$(pids_on_port "$p" | tr '\n' ' ')")"
    fi
  fi
done

head1 "Embed wiring"
ENVLOCAL="$APEX/packages/platform/.env.local"
if [ -f "$ENVLOCAL" ] && grep -qE '^[[:space:]]*VITE_ATLAS_IFRAME_URL=' "$ENVLOCAL"; then
  ok "VITE_ATLAS_IFRAME_URL set -> $(grep -E '^[[:space:]]*VITE_ATLAS_IFRAME_URL=' "$ENVLOCAL" | head -1 | cut -d= -f2-)"
else
  bad "VITE_ATLAS_IFRAME_URL not set in packages/platform/.env.local"
  say "     Without it the platform iframes PRODUCTION Atlas (atlas.apps.storagely.io)."
  FAILED=1
fi
if grep -qE '^[[:space:]]*VITE_API_BASE_URL=' "$ENVLOCAL" 2>/dev/null; then
  warn "VITE_API_BASE_URL is set — the platform will bypass the local API"
  say "     Comment it out unless you deliberately want prod data."
fi

head1 "Helix API config"
APIENV="$APEX/packages/api/.env"
if grep -qE '^STORAGELY_ALLOW_IMPORT=true' "$APIENV" 2>/dev/null; then ok "STORAGELY_ALLOW_IMPORT=true (import enabled)"
else warn "STORAGELY_ALLOW_IMPORT not true — import routes compile out"; fi

head1 "Atlas -> Helix (server side)"
ok "HELIX_BASE_URL=$HELIX_API will be exported to the Atlas process"
say "     Without it Atlas's server verifies local tokens against production"
say "     Helix and every call fails with 'session verify rejected (401)'."

head1 "Atlas -> Supabase (server side)"
if [ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
  ok "SUPABASE_SERVICE_ROLE_KEY present (${#SUPABASE_SERVICE_ROLE_KEY} chars)"
else
  bad "SUPABASE_SERVICE_ROLE_KEY not set — Atlas's server cannot read its own data"
  say "     Every company/location/FAQ/photo read fails, account resolution returns"
  say "     UNKNOWN_ACCOUNT, and nothing provisions. atlas/.env carries only the"
  say "     PUBLISHABLE (anon) key; the server client needs the service-role key."
  say "     Put it in $HELIX_ROOT/.env.local (untracked):"
  say "        SUPABASE_SERVICE_ROLE_KEY=..."
  say "     NOTE: that key BYPASSES RLS. Against the shared hosted project it grants"
  say "     full read/write on production Atlas data — prefer a local Supabase."
fi

head1 "Atlas <-> Helix signed surface (HMAC)"
if [ -z "${PUBLIC_SECRET_KEY:-}" ] || [ -z "${HELIX_PUBLIC_SECRET_KEY:-}" ]; then
  bad "the shared HMAC key is not set — every signed surface is DORMANT"
  say "     One value, two names: Helix reads it as PUBLIC_SECRET_KEY, Atlas signs"
  say "     with it as HELIX_PUBLIC_SECRET_KEY. Unset does not crash anything, which"
  say "     is what makes it hard to spot: Helix 503s the route and Atlas renders"
  say "     'Atlas signing secret is not configured on this environment.'"
  say "     Set BOTH to one throwaway value in $HELIX_ROOT/.env.local (never the prod key)."
elif [ "$PUBLIC_SECRET_KEY" != "$HELIX_PUBLIC_SECRET_KEY" ]; then
  bad "PUBLIC_SECRET_KEY != HELIX_PUBLIC_SECRET_KEY — signed reads will 401"
  say "     Prod uses ONE value for both directions. A mismatch surfaces as"
  say "     'Invalid signature', which reads like a bug rather than a config split."
else
  ok "shared HMAC key set on both sides (${#PUBLIC_SECRET_KEY} chars, matching)"
fi
if [ -n "${CRON_SECRET:-}" ]; then
  ok "CRON_SECRET set — 'make sync-atlas' can drive the page-catalog sync"
else
  warn "CRON_SECRET not set — 'make sync-atlas' will 503"
  say "     It authorises Atlas's own hourly sync hook and is deliberately NOT the"
  say "     HMAC key above. Without a sync, atlas_locations rows carry no"
  say "     fields.helix_tags, so every locations list in the app comes back empty."
fi

head1 "Atlas data target"
# Judge this by the SERVER target (SUPABASE_URL), because that is the client that
# actually reads and writes -- and match a private/loopback host rather than
# literally "localhost": under WSL the browser half is wired to the LAN IP (the
# iframe is served from it), so a localhost-only test called a local stack
# "hosted" and warned about writing to production when it was not.
_is_local_host() {
  case "${1:-}" in
    *127.0.0.1*|*localhost*|*://10.*|*://192.168.*|*://172.1[6-9].*|*://172.2[0-9].*|*://172.3[01].*) return 0 ;;
    *) return 1 ;;
  esac
}
if _is_local_host "${SUPABASE_URL:-}"; then
  # Probe the target, don't just parse it: a well-shaped URL with no stack
  # behind it fails every Atlas read as 'fetch failed' / UNKNOWN_ACCOUNT, and
  # this check used to bless exactly that state with "ok Supabase: LOCAL".
  if curl -fsS --max-time 3 "${SUPABASE_URL}/rest/v1/" -o /dev/null 2>/dev/null; then
    ok "Supabase: LOCAL and answering (server target ${SUPABASE_URL})"
  else
    warn "Supabase: LOCAL target ${SUPABASE_URL} is NOT answering"
    say "     Atlas would boot fine and then fail every read (UNKNOWN_ACCOUNT /"
    say "     'TypeError: fetch failed'). 'make dev' starts the stack automatically;"
    say "     standalone: make supabase-up"
  fi
  if [ -f "$ATLAS/.env.local" ] && grep -qE '^[[:space:]]*VITE_SUPABASE_URL=' "$ATLAS/.env.local"; then
    _vite="$(awk -F= '/^[[:space:]]*VITE_SUPABASE_URL=/{print $2; exit}' "$ATLAS/.env.local")"
    if _is_local_host "$_vite"; then ok "Supabase: LOCAL for the browser too ($_vite)"
    else bad "browser VITE_SUPABASE_URL is NOT local ($_vite) — the page would read the hosted project"; fi
  else
    warn "no VITE_SUPABASE_URL in atlas/.env.local — browser-side reads fall back to atlas/.env (hosted)"
    say "     Run 'make supabase-wire'."
  fi
else
  warn "Supabase: HOSTED shared project — Atlas reads AND WRITES it"
  say "     ensureAtlasCompanyForAccount() provisions atlas_companies rows on an"
  say "     unknown accountId, so browsing local Helix accounts writes to the DB"
  say "     production uses. See 'make supabase-help'."
fi

echo
if [ "$WORKSPACE_CONFLICT" = "1" ]; then
  warn "a previous run of this workspace is still up"
  say "     make restart    stop it and start fresh"
  say "     make down       just stop it"
  say "     make status     see what's running"
fi
if [ "$FAILED" -eq 0 ]; then ok "preflight passed"; else bad "preflight failed — fix the above, then re-run 'make doctor'"; fi
exit "$FAILED"
