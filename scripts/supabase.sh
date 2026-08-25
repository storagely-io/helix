#!/usr/bin/env bash
# Atlas data-target helper: status, and up/down for a LOCAL Supabase stack.
#
# Why local matters here: Atlas's server client uses the SERVICE ROLE key, which
# bypasses RLS. Against the shared hosted project that is full read/write on
# production Atlas data — and ensureAtlasCompanyForAccount() actively INSERTS a
# company row for any unknown accountId, so simply browsing a local Helix account
# would write to production. Against a local stack, that same provisioning is
# exactly what you want.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION="${1:-status}"
LOCAL_API="http://127.0.0.1:54321"
# The local stack lives in an untracked project dir with COPIES of Atlas's
# migrations, so nothing here can touch atlas/supabase/. See supabase-apply.sh
# for why the migrations cannot be applied atomically.
PROJ="$HELIX_ROOT/.supabase-local"

have_cli() { command -v supabase >/dev/null 2>&1; }

case "$ACTION" in
  up)
    have_cli || { bad "supabase CLI not installed"; exit 1; }
    docker info >/dev/null 2>&1 || { bad "Docker daemon unreachable — start Docker Desktop / dockerd first"; exit 1; }
    # Idempotent: already answering means already up — nothing to do.
    if curl -fsS --max-time 3 "$LOCAL_API/rest/v1/" -o /dev/null 2>/dev/null; then
      ok "local Supabase already up ($LOCAL_API)"
      exit 0
    fi
    head1 "Starting local Supabase (.supabase-local/)"
    say "First run pulls several GB of Docker images."
    # The stack belongs to the UNTRACKED project dir (project_id supabase-local),
    # NOT atlas/ — atlas/supabase/config.toml is a one-line project link with no
    # local-stack config, and starting from there would name different containers
    # than everything else here expects (supabase_db_supabase-local).
    (cd "$PROJ" && supabase start) || { bad "supabase start failed"; exit 1; }
    # Apply the schema only when it is actually missing: the db volume outlives
    # the containers, so a restart usually comes back with schema AND data. The
    # probe runs as postgres, which is fine for existence (grants are a separate
    # axis, checked through PostgREST by preflight/status).
    _has_schema="$(docker exec -i supabase_db_supabase-local psql -U postgres -d postgres -qAt \
      -c "select to_regclass('public.atlas_companies') is not null" 2>/dev/null | tr -d '[:space:]')"
    if [ "$_has_schema" = "t" ]; then
      ok "schema already present — skipping migration apply"
    else
      head1 "Applying migrations (per-file — see docs/local-supabase.md for why not db reset)"
      "$HELIX_ROOT/scripts/supabase-apply.sh" || { bad "migration apply failed"; exit 1; }
    fi
    "$HELIX_ROOT/scripts/supabase.sh" wire
    ;;
  down)
    have_cli || { bad "supabase CLI not installed"; exit 1; }
    (cd "$PROJ" && supabase stop) && ok "local Supabase stopped"
    ;;
  wire)
    have_cli || { bad "supabase CLI not installed"; exit 1; }
    ENVOUT="$(cd "$PROJ" && supabase status -o env 2>/dev/null)"
    KEY="$(printf '%s\n' "$ENVOUT" | grep -E '^SERVICE_ROLE_KEY=' | cut -d= -f2- | tr -d '"')"
    ANON="$(printf '%s\n' "$ENVOUT" | grep -E '^ANON_KEY=' | cut -d= -f2- | tr -d '"')"
    IP="$(ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)"
    BROWSER_URL="http://${IP:-127.0.0.1}:54321"
    [ -z "$KEY" ] && { bad "could not read the local service-role key (is the stack up?)"; exit 1; }
    ENVF="$HELIX_ROOT/.env.local"
    tmp="$(mktemp)"
    grep -vE '^[[:space:]]*(SUPABASE_URL|SUPABASE_SERVICE_ROLE_KEY)=' "$ENVF" 2>/dev/null > "$tmp" || true
    mv "$tmp" "$ENVF"; chmod 644 "$ENVF"
    {
      echo "SUPABASE_URL=$LOCAL_API"
      echo "SUPABASE_SERVICE_ROLE_KEY=$KEY"
    } >> "$ENVF"
    # The BROWSER half too, or it split-brains: Atlas's client code reads
    # VITE_SUPABASE_* from atlas/.env (tracked, pointing at the hosted project),
    # so without this the server would read local while the page read hosted.
    # These are VITE_-prefixed, so atlas/.env.local works for them — and it is
    # gitignored, unlike atlas/.env which must never hold a secret.
    # The browser gets the LAN IP for the same WSL reason as the Atlas iframe.
    AENV="$ATLAS/.env.local"
    tmp2="$(mktemp)"
    grep -vE '^[[:space:]]*(VITE_SUPABASE_URL|VITE_SUPABASE_PUBLISHABLE_KEY)=' "$AENV" 2>/dev/null > "$tmp2" || true
    mv "$tmp2" "$AENV"; chmod 644 "$AENV"
    {
      echo "# Local-only. atlas/.env is TRACKED — never put values there."
      echo "VITE_SUPABASE_URL=$BROWSER_URL"
      echo "VITE_SUPABASE_PUBLISHABLE_KEY=$ANON"
    } >> "$AENV"
    ok "wired local Supabase: server -> $LOCAL_API, browser -> $BROWSER_URL"
    warn "restart the workspace so Atlas picks it up: make restart"
    ;;
  status|*)
    head1 "Atlas data target"
    if [ -n "${SUPABASE_URL:-}" ] && printf '%s' "${SUPABASE_URL:-}" | grep -qE '127\.0\.0\.1|localhost'; then
      ok "LOCAL Supabase ($SUPABASE_URL)"
    else
      warn "HOSTED shared project — service-role writes hit PRODUCTION Atlas data"
    fi
    printf '  %-28s %s\n' "supabase CLI" "$(have_cli && supabase --version 2>/dev/null || echo MISSING)"
    printf '  %-28s %s\n' "docker" "$(command -v docker >/dev/null && (timeout 8 docker info --format '{{.ServerVersion}}' 2>/dev/null || echo 'installed, daemon unreachable') || echo MISSING)"
    printf '  %-28s %s\n' "local API reachable" "$(curl -fsS --max-time 3 "$LOCAL_API/rest/v1/" -o /dev/null 2>/dev/null && echo yes || echo no)"
    printf '  %-28s %s\n' "migrations" "$(ls "$ATLAS/supabase/migrations" 2>/dev/null | wc -l) files"
    printf '  %-28s %s\n' "seed file" "$(find "$ATLAS/supabase" -iname 'seed*' 2>/dev/null | grep -q . && echo present || echo 'none — a fresh DB starts empty')"
    cat <<'NOTES'

  make supabase-up     start the stack + apply all migrations + wire the key
  make supabase-down   stop it
  make supabase-wire   re-read the local service-role key into helix/.env.local

  Note: atlas/CLAUDE.md states the Supabase schema is Lovable-managed and must not
  be changed directly. Running these migrations LOCALLY does not touch the hosted
  project, but keep local schema changes out of atlas/supabase/migrations.

NOTES
    ;;
esac
