#!/usr/bin/env bash
# Populate Atlas's local data the way PRODUCTION does, rather than by hand.
#
# Supersedes scripts/seed-atlas-locations.py (moved to scripts/_superseded/).
# That script wrote atlas_locations rows straight from Helix's page manifest,
# which got the *rows* roughly right and the *fields* wrong in the one way that
# matters: listAtlasLocations only returns rows matching
#
#     fields.cs.{"helix_tags":["page/location"]}  OR  fields->>atlas_origin = 'import'
#
# so hand-seeded rows (fields = {}) were invisible to every locations list in the
# app — including the one the Checkout Settings header reads to name the facility,
# which is why it said "Select a location" under a selected location. It also
# created rows for Helix pages that are not location pages at all.
#
# So: run the real thing. POST the hourly cron endpoint Atlas ships
# (src/routes/api/public/hooks/sync-helix-location-pages.ts), which
#   1. enumerates atlas_companies with a connected Helix accountId,
#   2. asks Helix (signed, HMAC) for that account's websites,
#   3. asks Helix for each website's page catalog, and
#   4. reconciles into atlas_locations — matching on platform_location_id, so
#      existing rows are adopted/refreshed rather than duplicated,
#   5. caching the first websiteId onto atlas_companies.platform_website_id
#      (which the locations list requires via its inner join).
#
# Requires, all from helix/.env.local: CRON_SECRET (authorises the hook) and the
# HELIX_PUBLIC_SECRET_KEY / PUBLIC_SECRET_KEY pair (one value, two names — the
# outbound HMAC to Helix). Missing either is not an error you'll see as a crash:
# the surfaces go dormant instead.
set -euo pipefail
HELIX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HELIX_ROOT/scripts/lib.sh"

ATLAS_URL="http://localhost:9730"
DB_CONTAINER="supabase_db_supabase-local"

if [ -z "${CRON_SECRET:-}" ]; then
  printf "  CRON_SECRET is not set in helix/.env.local — the sync hook 503s without it.\n"
  exit 1
fi
if [ -z "${HELIX_PUBLIC_SECRET_KEY:-}" ] || [ -z "${PUBLIC_SECRET_KEY:-}" ]; then
  printf "  HELIX_PUBLIC_SECRET_KEY / PUBLIC_SECRET_KEY missing — Helix would 503 the signed reads.\n"
  exit 1
fi
if [ "${HELIX_PUBLIC_SECRET_KEY:-}" != "${PUBLIC_SECRET_KEY:-}" ]; then
  printf "  HELIX_PUBLIC_SECRET_KEY != PUBLIC_SECRET_KEY. Prod uses ONE value for both\n"
  printf "  directions; a mismatch surfaces as 'Invalid signature', not as a config error.\n"
  exit 1
fi
if ! curl -fsS "$ATLAS_URL/" >/dev/null 2>&1; then
  printf "  atlas is not listening on :9730 — start it with 'make dev'.\n"
  exit 1
fi
# The hook's signed reads target Helix, and the post-sync steps write straight
# into the local Supabase db container. Both used to be assumed rather than
# checked, so a half-up stack died mid-script under set -e with no diagnosis.
if ! curl -fsS --max-time 3 "http://localhost:9600/api/v1/health" >/dev/null 2>&1; then
  printf "  the Helix API is not answering on :9600 — the hook's signed reads need it.\n"
  printf "  Start the stack with 'make dev'.\n"
  exit 1
fi
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$DB_CONTAINER"; then
  printf "  the local Supabase db container (%s) is not running.\n" "$DB_CONTAINER"
  printf "  Start it with 'make supabase-up' (or 'make dev', which ensures it).\n"
  exit 1
fi

printf "\n  Reconciling Helix page catalog -> atlas_locations (the hourly cron path)\n"
body="$(curl -fsS -X POST -H "authorization: Bearer $CRON_SECRET" \
  "$ATLAS_URL/api/public/hooks/sync-helix-location-pages")" || {
  printf "  sync hook failed\n"; exit 1; }

printf '%s' "$body" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for r in d.get("results", []):
    tag = "ok " if r.get("ok") else "FAIL"
    c = r.get("counts") or {}
    detail = ", ".join(f"{k}={v}" for k, v in c.items()) if c else (r.get("error") or "")
    acct = r.get("accountId")
    site = r.get("websiteId") or "(no website)"
    print("    %s %s  %s  %s" % (tag, acct, site, detail))
print("    %s account(s), %s attempt(s)" % (d.get("accounts"), d.get("attempts")))
'

# The reconcile deliberately does NOT set fields.fms_location: that binding is
# the operator's pick (FmsSoftwarePage / LocationDetail / the bulk-id CSV), not
# something Helix owns. But edge-settings reads the FMS location code from
# fields.fms_location ONLY, while the locations list falls back to
# helix_page_location_code -- so without this step the switcher shows a code and
# Checkout Settings reports "no FMS location code assigned".
#
# Do locally what the operator did in prod, using the code Helix already bound to
# the page, and record it with the same provenance the FMS-feed path uses
# (sources.fms_location = 'fms', per atlas-import.functions.ts). Idempotent:
# never overwrites a code already on file.
printf "\n  Binding fields.fms_location from helix_page_location_code (the operator step)\n"
docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q -v ON_ERROR_STOP=1 <<'SQL'
UPDATE atlas_locations
   SET fields  = coalesce(fields, '{}'::jsonb)  || jsonb_build_object('fms_location', helix_page_location_code),
       sources = coalesce(sources, '{}'::jsonb) || jsonb_build_object('fms_location', 'fms')
 WHERE helix_page_location_code IS NOT NULL
   AND btrim(helix_page_location_code) <> ''
   AND coalesce(fields->>'fms_location', '') = '';
SQL

docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -qAt -F '  ' <<'SQL'
SELECT '    ' || l.slug
       || '  tags=' || coalesce(l.fields->'helix_tags', 'null')::text
       || '  fms_location=' || coalesce(nullif(l.fields->>'fms_location', ''), '(unset)')
  FROM atlas_locations l
  JOIN atlas_companies c ON c.id = l.company_id
 WHERE l.deleted_at IS NULL
   AND c.platform_website_id IS NOT NULL
 ORDER BY l.slug;
SQL

printf "\n  Locations with no fms_location have no FMS code on their Helix page either;\n"
printf "  Checkout Settings for those is correctly empty, not broken.\n\n"
