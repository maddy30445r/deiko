#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Put a build on the site, under /download.
#
#   ./scripts/publish-release.sh build/Deiko-0.3.1.dmg 0.3.1
#
# Uploads the DMG and writes the `version.json` beside it that the app reads at
# launch to find out whether it is out of date.
#
# A SEPARATE PREFIX FROM THE SITE, and separately deployed, because the two
# change on different days: shipping an app build must not require having the
# site's build output on this machine, and a copy fix on the landing page must
# not republish a 43MB disk image. `deploy-site.sh` syncs with `--delete` and
# excludes this prefix for exactly that reason — without the exclusion, the next
# site deploy would silently remove every published build.
#
# Versioned filenames are kept. `version.json` names the current one, so old
# builds stay downloadable and a bug report can cite a DMG that still exists.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DMG="${1:-}"
VERSION="${2:-}"
say() { printf '  %s\n' "$*"; }

[ -n "$DMG" ] && [ -n "$VERSION" ] || {
  echo "usage: publish-release.sh <dmg> <version>"; exit 1; }
[ -f "$DMG" ] || { echo "✗ $DMG does not exist — run 'make dmg' first"; exit 1; }
command -v aws >/dev/null || { echo "✗ aws CLI not found"; exit 1; }

# Shape checks, because both strings are pasted between quotes in version.json
# below — the one file every installed app and every `curl | sh` install reads.
# A stray `"` in either (a mistyped tag, a CI variable) would publish malformed
# JSON and break the update check for everyone until the next publish.
case "$VERSION" in
  *[!0-9.]*|"") echo "✗ version '$VERSION' — digits and dots only"; exit 1 ;;
esac
case "$(basename "$DMG")" in
  *[!A-Za-z0-9._-]*) echo "✗ DMG name '$(basename "$DMG")' — letters, digits, . _ - only"; exit 1 ;;
esac

# R2, reached through the S3 API. The bucket is the ONLY thing a release
# touches — the landing site is a separate Pages deployment, so shipping a
# build needs nothing of the site on this machine, and a copy fix cannot
# republish a 40MB disk image.
#
# R2 credentials are their own pair (Cloudflare dashboard → R2 → Manage API
# tokens), not the AWS ones. Kept under R2_* so an expired AWS session — the
# thing that killed the CloudFront route — cannot silently redirect an upload.
: "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID (Cloudflare dashboard → R2)}"
: "${R2_ACCESS_KEY_ID:?set R2_ACCESS_KEY_ID}"
: "${R2_SECRET_ACCESS_KEY:?set R2_SECRET_ACCESS_KEY}"

BUCKET="${DEIKO_R2_BUCKET:-deiko-downloads}"
ENDPOINT="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
# BOTH region vars. The repo's .env carries AWS_REGION=ap-south-1 for the relay,
# AWS_REGION wins over AWS_DEFAULT_REGION in CLI v2, and R2 rejects any region
# but its own — so setting only the DEFAULT one fails after uploading the whole
# file, which on a 40MB DMG is a slow way to learn this.
export AWS_REGION=auto
export AWS_DEFAULT_REGION=auto
# AWS CLI v2 sends a CRC32 trailer by default that R2 rejects with a 501 on
# streamed uploads. Asking for checksums only where the protocol requires them
# is the documented way round it, and it is not optional for a 40MB PUT.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required

s3() { aws s3 --endpoint-url "$ENDPOINT" "$@"; }

aws s3api --endpoint-url "$ENDPOINT" head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || {
  echo "✗ R2 bucket $BUCKET not reachable — create it, or check R2_* credentials"; exit 1; }

