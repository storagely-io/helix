#!/usr/bin/env bash
# Install prerequisites for both repos.
# Everything lands outside the repos (~/.bun) or in gitignored node_modules, so
# nothing here makes a tracked change.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

head1 "Helix (apex-app) — pnpm"
# --frozen-lockfile on purpose: pnpm-lock.yaml is TRACKED, and a plain install can
# rewrite it, which would break the "nothing git-tracked changes" rule for this
# whole setup. If the lockfile is genuinely stale that's a real repo change and
# belongs in its own commit, not in a dev-environment bootstrap.
if [ -d "$APEX/node_modules" ]; then
  ok "apex-app/node_modules already present — skipping (nothing to do)"
else
  (cd "$APEX" && pnpm install --frozen-lockfile) || {
    bad "pnpm install --frozen-lockfile failed"
    say "     If it failed on lockfile drift, run 'pnpm install' in apex-app yourself"
    say "     and commit the lockfile change deliberately."
    exit 1; }
  ok "apex-app dependencies installed"
fi

head1 "bun"
if command -v bun >/dev/null 2>&1; then
  ok "bun already present ($(bun --version))"
else
  say "Atlas requires bun: bun.lock is its only lockfile, and neither"
  say "package-lock.json nor pnpm-lock.yaml is gitignored there, so npm/pnpm"
  say "would drop a TRACKED lockfile into the repo."
  say "Installing to ~/.bun (outside both repos) ..."
  curl -fsSL https://bun.sh/install | bash || { bad "bun install failed"; exit 1; }
  export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
  export PATH="$BUN_INSTALL/bin:$PATH"
  command -v bun >/dev/null 2>&1 || { bad "bun still not on PATH — add \$HOME/.bun/bin and re-run"; exit 1; }
  ok "bun installed ($(bun --version))"
  warn "add this to your shell profile if it isn't already:"
  say '     export PATH="$HOME/.bun/bin:$PATH"'
fi

head1 "Atlas — bun install"
# bunfig.toml sets minimumReleaseAge (a 24h supply-chain guard) with excludes for
# the two @lovable.dev packages. Nothing to override; just run it.
# --frozen-lockfile for the same reason: atlas/bun.lock is TRACKED.
(cd "$ATLAS" && bun install --frozen-lockfile) || {
  bad "bun install --frozen-lockfile failed in atlas"
  say "     If it failed on lockfile drift, run 'bun install' in atlas yourself and"
  say "     commit bun.lock deliberately — Lovable also writes that file."
  exit 1; }
ok "atlas dependencies installed"

head1 "Embed wiring"
"$HELIX_ROOT/scripts/wire-embed.sh"

echo; ok "install complete — run 'make doctor' then 'make dev'"
