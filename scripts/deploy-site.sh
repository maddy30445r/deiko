#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Put the landing site on S3 behind CloudFront.
#
#   ./scripts/deploy-site.sh site/          # any directory of static files
#
# The bucket stays PRIVATE and CloudFront reaches it through an Origin Access
# Control. A public bucket is the classic way to end up serving something you
# did not mean to, and it buys nothing here — CloudFront is the only reader.
#
# No custom domain yet, so this hands back a *.cloudfront.net hostname. Adding
# a domain later is one ACM certificate (in us-east-1, which CloudFront
# requires) and one alias on the distribution; nothing here has to change.
#
# Idempotent: run it again to publish an update.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SITE_DIR="${1:-site}"
BUCKET="${FOVEA_SITE_BUCKET:-}"
say() { printf '  %s\n' "$*"; }

command -v aws >/dev/null || { echo "✗ aws CLI not found"; exit 1; }
[ -d "$SITE_DIR" ] || { echo "✗ $SITE_DIR does not exist — build the site first"; exit 1; }
[ -f "$SITE_DIR/index.html" ] || { echo "✗ $SITE_DIR has no index.html"; exit 1; }

if ! ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo "✗ no AWS credentials. Run 'aws configure' first."
  exit 1
fi

# S3 bucket names are globally unique across every AWS customer, so the account
# id is appended rather than hoping "fovea-site" is free.
BUCKET="${BUCKET:-fovea-site-$ACCOUNT}"
say "account $ACCOUNT · bucket $BUCKET"

# ── The bucket ──────────────────────────────────────────────────────────────
#
# us-east-1 has no LocationConstraint and errors if you send one — the one
# region special case worth handling rather than discovering.

REGION="${AWS_REGION:-ap-south-1}"
if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  say "creating bucket"
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
fi

# ── The distribution ────────────────────────────────────────────────────────

DIST_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='fovea-site'].Id | [0]" --output text 2>/dev/null || echo "None")

if [ "$DIST_ID" = "None" ] || [ -z "$DIST_ID" ]; then
  say "creating origin access control"
  OAC_ID=$(aws cloudfront create-origin-access-control --origin-access-control-config \
    "Name=fovea-site-oac,Description=Fovea landing site,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
    --query OriginAccessControl.Id --output text)

  say "creating distribution (this takes a few minutes to propagate)"
  # CachingOptimized is AWS's managed policy id — a constant, not a magic
  # number we chose.
  DIST_JSON=$(cat <<JSON
{
  "CallerReference": "fovea-site-$(date +%s)",
  "Comment": "fovea-site",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "Origins": {"Quantity": 1, "Items": [{
    "Id": "s3-$BUCKET",
    "DomainName": "$BUCKET.s3.$REGION.amazonaws.com",
    "OriginAccessControlId": "$OAC_ID",
    "S3OriginConfig": {"OriginAccessIdentity": ""}
  }]},
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-$BUCKET",
    "ViewerProtocolPolicy": "redirect-to-https",
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
    "Compress": true
  },
  "CustomErrorResponses": {"Quantity": 1, "Items": [{
    "ErrorCode": 403, "ResponsePagePath": "/index.html",
    "ResponseCode": "200", "ErrorCachingMinTTL": 10
  }]}
}
JSON
)
  DIST_ID=$(aws cloudfront create-distribution --distribution-config "$DIST_JSON" \
    --query Distribution.Id --output text)

  say "granting CloudFront read on the bucket"
  aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$(cat <<JSON
{"Version":"2012-10-17","Statement":[{
  "Effect":"Allow",
  "Principal":{"Service":"cloudfront.amazonaws.com"},
  "Action":"s3:GetObject",
  "Resource":"arn:aws:s3:::$BUCKET/*",
  "Condition":{"StringEquals":{"AWS:SourceArn":"arn:aws:cloudfront::$ACCOUNT:distribution/$DIST_ID"}}
}]}
JSON
)"
fi

DOMAIN=$(aws cloudfront get-distribution --id "$DIST_ID" --query Distribution.DomainName --output text)

# ── Publish ─────────────────────────────────────────────────────────────────
#
# HTML gets a short cache so a copy fix is live in a minute; everything else is
# assumed to be content-addressed by the site generator and cached hard.

#
# `download/` IS NOT OURS TO DELETE. Builds are published there by
# `scripts/publish-release.sh` on a different day from any site change, and
# `--delete` removes whatever is in the bucket but not in $SITE_DIR — so without
# this exclusion the next copy fix on the landing page would quietly take every
# downloadable build with it, including the one the app's update check points at.
say "uploading $SITE_DIR"
aws s3 sync "$SITE_DIR" "s3://$BUCKET" --delete --exclude "download/*" \
  --exclude "*.html" --cache-control "public,max-age=31536000,immutable" >/dev/null
# The download exclusion comes LAST here, not first: s3 filters are applied in
# order and the last match wins, so putting it before `--include "*.html"` would
# let that include put `download/*.html` back in scope for deletion.
aws s3 sync "$SITE_DIR" "s3://$BUCKET" --delete \
  --exclude "*" --include "*.html" --exclude "download/*" \
  --cache-control "public,max-age=60" >/dev/null

aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*" \
  --query Invalidation.Id --output text >/dev/null
say "invalidated the cache"

echo
echo "✓ https://$DOMAIN"
echo "  distribution $DIST_ID · bucket $BUCKET (private)"
echo "  a new distribution takes a few minutes before it serves."
