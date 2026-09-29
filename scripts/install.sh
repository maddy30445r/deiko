#!/bin/sh
# Install Deiko.
#
#   curl -fsSL https://<site>/install.sh | sh
#
# Downloads the current DMG, replaces /Applications/Deiko.app, and clears the
# quarantine attribute recursively. Deiko is signed with a self-signed
# certificate, so macOS quarantines the download; the GUI bypass can leave the
# Node runtime nested inside the bundle quarantined, and the app then hangs at
# "Transcribing..." with nothing pointing at the cause.
#
# It reads download/version.json, the same file the app's update check reads.
#
# There is no checksum on purpose: the DMG and its hash would come from the same
# origin over the same TLS connection, so the check would prove nothing.
#
# `sh`, not `bash`: this runs on a Mac nobody has set up.

set -eu

# The placeholder is replaced at publish time: publish-release.sh rewrites this
# line as it uploads the file, so the served copy names the host that served it.
# DEIKO_SITE_URL overrides it, e.g. to point at a local server.
SITE="${DEIKO_SITE_URL:-https://deiko.example}"
SITE="${SITE%/}"
APP="/Applications/Deiko.app"

fail() { printf '\n✗ %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Deiko is macOS only."

# Apple silicon only. The app binary and the bundled Node runtime are arm64-thin
# (Rosetta only translates x86_64 onto arm64), so on an Intel Mac the launch
# would fail with a system dialog after a full download.
[ "$(uname -m)" = "arm64" ] \
  || fail "Deiko needs an Apple-silicon Mac (this one reports $(uname -m))."

# macOS 14+. `sw_vers -productVersion` is "15.2" or "26.0"; the major is enough.
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] 2>/dev/null \
  || fail "Deiko needs macOS 14 or later (this is $(sw_vers -productVersion))."

printf 'Looking up the latest release…\n'

# version.json is one flat object. Parsed with sed because jq is not on a stock
# Mac.
manifest=$(curl -fsSL "$SITE/download/version.json") \
  || fail "Could not reach $SITE. Are you online?"

field() { printf '%s' "$manifest" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'; }
version=$(field version)
dmg=$(field dmg)

[ -n "$version" ] && [ -n "$dmg" ] || fail "$SITE/download/version.json is malformed."

# Work in a temp dir cleaned up on any exit, so a failed install does not leave
# a mounted volume behind.
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

# Replace wholesale: `cp -R` onto an existing bundle merges, so files only the
# old build had would survive.
if [ -d "$APP" ]; then
  printf 'Replacing the existing install…\n'
  osascript -e 'quit app "Deiko"' 2>/dev/null || true
  sleep 1
  rm -rf "$APP" || fail "Could not remove $APP — is it running?"
fi

printf 'Installing to %s\n' "$APP"
cp -R "$mounted/Deiko.app" /Applications/ || fail "Could not copy into /Applications."

# Recursive, so the nested Node runtime is cleared too.
xattr -dr com.apple.quarantine "$APP"

# Checked, because the success message below claims the app is running.
open "$APP" || fail "Deiko installed to $APP but would not launch. Open it from Applications, and send what macOS says."

cat <<'DONE'

✓ Deiko is installed and running — look for the ring in your menu bar.

  A first-run window explains the four permissions it needs and why.
  Then: double-tap Right Option, point at something and talk, tap Right
  Option to stop, and drag the coin onto your coding agent's window.

DONE
