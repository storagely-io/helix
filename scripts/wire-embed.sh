#!/usr/bin/env bash
# Point the platform shell's Atlas iframe at the LOCAL Atlas, and tell Atlas to
# verify against the LOCAL Helix API.
#
# Writes only packages/platform/.env.local, which is gitignored (.gitignore:2).
#
# WHY THE IFRAME ORIGIN IS NOT "localhost":
# Atlas's useIsEmbedded() does this (src/lib/iframe-session.tsx):
#     if (isLovableHost(window.location.hostname)) { setEmbedded(false); return; }
#     // isLovableHost: host === "localhost" || host === "127.0.0.1" || *.lovable.app
# Served from localhost:9730 it classifies ITSELF as a Lovable preview pane and
# renders its FULL shell — its own left rail and top bar — nested inside Helix's
# shell. That is the duplicated chrome (two rails, two top bars, two avatars).
# Its auth path deliberately does NOT make this mistake ("a real iframe load
# always runs the real handshake, even on localhost"); only the chrome check does.
#
# So we serve the iframe from a host that is not localhost. The LAN IP is used
# because Vite's host allowlist accepts IP literals but 403s invented hostnames
# like atlas.localtest.me. The IP is recomputed every run since it changes on
# reboot.
#
# What must NOT change: the PARENT origin stays http://localhost:9720. Atlas
# honours ?apiBase= only for that exact parent, and localhost:9720 is what its
# ALLOWED_PARENT_ORIGINS permits — so keep browsing the shell on localhost.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENVLOCAL="$APEX/packages/platform/.env.local"
touch "$ENVLOCAL"

ATLAS_HOST="localhost"
if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
  IP="$(ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)"
  if [ -n "$IP" ]; then
    ATLAS_HOST="$IP"
  else
    warn "could not determine the LAN IP — falling back to localhost"
    say "     Atlas will render its own duplicate chrome inside the shell."
  fi
fi

WANT="VITE_ATLAS_IFRAME_URL=http://${ATLAS_HOST}:9730?apiBase=http://localhost:9600"

# Rewrite in place rather than append-if-missing: the IP changes across reboots,
# so a stale value must be replaced, not kept.
# Managed block, delimited so a rewrite replaces it whole. Without markers the
# explanatory comments were orphaned on every IP change and piled up.
BEGIN="# >>> helix workspace: atlas embed >>>"
END="# <<< helix workspace: atlas embed <<<"

CURRENT="$(sed -n "/^${BEGIN}\$/,/^${END}\$/p" "$ENVLOCAL" | grep -E '^VITE_ATLAS_IFRAME_URL=' | head -1)"
if [ "$CURRENT" = "$WANT" ]; then
  ok "embed already wired -> http://${ATLAS_HOST}:9730"
  exit 0
fi

tmp="$(mktemp)"
# Drop the managed block AND any bare legacy line from before markers existed.
sed "/^${BEGIN}\$/,/^${END}\$/d" "$ENVLOCAL" \
  | grep -vE '^[[:space:]]*VITE_ATLAS_IFRAME_URL=' \
  | grep -vE '^# (Local Atlas embed|origin -> local Atlas|Atlas only honours apiBase|Host is the LAN IP|Lovable preview and renders|Keep browsing the SHELL|parent origin, and only)' \
  | cat -s > "$tmp"
mv "$tmp" "$ENVLOCAL"; chmod 644 "$ENVLOCAL"

{
  echo "$BEGIN"
  echo "# Host is the LAN IP, NOT localhost: Atlas's useIsEmbedded() treats a"
  echo "# localhost origin as a Lovable preview and renders its own duplicate shell."
  echo "# Recomputed each run because the WSL IP changes on reboot."
  echo "# Keep browsing the SHELL on http://localhost:9720 — that is the only parent"
  echo "# origin Atlas accepts, and the only one it honours apiBase for."
  echo "$WANT"
  echo "$END"
} >> "$ENVLOCAL"
ok "wired Atlas iframe origin -> http://${ATLAS_HOST}:9730"
