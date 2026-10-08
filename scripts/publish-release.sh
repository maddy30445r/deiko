#!/usr/bin/env bash
# Put a build on the site, under /download.
#
#   ./scripts/publish-release.sh build/Deiko-0.3.1.dmg 0.3.1
#
# Uploads the DMG and writes the version.json beside it that the app reads at
# launch to check whether it is out of date.
#
# /download is served from R2, separately from the site's own deploy, so a
# copy fix on the site never republishes a disk image.
#
# Versioned filenames are kept: version.json names the current one, and old
# builds stay downloadable.
set -euo pipefail

DMG="${1:-}"
VERSION="${2:-}"
say() { printf '  %s\n' "$*"; }

[ -n "$DMG" ] && [ -n "$VERSION" ] || {
  echo "usage: publish-release.sh <dmg> <version>"; exit 1; }
[ -f "$DMG" ] || { echo "✗ $DMG does not exist — run 'make dmg' first"; exit 1; }
command -v aws >/dev/null || { echo "✗ aws CLI not found"; exit 1; }

# Shape checks: both strings are pasted between quotes in version.json below,
# which every installed app and `curl | sh` install reads. A stray `"` would
# publish malformed JSON and break the update check for everyone.
case "$VERSION" in
  *[!0-9.]*|"") echo "✗ version '$VERSION' — digits and dots only"; exit 1 ;;
esac
case "$(basename "$DMG")" in
  *[!A-Za-z0-9._-]*) echo "✗ DMG name '$(basename "$DMG")' — letters, digits, . _ - only"; exit 1 ;;
esac

# R2, reached through the S3 API. The bucket is the only thing a release
# touches; the landing site is a separate Pages deployment.
#
# R2 credentials are their own pair (Cloudflare dashboard, R2, Manage API
# tokens), kept under R2_* so an AWS session cannot redirect an upload.
: "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID (Cloudflare dashboard → R2)}"
: "${R2_ACCESS_KEY_ID:?set R2_ACCESS_KEY_ID}"
: "${R2_SECRET_ACCESS_KEY:?set R2_SECRET_ACCESS_KEY}"

BUCKET="${DEIKO_R2_BUCKET:-deiko-downloads}"
ENDPOINT="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
# Set both region vars: the repo's .env carries AWS_REGION=ap-south-1 for the
# relay, AWS_REGION wins over AWS_DEFAULT_REGION in CLI v2, and R2 rejects any
# region but its own.
export AWS_REGION=auto
export AWS_DEFAULT_REGION=auto
# AWS CLI v2 sends a CRC32 trailer by default that R2 rejects with a 501 on
# streamed uploads; request checksums only where the protocol requires them.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required

s3() { aws s3 --endpoint-url "$ENDPOINT" "$@"; }

aws s3api --endpoint-url "$ENDPOINT" head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || {
  echo "✗ R2 bucket $BUCKET not reachable — create it, or check R2_* credentials"; exit 1; }

# The public origin. Every URL in version.json and the installer uses it, and
# the app's update check is baked into a shipped plist that cannot be corrected
# remotely.
SITE_ORIGIN="${SITE_URL:-https://deiko.app}"
SITE_ORIGIN="${SITE_ORIGIN%/}"
# An origin, not a URL: it lands inside version.json and in a sed replacement,
# where `&`, `\` and the delimiter are special. Pin the shape rather than escape.
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
# Immutable: a versioned filename never changes contents.
s3 cp "$DMG" "s3://$BUCKET/download/$NAME" \
  --cache-control "public,max-age=31536000,immutable" >/dev/null

# version.json must never point at a file that isn't there: 0.5.10's pointer went
# up without its DMG and every install failed for eight days. Check the stored
# size before writing the pointer.
STORED=$(aws s3api --endpoint-url "$ENDPOINT" head-object --bucket "$BUCKET" --key "download/$NAME" \
  --query ContentLength --output text 2>/dev/null || true)
[ "$STORED" = "$(stat -f %z "$DMG")" ] || {
  echo "✗ $NAME is not in the bucket at full size (got '${STORED:-nothing}') — version.json left unchanged"; exit 1; }

# The pointer. Cached for a minute only: it is the one file that must be fresh.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
# `url` is where the app sends a user who clicks "Update". It points at the site
# root, where the install one-liner lives; that line performs the update.
# /download/ has no index page and is disallowed in robots.txt.
cat > "$TMP" <<JSON
{"version":"$VERSION","dmg":"$NAME","url":"$SITE_ORIGIN/"}
JSON
s3 cp "$TMP" "s3://$BUCKET/download/version.json" \
  --content-type application/json \
  --cache-control "public,max-age=60" >/dev/null

# No purge step: the cache-control set at upload passes straight through, so the
# pointer is stale for at most a minute and the versioned DMG never needs one.

# Check that the stamped host serves what was just uploaded. Every URL baked
# into the app, version.json and the installer says $SITE_ORIGIN, but the upload
# goes to the bucket; a wrong SITE_URL would upload cleanly while every install's
# update check 404s. Retried briefly to let the edge settle.
# VERIFY_ORIGIN: the same Pages project through another of its hosts, for a
# network that intercepts $SITE_ORIGIN's TLS. What ships still says $SITE_ORIGIN.
VERIFY="${VERIFY_ORIGIN:-$SITE_ORIGIN}"
say "verifying $VERIFY/download/version.json and $NAME"
for attempt in 1 2 3 4 5; do
  if curl -fsI --max-time 10 "$VERIFY/download/version.json" >/dev/null 2>&1 \
    && curl -fsI --max-time 10 "$VERIFY/download/$NAME" >/dev/null 2>&1; then
    verified=1; break
  fi
  sleep 5
done
[ "${verified:-}" = 1 ] || {
  echo "✗ $SITE_ORIGIN does not serve /download/version.json and /download/$NAME."
  echo "  The files are uploaded, but the host every install will ask is wrong —"
  echo "  SITE_URL must be the Pages domain whose /download/* reads this bucket."
  exit 1
}

echo
echo "✓ $SITE_ORIGIN/download/$NAME"
echo "  install with:  curl -fsSL $SITE_ORIGIN/install.sh | sh"
echo "  (install.sh ships with the site — redeploy the site if the origin changed)"
echo "  running installs will offer $VERSION on their next launch."
