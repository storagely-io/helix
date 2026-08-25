#!/usr/bin/env bash
# One-shot bootstrap for a FRESH machine: clone the two app repos, scaffold the
# untracked env files, install dependencies, stage the local Supabase project,
# and seed a local login. Idempotent — every step skips itself when its output
# already exists, so re-running after a partial failure is safe.
#
# The two app repos are NOT part of this workspace repo (see .gitignore): they
# are cloned side-by-side into apex-app/ and atlas/ by this script.
#
#   make setup     then     make dev
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Remote base override, e.g. HELIX_GIT_BASE=https://github.com/storagely-io
GIT_BASE="${HELIX_GIT_BASE:-git@github.com:storagely-io}"
APEX_REMOTE="$GIT_BASE/apex-app.git"
# ⚠ Atlas's repo name is NOT its directory name.
ATLAS_REMOTE="$GIT_BASE/storagely-home-base.git"

FAILED=0
rand_hex() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex "$1"
  else head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}

# --- toolchain ----------------------------------------------------------------
head1 "Toolchain"
for c in git node pnpm curl; do
  if command -v "$c" >/dev/null 2>&1; then ok "$(printf '%-9s %s' "$c" "$($c --version 2>/dev/null | head -1)")"
  else bad "$c missing — install it first"; FAILED=1; fi
done
# bun is installed by install.sh if absent; docker/supabase/tmux are needed at
# `make dev` time, not right now — warn so the gap is known before it bites.
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
  && ok "docker daemon reachable" \
  || warn "docker unreachable — needed for the local Supabase at 'make dev' time"
command -v supabase >/dev/null 2>&1 \
  && ok "supabase CLI $(supabase --version 2>/dev/null | head -1)" \
  || { warn "supabase CLI missing — needed at 'make dev' time"; \
       say "     https://supabase.com/docs/guides/local-development/cli/getting-started"; \
       say "     (a single binary in ~/.local/bin works; lib.sh puts it on PATH)"; }
command -v tmux >/dev/null 2>&1 || warn "tmux missing — 'make up' (detached mode) needs it; 'make dev' does not"
[ "$FAILED" = "1" ] && { echo; bad "fix the toolchain, then re-run 'make setup'"; exit 1; }

# --- clone the two app repos ----------------------------------------------------
head1 "App repos"
if [ -d "$APEX/.git" ]; then ok "apex-app/ already cloned"
else
  say "cloning $APEX_REMOTE -> apex-app/"
  git clone "$APEX_REMOTE" "$APEX" || { bad "clone failed — check repo access ($APEX_REMOTE)"; exit 1; }
fi
if [ -d "$ATLAS/.git" ]; then ok "atlas/ already cloned"
else
  say "cloning $ATLAS_REMOTE -> atlas/  (repo name differs from the directory on purpose)"
  git clone "$ATLAS_REMOTE" "$ATLAS" || { bad "clone failed — check repo access ($ATLAS_REMOTE)"; exit 1; }
fi

# --- the one secret that cannot be generated ------------------------------------
head1 "FontAwesome Pro registry token (apex-app/.npmrc)"
if [ -f "$APEX/.npmrc" ]; then
  ok ".npmrc present"
else
  say "  apex-app depends on @fortawesome/fontawesome-pro, so pnpm install needs the"
  say "  team's FontAwesome Pro token. Where to get it:"
  say "    - a teammate's apex-app/.npmrc (the line after _authToken=), or"
  say "    - fontawesome.com -> sign in with the team account -> Account -> Tokens"
  FA_TOKEN=""
  if [ -t 0 ]; then
    printf '  paste the token (input hidden; Enter to skip): '
    read -rs FA_TOKEN; echo
  fi
  if [ -n "$FA_TOKEN" ]; then
    printf '@fortawesome:registry=https://npm.fontawesome.com/\n//npm.fontawesome.com/:_authToken=%s\n' "$FA_TOKEN" > "$APEX/.npmrc"
    ok "wrote apex-app/.npmrc (gitignored in apex-app — never commit it)"
  else
    bad "no token — pnpm install WILL fail without it"
    say "     When you have it, either re-run 'make setup' and paste it, or:"
    say ""
    say "       cat > apex-app/.npmrc <<'NPMRC'"
    say "       @fortawesome:registry=https://npm.fontawesome.com/"
    say "       //npm.fontawesome.com/:_authToken=YOUR-TOKEN-HERE"
    say "       NPMRC"
    exit 1
  fi
