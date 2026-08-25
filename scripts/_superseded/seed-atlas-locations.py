#!/usr/bin/env python3
"""Seed Atlas's local atlas_locations from Helix's local location pages.

Why this is needed: Atlas resolves the shell's `?pageId=` by matching it against
its OWN atlas_locations.platform_location_id (see atlas.$company.index.tsx ->
rows.find(r => r.platformLocationId === pageId)). A fresh local Supabase has no
locations, so the match fails, the redirect to the Location Page never happens,
and the shell falls back to the Overview with the header reading "All locations".

Emits idempotent SQL on stdout; pipe into psql. Reads Helix's page manifest from
the local file-storage adapter, so it needs no running API.
"""
import json, re, sys, unicodedata
from pathlib import Path

LS = Path("/var/www/Storagely/helix/apex-app/packages/api/.local-storage/default")

def slugify(s: str) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode()
    s = re.sub(r"[^a-zA-Z0-9]+", "-", s).strip("-").lower()
    return s or "location"

def q(v):
    if v is None:
        return "NULL"
    return "'" + str(v).replace("'", "''") + "'"

def main(website_id: str, account_id: str):
    manifest = json.loads((LS / "websites" / website_id / "pages-manifest.json").read_text())
    pages = manifest if isinstance(manifest, list) else manifest.get("pages", [])
    locs = [p for p in pages if p.get("locationCode")]
    if not locs:
        print("-- no location pages found", file=sys.stderr); return 1

    print("BEGIN;")
    # Resolve the company Atlas already provisioned for this Helix account.
    print(f"""
DO $seed$
DECLARE cid uuid;
BEGIN
  SELECT id INTO cid FROM atlas_companies WHERE platform_account_id = {q(account_id)} LIMIT 1;
  IF cid IS NULL THEN
    RAISE EXCEPTION 'no atlas_companies row for %; load the Atlas surface once so it provisions, then re-run', {q(account_id)};
  END IF;
""")
    for p in locs:
        pid = p["id"]
        title = p.get("title") or pid
        # `slug_id` is a short per-company handle (existing rows use 6 chars);
        # derive it from the Helix page id so re-runs are stable.
        slug_id = re.sub(r"[^a-z0-9]", "", pid.lower())[-6:]
        parts = [x for x in (p.get("path") or "").split("/") if x]
        state = parts[2] if len(parts) > 2 else None
        city = parts[3] if len(parts) > 3 else None
        slug = f"{slugify(title)}-{slug_id}"
        print(f"""  INSERT INTO atlas_locations
    (company_id, name, slug, slug_id, city, state, platform_website_id, platform_location_id, helix_page_location_code)
  VALUES (cid, {q(title)}, {q(slug)}, {q(slug_id)}, {q(city)}, {q(state)}, {q(website_id)}, {q(pid)}, {q(p.get('locationCode'))})
  ON CONFLICT (company_id, platform_location_id) WHERE platform_location_id IS NOT NULL
  DO UPDATE SET name = EXCLUDED.name, city = EXCLUDED.city, state = EXCLUDED.state,
                platform_website_id = EXCLUDED.platform_website_id,
                helix_page_location_code = EXCLUDED.helix_page_location_code;""")
    print("END\n$seed$;")
    print("COMMIT;")
    print(f"-- seeded {len(locs)} location(s)", file=sys.stderr)
    return 0

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: seed-atlas-locations.py <websiteId> <accountId>", file=sys.stderr); sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