# The name users actually type. Every URL baked into version.json and the
# installer says this, and those strings outlive this script by a release
# cycle — the app's update check is compiled into a shipped plist and can
# never be corrected remotely.
SITE_ORIGIN="${SITE_URL:-https://deiko.app}"
SITE_ORIGIN="${SITE_ORIGIN%/}"
# An origin, not a URL: this string lands inside version.json AND in the
# replacement half of the sed below, where `&`, `\` and the delimiter are all
# live. Pinning the shape here is cheaper than escaping it in two places.
case "$SITE_ORIGIN" in
  https://[A-Za-z0-9]*) ;;
  *) echo "✗ SITE_URL '$SITE_ORIGIN' — expected https://<host>"; exit 1 ;;
esac
case "$SITE_ORIGIN" in
  *[!A-Za-z0-9:/.-]*) echo "✗ SITE_URL '$SITE_ORIGIN' carries characters that would corrupt version.json or the installer"; exit 1 ;;
esac
NAME=$(basename "$DMG")

say "r2 bucket $BUCKET · origin $SITE_ORIGIN"
say "uploading $NAME ($(du -h "$DMG" | cut -f1))"
# Immutable: a versioned filename never changes contents, so it can cache for a
# year and a re-download costs nothing at the edge.
s3 cp "$DMG" "s3://$BUCKET/download/$NAME" \
  --cache-control "public,max-age=31536000,immutable" >/dev/null

# The pointer. Cached for a minute only — this is the one file that has to be
# fresh, because everything downstream reads the current version out of it.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
# `url` IS WHERE THE APP SENDS SOMEBODY WHO CLICKS "Update to X…", and it was
# "$SITE_ORIGIN/download/" — a directory with no object behind it, so R2's
# function answered 404 and the one affordance an existing user has for
# updating led to a broken page. The site root is where the install one-liner
# lives, and that line is what actually performs an update: it replaces the
# bundle and clears quarantine. `robots.txt` disallows /download/ too, so this
# is the only one of the two a person was ever meant to open.
cat > "$TMP" <<JSON
{"version":"$VERSION","dmg":"$NAME","url":"$SITE_ORIGIN/"}
JSON
s3 cp "$TMP" "s3://$BUCKET/download/version.json" \
  --content-type application/json \
  --cache-control "public,max-age=60" >/dev/null

# No purge step. The R2 function passes the cache-control set at upload
# straight through, and version.json carries max-age=60 — so the pointer is
# stale for at most a minute and the DMG, whose filename is versioned, is
# immutable and never needs purging at all.

# PROVE THE STAMPED HOST SERVES WHAT WAS JUST UPLOADED. The uploads went to
# the CloudFront bucket, but every URL baked into the app, version.json and
# the installer says $SITE_ORIGIN — and nothing above checks the two are the
# same place. Pass SITE_URL=https://some-other-host and everything uploads
# green while every install's update check 404s, silently, forever (the check
# is baked into the shipped plist and can never be corrected remotely). One
# HEAD request closes the only silent-after-ship failure this script can make.
# Retried briefly because CloudFront invalidations take a moment to settle.
# VERIFY_ORIGIN: the same Pages project through another of its hosts, for a
# network that intercepts $SITE_ORIGIN's TLS. What ships still says $SITE_ORIGIN.
VERIFY="${VERIFY_ORIGIN:-$SITE_ORIGIN}"
say "verifying $VERIFY/download/version.json"
for attempt in 1 2 3 4 5; do
  if curl -fsI --max-time 10 "$VERIFY/download/version.json" >/dev/null 2>&1; then
    verified=1; break
  fi
  sleep 5
done
[ "${verified:-}" = 1 ] || {
  echo "✗ $SITE_ORIGIN does not serve /download/version.json."
  echo "  The files are uploaded, but the host every install will ask is wrong —"
  echo "  SITE_URL must be the Pages domain whose /download/* reads this bucket."
  exit 1
}

echo
echo "✓ $SITE_ORIGIN/download/$NAME"
echo "  install with:  curl -fsSL $SITE_ORIGIN/install.sh | sh"
echo "  (install.sh ships with the site — run deploy-site.sh if the origin changed)"
echo "  running installs will offer $VERSION on their next launch."
