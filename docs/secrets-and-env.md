# Secrets and environment delivery

The recurring failure here is not choosing a wrong value — it is putting a right value somewhere
the process never reads. There are **three destinations with three different audiences**, and
they are easy to mistake for one another.

## The three destinations

| File | Reaches | Do not expect it to |
|---|---|---|
| `helix/.env.local` | `process.env` of **every** service `make dev` starts (`scripts/lib.sh` sources it under `set -a`) | — |
| `atlas/.env.local` | the **browser**, and only `VITE_`-prefixed keys | reach `process.env`; Atlas's `*.server.ts` / `*.functions.ts` will not see it |
| `apex-app/packages/api/.env` | the API via `dotenv.config()` | override an existing `process.env` value — dotenv does not |

That last row is why `helix/.env.local` works for the API too: keys absent from
`packages/api/.env` are simply inherited from the exported environment.

**`atlas/.env` is TRACKED.** Never put a value there. It already contains `SUPABASE_*` and a
Maps browser key, which is its own open question — see [open-items.md](open-items.md).

The workspace root is not a git repo, so `helix/.env.local` is untracked by construction. Local
values here are throwaway; **never the production key.**

## The shared HMAC key — one value, two names

| Side | Name | Used by |
|---|---|---|
| Helix (verifies) | `PUBLIC_SECRET_KEY` | `withAtlasHmac` in `packages/api/app/services/atlas-pages/atlasPagesAuth.ts` |
| Atlas (signs) | `HELIX_PUBLIC_SECRET_KEY` | `readSecret()` in `atlas/src/lib/helix-location-pages.server.ts:243`, and ~10 other modules |

Production uses **one** value for both directions. Two failure modes, and neither announces
itself as a configuration problem:

- **Unset** → the surface goes **dormant**, not broken. Helix answers `503`; Atlas renders
  *"Atlas signing secret is not configured on this environment."* Nothing crashes, nothing is
  logged as an error.
- **Mismatched** → `Invalid signature`, which reads like a bug in the signing code rather than a
  split config.

`make doctor` checks presence *and* equality, precisely because the second case is the one that
sends you reading crypto.

`CRON_SECRET` is separate and Atlas-internal: it authorises only the sync hook. The Supabase
anon key is deliberately **not** accepted there (it ships in client bundles).

### The canonical scheme

```
signature = "sha256=" + hex(HMAC-SHA256(secret, "{unix_ts}.{METHOD}.{path_with_query}"))
headers:  X-Atlas-Timestamp: {unix_ts}     # ±300s skew
          X-Atlas-Signature: sha256=...
```

For body-bearing writes the raw body joins the canonical string
(`"{ts}.PATCH.{path}.{rawBody}"`). The path must be signed **exactly as sent** — any
re-encoding between signing and sending yields a 401.

### Signing a request by hand

The fastest way to prove where a failure is. This is how the checkout-settings chain was
verified end to end:

```bash
SECRET=$(grep '^PUBLIC_SECRET_KEY=' /var/www/Storagely/helix/.env.local | cut -d= -f2-)
PQ="/api/v1/accounts/account_FDL4h_6DC5C8Ftp/edge-settings?apiPath=storagelyselfstorage&locationCode=<code>"
TS=$(date +%s)
SIG=$(printf '%s.GET.%s' "$TS" "$PQ" | openssl dgst -sha256 -hmac "$SECRET" -hex | sed 's/.*= //')
curl -s -H "X-Atlas-Timestamp: $TS" -H "X-Atlas-Signature: sha256=$SIG" "http://localhost:9600$PQ"
```

Signed endpoints this workspace depends on, all on `:9600`:

```
GET /api/v1/accounts/{accountId}/websites
GET /api/v1/accounts/{accountId}/websites/{websiteId}/atlas/pages       # page catalog
GET /api/v1/accounts/{accountId}/websites/{websiteId}/atlas/locations   # FMS feed + apiPath
GET /api/v1/accounts/{accountId}/edge-settings?apiPath=…&locationCode=…
```

## `SUPABASE_SERVICE_ROLE_KEY` — handle with care

Atlas's server client (`atlas/src/integrations/supabase/client.server.ts`) requires
`SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY`, and **that key bypasses RLS**. Pointed at the
hosted project it is full read/write on production Atlas data — and worse, Atlas *writes*
unprompted: `ensureAtlasCompanyForAccount` provisions an `atlas_companies` row for an unknown
accountId, so merely browsing local Helix accounts against the hosted project would create junk
rows in the database production reads.

That is the reason the local Supabase stack exists, not merely convenience. See
[local-supabase.md](local-supabase.md).

`atlas/.env` carries only the **publishable (anon)** key; the server needs the service-role key,
which is why the two are not interchangeable.

## Where this does *not* apply

This is local-development plumbing. Product credentials follow the platform's own doctrine —
`apex-app/docs/credentials.md`, summarised in `apex-app/CLAUDE.md`. In particular: a platform
secret's production home is **AWS Secrets Manager** delivered at deploy time by
`scripts/merge-secrets.mjs`; a `.env` edit is never "in AWS Secrets". Nothing in this workspace
changes that, and nothing here should be cited as precedent for it.
