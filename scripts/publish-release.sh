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

if ! ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo "✗ no AWS credentials. Run 'aws configure' first."
  exit 1
fi

# Same derivation as deploy-site.sh — one bucket, one site.
BUCKET="${DEIKO_SITE_BUCKET:-deiko-site-$ACCOUNT}"
aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || {
  echo "✗ bucket $BUCKET does not exist — run scripts/deploy-site.sh first"; exit 1; }

DIST_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='deiko-site'].Id | [0]" --output text 2>/dev/null || echo "None")
[ "$DIST_ID" != "None" ] && [ -n "$DIST_ID" ] || {
  echo "✗ no 'deiko-site' CloudFront distribution — run scripts/deploy-site.sh first"; exit 1; }

CF_DOMAIN=$(aws cloudfront get-distribution --id "$DIST_ID" --query Distribution.DomainName --output text)

# The name users actually type, when there is one. CloudFront's own
# `dxxxx.cloudfront.net` is the origin's address, not the product's, and once a
# custom domain is aliased onto the distribution every URL we bake into
# version.json and into the installer should say the real one — those strings
# outlive this script by a release cycle.
SITE_ORIGIN="${SITE_URL:-https://$CF_DOMAIN}"
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

say "account $ACCOUNT · bucket $BUCKET"
say "uploading $NAME ($(du -h "$DMG" | cut -f1))"
# Immutable: a versioned filename never changes contents, so it can cache for a
# year and a re-download costs nothing at the edge.
aws s3 cp "$DMG" "s3://$BUCKET/download/$NAME" \
  --cache-control "public,max-age=31536000,immutable" >/dev/null

# The pointer. Cached for a minute only — this is the one file that has to be
# fresh, because everything downstream reads the current version out of it.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<JSON
{"version":"$VERSION","dmg":"$NAME","url":"$SITE_ORIGIN/download/"}
JSON
aws s3 cp "$TMP" "s3://$BUCKET/download/version.json" \
  --content-type application/json \
  --cache-control "public,max-age=60" >/dev/null

# THE INSTALLER, STAMPED WITH THE HOST THAT WILL SERVE IT.
#
# `scripts/install.sh` carries a placeholder origin, and for a long time
# nothing published the file at all: `deploy-site.sh` syncs the site directory
# and the installer does not live there. So the documented one-liner —
# `curl -fsSL https://<site>/install.sh | sh` — fetched a 404, and any copy
# that did get served looked its release up on a domain that does not exist.
# Publishing it here, from the script that already knows the domain and the
# version it is publishing, is what keeps the two in step.
sed "s|https://deiko.example|$SITE_ORIGIN|g" scripts/install.sh > "$TMP.sh"
aws s3 cp "$TMP.sh" "s3://$BUCKET/install.sh" \
  --content-type "text/x-shellscript" \
  --cache-control "public,max-age=300" >/dev/null
rm -f "$TMP.sh"
say "published install.sh → $SITE_ORIGIN/install.sh"

aws cloudfront create-invalidation --distribution-id "$DIST_ID" \
  --paths "/download/version.json" "/install.sh" --query Invalidation.Id --output text >/dev/null
say "invalidated version.json and install.sh"

# PROVE THE STAMPED HOST SERVES WHAT WAS JUST UPLOADED. The uploads went to
# the CloudFront bucket, but every URL baked into the app, version.json and
# the installer says $SITE_ORIGIN — and nothing above checks the two are the
# same place. Pass SITE_URL=https://some-other-host and everything uploads
# green while every install's update check 404s, silently, forever (the check
# is baked into the shipped plist and can never be corrected remotely). One
# HEAD request closes the only silent-after-ship failure this script can make.
# Retried briefly because CloudFront invalidations take a moment to settle.
say "verifying $SITE_ORIGIN/download/version.json"
for attempt in 1 2 3 4 5; do
  if curl -fsI --max-time 10 "$SITE_ORIGIN/download/version.json" >/dev/null 2>&1; then
    verified=1; break
  fi
  sleep 5
done
[ "${verified:-}" = 1 ] || {
  echo "✗ $SITE_ORIGIN does not serve /download/version.json."
  echo "  The files are uploaded, but the host every install will ask is wrong —"
  echo "  SITE_URL must be a domain that fronts this CloudFront distribution."
  exit 1
}

echo
echo "✓ $SITE_ORIGIN/download/$NAME"
echo "  install with:  curl -fsSL $SITE_ORIGIN/install.sh | sh"
echo "  running installs will offer $VERSION on their next launch."