fi

# --- scaffold the untracked env files --------------------------------------------
head1 "Env files"

ENVF="$HELIX_ROOT/.env.local"
if [ -f "$ENVF" ]; then
  ok ".env.local present"
else
  HMAC="$(rand_hex 32)"
  cat > "$ENVF" <<EOF
# Workspace-local values — gitignored, exported into every service 'make dev' starts.

# The shared Atlas<->Helix HMAC key. ONE value, two names: Helix reads it as
# PUBLIC_SECRET_KEY, Atlas signs with it as HELIX_PUBLIC_SECRET_KEY. This is a
# generated THROWAWAY for local dev — never the prod key.
PUBLIC_SECRET_KEY=$HMAC
HELIX_PUBLIC_SECRET_KEY=$HMAC

# Authorises Atlas's page-catalog sync hook ('make sync-atlas'). Deliberately
# NOT the HMAC key above.
CRON_SECRET=$(rand_hex 24)

# SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are written by 'make supabase-wire'
# (which 'make dev' runs for you when it starts the local stack).
EOF
  ok "generated .env.local (throwaway HMAC + CRON_SECRET)"
fi

APIENV="$APEX/packages/api/.env"
if [ -f "$APIENV" ]; then
  ok "packages/api/.env present"
else
  cat > "$APIENV" <<'EOF'
NODE_ENV=development
PORT=9600
LOG_LEVEL=info
# Schedules every job definition's cron (jobsService.activate gates on this).
PRIMARY_SERVER=true
LOCAL_STORAGE_ROOT=.local-storage
STORAGE_DEFAULT_BUCKET=default
STORAGELY_BASE_URL=http://localhost:3000
# Enables the local import routes ('/import', 'make import'). Never set in prod.
STORAGELY_ALLOW_IMPORT=true
# Read FMS artifacts from THIS API's own passthrough instead of prod CloudFront.
# Must mirror packages/webpage/.env's VITE_FMS_CDN_BASE_URL.
FMS_CDN_BASE_URL=http://localhost:9600/v4/fms/client_urls

# Optional third-party keys — features degrade gracefully without them:
#SCRAPINGDOG_API_KEY=
#FIRECRAWL_API_KEY=
#TOGETHER_API_KEY=
#GOOGLE_PLACES_API_KEY=
#STORAGE_API_KEY=
#STORAGE_API_SECRET=
#POSTMARK_API_KEY=
#TWILIO_AUTH_TOKEN=
EOF
  ok "scaffolded packages/api/.env (optional third-party keys left commented)"
fi

WEBENV="$APEX/packages/webpage/.env"
if [ -f "$WEBENV" ]; then
  ok "packages/webpage/.env present"
else
  cat > "$WEBENV" <<'EOF'
# Local dev only. Gitignored. Read by dev-ssr.ts via Vite loadEnv.

# hCaptcha's documented test sitekey — pairs with NO HCAPTCHA_SECRET on the API,
# so verification stands aside locally instead of rejecting test tokens.
HCAPTCHA_SITE_KEY=30000000-ffff-ffff-ffff-000000000003

# Read FMS artifacts from the LOCAL API passthrough — must mirror
# packages/api/.env's FMS_CDN_BASE_URL.
VITE_FMS_CDN_BASE_URL=http://localhost:9600/v4/fms/client_urls

# Optional; maps render as placeholders without it:
#GOOGLE_MAPS_BROWSER_KEY=
EOF
  ok "scaffolded packages/webpage/.env"
fi

ROOTENV="$APEX/.env"
if [ -f "$ROOTENV" ]; then
  ok "apex-app/.env present"
else
  cat > "$ROOTENV" <<'EOF'
