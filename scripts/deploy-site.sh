#!/usr/bin/env bash
# Deploy the site (apps/web) to Cloudflare Pages. Idempotent.
#
#   ./scripts/deploy-site.sh
#   SITE_URL=https://staging.deiko.app ./scripts/deploy-site.sh
#
# Releases are not deployed from here: /download/* streams from R2 via
# apps/web/functions/download, and only publish-release.sh writes there.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
WEB="$REPO/apps/web"
SITE_DIR="$WEB/public"
PROJECT="${DEIKO_PAGES_PROJECT:-deiko-site}"
say() { printf '  %s\n' "$*"; }

[ -f "$SITE_DIR/index.html" ] || { echo "✗ $SITE_DIR has no index.html"; exit 1; }
command -v npx >/dev/null || { echo "✗ npx not found — install Node 22+"; exit 1; }

SITE_ORIGIN="${SITE_URL:-https://deiko.app}"
SITE_ORIGIN="${SITE_ORIGIN%/}"
case "$SITE_ORIGIN" in
  https://[A-Za-z0-9]*) ;;
  *) echo "✗ SITE_URL '$SITE_ORIGIN' — expected https://<host>"; exit 1 ;;
esac

# The installer is served by the site, stamped with its origin. Removed on
# exit so a stamped copy is never committed.
trap 'rm -f "$SITE_DIR/install.sh"' EXIT
sed "s|https://deiko.example|$SITE_ORIGIN|g" "$REPO/scripts/install.sh" > "$SITE_DIR/install.sh"

say "project $PROJECT · origin $SITE_ORIGIN"
(cd "$WEB" && npx wrangler pages deploy --project-name "$PROJECT" --commit-dirty=true)
