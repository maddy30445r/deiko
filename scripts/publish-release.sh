#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Put a build on the site, under /download.
#
#   ./scripts/publish-release.sh build/Fovea-0.3.1.dmg 0.3.1
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

if ! ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo "✗ no AWS credentials. Run 'aws configure' first."
  exit 1
fi

# Same derivation as deploy-site.sh — one bucket, one site.
BUCKET="${FOVEA_SITE_BUCKET:-fovea-site-$ACCOUNT}"
aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || {
  echo "✗ bucket $BUCKET does not exist — run scripts/deploy-site.sh first"; exit 1; }

DIST_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='fovea-site'].Id | [0]" --output text 2>/dev/null || echo "None")
[ "$DIST_ID" != "None" ] && [ -n "$DIST_ID" ] || {
  echo "✗ no 'fovea-site' CloudFront distribution — run scripts/deploy-site.sh first"; exit 1; }

CF_DOMAIN=$(aws cloudfront get-distribution --id "$DIST_ID" --query Distribution.DomainName --output text)

# The name users actually type, when there is one. CloudFront's own
# `dxxxx.cloudfront.net` is the origin's address, not the product's, and once a
# custom domain is aliased onto the distribution every URL we bake into
# version.json and into the installer should say the real one — those strings
# outlive this script by a release cycle.
SITE_ORIGIN="${SITE_URL:-https://$CF_DOMAIN}"
SITE_ORIGIN="${SITE_ORIGIN%/}"
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
sed "s|https://fovea.example|$SITE_ORIGIN|g" scripts/install.sh > "$TMP.sh"
aws s3 cp "$TMP.sh" "s3://$BUCKET/install.sh" \
  --content-type "text/x-shellscript" \
  --cache-control "public,max-age=300" >/dev/null
rm -f "$TMP.sh"
say "published install.sh → $SITE_ORIGIN/install.sh"

aws cloudfront create-invalidation --distribution-id "$DIST_ID" \
  --paths "/download/version.json" "/install.sh" --query Invalidation.Id --output text >/dev/null
say "invalidated version.json and install.sh"

echo
echo "✓ $SITE_ORIGIN/download/$NAME"
echo "  install with:  curl -fsSL $SITE_ORIGIN/install.sh | sh"
echo "  running installs will offer $VERSION on their next launch."