# Import-tool credentials (gitignored). LOCAL_USER_API_* is filled in by 'make setup'.
# PROD_USER_API_* is only needed for '/import' (name->token resolution against prod):
#PROD_USER_API_EMAIL=
#PROD_USER_API_PASSWORD=
#SITEIMPORT_API_URL=
EOF
  ok "scaffolded apex-app/.env"
  # Optional, so offered rather than required: '/import' authenticates against
  # prod ONCE per run, read-only, purely to map an operator name to a source
  # token (see the import skill). Your own prod platform login is what goes here.
  if [ -t 0 ]; then
    say ""
    say "  Optional: '/import <operator>' needs your PROD platform login to resolve"
    say "  operator names. Skip now and add to apex-app/.env later if you prefer."
    printf '  prod email (Enter to skip): '
    read -r PROD_EMAIL
    if [ -n "$PROD_EMAIL" ]; then
      printf '  prod password (input hidden): '
      read -rs PROD_PASS; echo
      if [ -n "$PROD_PASS" ]; then
        { echo "PROD_USER_API_EMAIL=$PROD_EMAIL"; echo "PROD_USER_API_PASSWORD=$PROD_PASS"; } >> "$ROOTENV"
        ok "prod import credentials written to apex-app/.env (gitignored)"
      else
        warn "no password entered — skipped; add PROD_USER_API_* to apex-app/.env later"
      fi
    else
      say "  skipped — add PROD_USER_API_* to apex-app/.env when you want '/import'"
    fi
  fi
fi

# --- dependencies (pnpm, bun, atlas deps, embed wiring) ---------------------------
head1 "Dependencies"
"$HELIX_ROOT/scripts/install.sh" || { bad "install failed"; exit 1; }

# --- local Supabase project: copy Atlas's migrations ------------------------------
head1 "Local Supabase project (.supabase-local)"
mkdir -p "$HELIX_ROOT/.supabase-local/pending"
[ -f "$HELIX_ROOT/.supabase-local/pending/00000000000001_local_bootstrap.sql" ] \
  || { bad "the tracked bootstrap SQL is missing — is this a full clone of the workspace repo?"; exit 1; }
cp -f "$ATLAS/supabase/migrations/"*.sql "$HELIX_ROOT/.supabase-local/pending/" 2>/dev/null
ok "staged $(ls "$HELIX_ROOT/.supabase-local/pending/"*.sql | wc -l) SQL files (Atlas migrations + local bootstrap)"
say "     'make dev' applies them per-file on first start — see docs/local-supabase.md"

# --- seed a local login ------------------------------------------------------------
# A fresh PGlite has no usable credential (the auto-created admin@localhost.com
# carries forcePasswordReset). Boot the API once so it creates/migrates the DB,
# stop it (PGlite is single-writer; the seed opens the DB directly), then seed.
head1 "Local login"
if grep -q '^LOCAL_USER_API_EMAIL=' "$ROOTENV" 2>/dev/null; then
  ok "LOCAL_USER_API_* already set in apex-app/.env — skipping seed"
else
  if ! contracts_built; then
    say "building contract packages (the API imports their compiled output) ..."
    (cd "$APEX" && pnpm --filter @storagely/rental-contract build && pnpm --filter @storagely/workflow-contract build) \
      || { bad "contract build failed"; exit 1; }
  fi
  mkdir -p "$LOGDIR"
  if port_free 9600; then
    say "booting the API once to create the local database ..."
    (cd "$APEX" && nohup pnpm dev:api >> "$LOGDIR/api.log" 2>&1 &)
    wait_for_api 120 || { bad "API never became healthy — see $LOGDIR/api.log"; exit 1; }
  fi
  api_tree_down
  SEED_EMAIL_V="dev@storagely.local"
  SEED_PASS_V="$(rand_hex 16)"
  (cd "$APEX/packages/api" && SEED_EMAIL="$SEED_EMAIL_V" SEED_PASSWORD="$SEED_PASS_V" pnpm exec tsx scripts/seed-local-operator.ts) \
    || { bad "seed failed"; exit 1; }
  { echo "LOCAL_USER_API_EMAIL=$SEED_EMAIL_V"; echo "LOCAL_USER_API_PASSWORD=$SEED_PASS_V"; } >> "$ROOTENV"
  ok "seeded local operator $SEED_EMAIL_V (credentials written to apex-app/.env)"
fi

echo
ok "setup complete"
say ""
say "  Next:"
say "    make dev          start everything (first run also pulls Supabase Docker images)"
say "    make doctor       if anything looks off"
say ""
say "  To import an operator's production data ('/import <operator name>' in Claude Code,"
say "  or 'make import'): set PROD_USER_API_EMAIL / PROD_USER_API_PASSWORD in apex-app/.env."
