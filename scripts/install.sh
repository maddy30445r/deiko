#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# INSTALL DEIKO
#
#   curl -fsSL https://<site>/install.sh | sh
#
# This file exists for ONE line: `xattr -dr com.apple.quarantine`. Everything
# else here is the drag-to-Applications the user would have done anyway.
#
# Deiko is signed with a self-signed certificate rather than an Apple Developer
# ID, so macOS quarantines the download. The GUI bypass (System Settings →
# Privacy & Security → Open Anyway) clears the app and lets it launch — but can
# leave the 110MB Node runtime NESTED INSIDE the bundle quarantined, and Deiko
# spawns that runtime to transcribe. The failure surfaces minutes later as a
# session stuck at "Transcribing…", with nothing on screen connecting it to a
# security prompt the user dismissed correctly. Recursive `xattr` on the whole
# bundle is what actually fixes it, and asking somebody to paste that out of a
# text file inside a disk image is where installs were being lost.
#
# It reads `download/version.json` — the same file the app's own update check
# reads, so there is one answer to "what is the current version" and not two.
#
# NO CHECKSUM, deliberately. The DMG and any hash would come from the same
# origin over the same TLS connection, so a check would verify only that the
# server agrees with itself. Real integrity here is a Developer ID signature and
# notarisation, which costs $99 — not a reassuring-looking `shasum` line.
#
# `sh`, not `bash`: this runs on a Mac nobody has set up.
# ─────────────────────────────────────────────────────────────────────────────

set -eu

# THE PLACEHOLDER IS REPLACED AT PUBLISH TIME. `publish-release.sh` rewrites
# this line as it uploads the file, so the copy being served always names the
# host that served it. A script fetched from the real site cannot look up its
# release on a domain that does not exist — which is what happened for as long
# as this default was the only thing here.
#
# Still overridable, so it can be pointed at a local server before it is live.
SITE="${DEIKO_SITE_URL:-https://deiko.example}"
SITE="${SITE%/}"
APP="/Applications/Deiko.app"

fail() { printf '\n✗ %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Deiko is macOS only."

# Apple silicon only. Both the app binary and the bundled Node runtime are
# arm64-thin, and Rosetta translates x86_64 onto arm64, never the other way —
# so on an Intel Mac the download succeeds, the copy succeeds, and the launch
# fails with a system dialog. Refusing here costs 41MB less and one clear
# sentence more.
[ "$(uname -m)" = "arm64" ] \
  || fail "Deiko needs an Apple-silicon Mac (this one reports $(uname -m))."

# macOS 14+. `sw_vers -productVersion` is "15.2" or "26.0"; the major is enough.
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] 2>/dev/null \
  || fail "Deiko needs macOS 14 or later (this is $(sw_vers -productVersion))."

printf 'Looking up the latest release…\n'

# version.json is one flat object. Parsed with sed rather than jq because jq is
# not on a stock Mac, and telling somebody to install a JSON processor before
# they can install an app is the friction this script exists to remove.
manifest=$(curl -fsSL "$SITE/download/version.json") \
  || fail "Could not reach $SITE. Are you online?"

field() { printf '%s' "$manifest" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'; }
version=$(field version)
dmg=$(field dmg)

[ -n "$version" ] && [ -n "$dmg" ] || fail "$SITE/download/version.json is malformed."

# Everything happens in a temp dir that is cleaned up however we exit — a failed
# install must not leave a mounted volume behind for the user to find later.
work=$(mktemp -d)
mounted=""
cleanup() {
  [ -n "$mounted" ] && hdiutil detach "$mounted" -quiet 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

printf 'Downloading Deiko %s\n' "$version"
curl -fL# "$SITE/download/$dmg" -o "$work/Deiko.dmg" || fail "Download failed."

mounted="$work/mnt"
mkdir -p "$mounted"
hdiutil attach "$work/Deiko.dmg" -mountpoint "$mounted" -nobrowse -quiet \
  || fail "Could not open the disk image."

[ -d "$mounted/Deiko.app" ] || fail "No Deiko.app inside the disk image."

# Replace wholesale rather than copying over. `cp -R` onto an existing bundle
# MERGES, so files the old build had and the new one does not simply survive —
# the same trap the Makefile's `install` target documents.
if [ -d "$APP" ]; then
  printf 'Replacing the existing install…\n'
  osascript -e 'quit app "Deiko"' 2>/dev/null || true
  sleep 1
  rm -rf "$APP" || fail "Could not remove $APP — is it running?"
fi

printf 'Installing to %s\n' "$APP"
cp -R "$mounted/Deiko.app" /Applications/ || fail "Could not copy into /Applications."

# THE LINE THIS SCRIPT EXISTS FOR.
xattr -dr com.apple.quarantine "$APP"

# Checked, because the success block below is a claim. An unchecked `open`
# printed "installed and running" over the top of a system dialog saying the
# app could not be opened — the install failed and the script congratulated
# the user for it.
open "$APP" || fail "Deiko installed to $APP but would not launch. Open it from Applications, and send what macOS says."

cat <<'DONE'

✓ Deiko is installed and running — look for the ring in your menu bar.

  A first-run window explains the four permissions it needs and why.
  Then: double-tap Right Option, point at something and talk, tap Right
  Option to stop, and drag the coin onto your coding agent's window.

DONE
