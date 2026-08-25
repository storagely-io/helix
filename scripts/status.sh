#!/usr/bin/env bash
# What's listening, and which pid holds it.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

printf '\n%s%-10s %-6s %-8s %s%s\n' "$C_BOLD" "SERVICE" "PORT" "PID" "STATE" "$C_RESET"
row() {
  local name="$1" port="$2" pids
  pids="$(pids_on_port "$port" | tr '\n' ' ')"
  if [ -n "$pids" ]; then
    printf '%-10s %-6s %-8s %sup%s\n' "$name" "$port" "${pids% }" "$C_GREEN" "$C_RESET"
  else
    printf '%-10s %-6s %-8s %sdown%s\n' "$name" "$port" "-" "$C_DIM" "$C_RESET"
  fi
}
for svc in "${CORE_SERVICES[@]}" "${EXTRA_SERVICES[@]}"; do
  IFS='|' read -r name port dir cmd <<< "$svc"
  row "$name" "$port"
done
row "dev-ssr" 9702

echo
if curl -fsS --max-time 2 http://localhost:9600/api/v1/health 2>/dev/null | head -c 400; then echo
else printf '%sapi health: unreachable%s\n' "$C_DIM" "$C_RESET"; fi

# Embed readiness. The failure this catches: `pnpm dev` (from apex-app) brings up
# every Helix service and looks healthy, but knows nothing about the Atlas repo —
# so :9730 is down and the embedded page is broken with no obvious cause.
printf '\n%sAtlas data (Supabase)%s\n' "$C_BOLD" "$C_RESET"
# Separate lifecycle from `make dev` on purpose: the local stack is its own set of
# containers, so `make down` deliberately leaves it running.
if curl -fsS --max-time 3 "http://127.0.0.1:54321/rest/v1/" -o /dev/null 2>/dev/null; then
  ok "local stack up (127.0.0.1:54321) — make supabase-down to stop it"
  if [ -n "${SUPABASE_URL:-}" ] && printf '%s' "$SUPABASE_URL" | grep -qE '127\.0\.0\.1|localhost'; then
    ok "Atlas points at the LOCAL stack — production Atlas data is untouched"
  else
    warn "stack is up but SUPABASE_URL is not local (make supabase-wire)"
  fi
  # The count that actually matters. A location row is invisible to every list in
  # the app unless it carries fields.helix_tags (or atlas_origin=import) AND its
  # company has platform_website_id set -- both of which only the page-catalog
  # sync writes. Rows can exist and still show "Select a location" everywhere.
  _listable="$(docker exec -i supabase_db_supabase-local psql -U postgres -d postgres -qAt -c \
    "SELECT count(*) FROM atlas_locations l JOIN atlas_companies c ON c.id = l.company_id
      WHERE l.deleted_at IS NULL AND c.platform_website_id IS NOT NULL
        AND (l.fields @> '{\"helix_tags\":[\"page/location\"]}'::jsonb
             OR l.fields->>'atlas_origin' = 'import');" 2>/dev/null | tr -d '[:space:]')"
  if [ "${_listable:-0}" -gt 0 ] 2>/dev/null; then
    ok "$_listable location(s) visible to the app's locations lists"
  else
    warn "0 locations visible to the app — run 'make sync-atlas'"
    say "     Rows may still exist: the lists filter on fields.helix_tags, which only"
    say "     the page-catalog sync writes. Untagged rows are silently invisible."
  fi
else
  warn "local Supabase not running (make supabase-up) — Atlas will report UNKNOWN_ACCOUNT"
fi

printf '\n%sAtlas embed%s\n' "$C_BOLD" "$C_RESET"
EMBED_OK=1
port_free 9720 && { bad "platform :9720 down — nothing to embed into"; EMBED_OK=0; }
if port_free 9730; then
  bad "atlas :9730 down — the embed will render Atlas's unauthenticated shell"
  say "     'pnpm dev' does NOT start Atlas (different repo). Use 'make dev' from"
  say "     $HELIX_ROOT instead."
  EMBED_OK=0
fi
port_free 9600 && { bad "api :9600 down — the handshake verify will fail"; EMBED_OK=0; }
grep -qE '^[[:space:]]*VITE_ATLAS_IFRAME_URL=' "$APEX/packages/platform/.env.local" 2>/dev/null \
  || { bad "embed not wired (make wire)"; EMBED_OK=0; }
[ "$EMBED_OK" = "1" ] && ok "ready — browse http://localhost:9720 (localhost only: Atlas rejects other parent origins)"

printf '\n%sgit (never commit from the workspace root)%s\n' "$C_BOLD" "$C_RESET"
for r in apex-app atlas; do
  printf '  %-10s %-34s %s\n' "$r" \
    "$(git -C "$HELIX_ROOT/$r" config --get remote.origin.url 2>/dev/null | sed -E 's#//[^@/]*@#//#')" \
    "$(git -C "$HELIX_ROOT/$r" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  d="$(git -C "$HELIX_ROOT/$r" status --porcelain 2>/dev/null | wc -l)"
  [ "$d" -gt 0 ] && printf '             %s%s uncommitted change(s)%s\n' "$C_YELLOW" "$d" "$C_RESET" || true
done
echo
