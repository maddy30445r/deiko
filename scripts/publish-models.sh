#!/usr/bin/env bash
# Publish the meaning model: the files the app downloads once after install.
#
#   make models-publish            # the default model (packages/core/src/lib/meaning.mjs)
#
# Uploads each file of the model from this Mac's copy
# (~/Library/Application Support/Deiko/models/<key>/, fetched and
# checksum-verified by `node packages/core/src/meaning.mjs download --from-hf`)
# to R2 at download/models/<key>/<path>, where the site's /download function
# serves it. Every file's SHA-256 is checked against MODELS before upload, and
# every URL is fetched back afterwards. Uses the same R2_* credentials as
# publish-release.sh.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
: "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID (Cloudflare dashboard → R2)}"
: "${R2_ACCESS_KEY_ID:?set R2_ACCESS_KEY_ID}"
: "${R2_SECRET_ACCESS_KEY:?set R2_SECRET_ACCESS_KEY}"
BUCKET="${DEIKO_R2_BUCKET:-deiko-downloads}"
ENDPOINT="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
# R2 accepts only its own region and rejects the CRC32 trailer AWS CLI v2 adds
# (see publish-release.sh).
export AWS_REGION=auto AWS_DEFAULT_REGION=auto AWS_REQUEST_CHECKSUM_CALCULATION=when_required
unset AWS_SESSION_TOKEN AWS_PROFILE

# key, local dir, base URL and "path sha256" lines, all from MODELS.
LIST=$(cd "$REPO" && node --input-type=module -e '
  const { MODELS, DEFAULT_MODEL, MODEL_BASE_URL, modelDir } = await import("./packages/core/src/lib/meaning.mjs");
  const key = process.env.MODEL || DEFAULT_MODEL;
  if (!MODELS[key]) { console.error(`unknown model ${key}`); process.exit(1); }
  console.log(key); console.log(modelDir(key)); console.log(MODEL_BASE_URL.replace(/\/+$/, ""));
  for (const f of MODELS[key].files) console.log(`${f.path} ${f.sha256}`);
')
KEY=$(sed -n 1p <<<"$LIST"); DIR=$(sed -n 2p <<<"$LIST"); BASE=$(sed -n 3p <<<"$LIST")

echo "· model $KEY from $DIR → r2://$BUCKET/download/models/$KEY/"
while read -r path sha; do
  [ -f "$DIR/$path" ] || { echo "✗ $DIR/$path missing — run: node packages/core/src/meaning.mjs download --from-hf"; exit 1; }
  got=$(shasum -a 256 "$DIR/$path" | cut -d' ' -f1)
  [ "$got" = "$sha" ] || { echo "✗ $path checksum differs from MODELS — not uploading"; exit 1; }
done < <(tail -n +4 <<<"$LIST")

while read -r path _; do
  # Immutable: the model's files never change under the same key.
  aws s3 cp "$DIR/$path" "s3://$BUCKET/download/models/$KEY/$path" --endpoint-url "$ENDPOINT" \
    --cache-control "public,max-age=31536000,immutable" --only-show-errors
  echo "  ↑ $path"
done < <(tail -n +4 <<<"$LIST")

while read -r path _; do
  curl -fsI "$BASE/$KEY/$path" >/dev/null || { echo "✗ $BASE/$KEY/$path is not served yet"; exit 1; }
done < <(tail -n +4 <<<"$LIST")
echo "✓ model mirror serves every file of $KEY"
