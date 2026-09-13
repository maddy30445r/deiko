#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Put the landing site on Cloudflare Pages.
#
#   ./scripts/deploy-site.sh
#   SITE_URL=https://staging.deiko.app ./scripts/deploy-site.sh
#
# WAS S3 + CLOUDFRONT. CreateDistribution is refused on an unverified AWS
# account, which is a wall you hit at the end rather than the start. Pages has
# no such gate, no egress bill, and serves index.html without the 403-rewrite
# dance the S3 version needed.
#
# Builds are NOT deployed from here. /download/* is streamed from the R2 bucket
# by functions/download/[[path]].js, and scripts/publish-release.sh is the
# only thing that writes there — so a copy fix on the landing page cannot
# disturb a published DMG. The old script needed an --exclude "download/*" on
# its sync to get that; here it falls out of the architecture instead of
# depending on a flag staying right.
#
# Idempotent: run it again to publish an update.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PROJECT="${DEIKO_PAGES_PROJECT:-deiko-site}"
say() { printf '  %s\n' "$*"; }

# No directory argument: wrangler.toml names the source as pages_build_output_dir
# and passing both is ambiguous to wrangler. One place, one answer.
SITE_DIR="site"
[ -f "$SITE_DIR/index.html" ] || { echo "✗ $SITE_DIR has no index.html"; exit 1; }
command -v npx >/dev/null || { echo "✗ npx not found — install Node 22+"; exit 1; }

SITE_ORIGIN="${SITE_URL:-https://deiko.app}"
SITE_ORIGIN="${SITE_ORIGIN%/}"
case "$SITE_ORIGIN" in
  https://[A-Za-z0-9]*) ;;
  *) echo "✗ SITE_URL '$SITE_ORIGIN' — expected https://<host>"; exit 1 ;;
esac

# THE INSTALLER IS SITE CONTENT, not a release artifact. It changes only when
# the origin does, and `curl -fsSL https://deiko.app/install.sh | sh` is a
# landing-page URL — so it ships with the page rather than with a build.
#
# Written in, deployed, removed. The trap fires on failure too, because a
# stamped install.sh left in the tree gets committed with a hardcoded origin
# sooner or later; .gitignore carries it as the second line of defence.
trap 'rm -f "$SITE_DIR/install.sh"' EXIT
sed "s|https://deiko.example|$SITE_ORIGIN|g" scripts/install.sh > "$SITE_DIR/install.sh"

say "project $PROJECT · origin $SITE_ORIGIN"
npx wrangler pages deploy --project-name "$PROJECT" --commit-dirty=true

echo
echo "  first deploy only — attach the domain once, in the dashboard:"
echo "    Workers & Pages → $PROJECT → Custom domains → deiko.app"
