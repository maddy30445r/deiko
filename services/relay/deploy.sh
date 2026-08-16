#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Deploy the relay to AWS Lambda behind a Function URL.
#
#   SARVAM_API_KEY=… GROQ_API_KEY=… ./services/relay/deploy-aws.sh
#
# Plain AWS CLI, no SAM/CDK/Terraform — the CLI is already installed, and a
# deploy step that first needs another toolchain is a deploy step that fails on
# the one machine nobody set up.
#
# IDEMPOTENT. Run it again to ship a code change; it creates what is missing and
# updates what is not. That matters more than it sounds: the alternative is a
# script you can only run once, which means the second deploy is done by hand
# and differs from the first in a way nobody wrote down.
#
# Lambda because this service is idle most of the day BY DESIGN — nobody is
# recording — and Lambda is the only option here that costs nothing while idle.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"        # Mumbai: closest to Sarvam
FUNCTION="${FOVEA_LAMBDA_NAME:-fovea-relay}"
ROLE_NAME="${FUNCTION}-role"
# Caps how many transcriptions can run at once. Not a quota — a blast radius.
# The in-process rate limiter is per warm container and cannot bound spend on
# its own, so this is the lever that actually can.
CONCURRENCY="${FOVEA_LAMBDA_CONCURRENCY:-5}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say() { printf '  %s\n' "$*"; }

# ── Preflight ───────────────────────────────────────────────────────────────

command -v aws >/dev/null || { echo "✗ aws CLI not found"; exit 1; }

if ! ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo "✗ no AWS credentials. Run 'aws configure' (or 'aws sso login') first."
  exit 1
fi
say "account $ACCOUNT · region $REGION"

# Refuse rather than deploy a relay that answers /health and 503s every real
# request — the failure that looks healthy and is not.
: "${SARVAM_API_KEY:?set SARVAM_API_KEY (transcription will 503 without it)}"
: "${GROQ_API_KEY:?set GROQ_API_KEY (summaries will 503 without it)}"

# ── The usage table ─────────────────────────────────────────────────────────
#
# One table holds every stateful thing the relay knows: per-subject audio
# seconds, the cached Lemon Squeezy verdict, and the global daily total. See
# services/relay/usage.mjs for the row shapes.
#
# PROVISIONED AT 25/25, WHICH IS EXACTLY THE ALWAYS-FREE TIER — 25 write units,
# 25 read units and 25GB, every month, permanently. On-demand is the obvious
# choice for spiky traffic and it is the wrong one here, because the free tier
# does not apply to it: an on-demand table bills from the first request.
#
# The bill either way is pennies — a session is usually ONE chunk, so two writes
# and a read — but pennies and zero are different numbers, and this costs one
# flag.
#
# 25 write units a second CANNOT BE EXHAUSTED BY THIS SERVICE. Reserved
# concurrency is 5, and each request writes twice, so the ceiling is about ten
# writes a second even if every invocation lands in the same second. The two
# limits are set in the same script; if you ever raise CONCURRENCY past ~12,
# raise this with it or writes will start throttling.
#
# TTL IS PART OF THE DESIGN, not housekeeping. Monthly rows carry an `expiresAt`
# and vanish on their own, so the billing period rolls over with no reset job to
# write, to schedule, or to discover has not run since March.

TABLE="${FOVEA_USAGE_TABLE:-fovea-usage}"

if ! aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" >/dev/null 2>&1; then
  say "creating table $TABLE (provisioned 25/25 — inside the always-free tier)"
  aws dynamodb create-table --table-name "$TABLE" --region "$REGION" \
    --attribute-definitions AttributeName=subject,AttributeType=S \
    --key-schema AttributeName=subject,KeyType=HASH \
    --provisioned-throughput ReadCapacityUnits=25,WriteCapacityUnits=25 >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
fi

# Idempotent: enabling TTL when it is already enabled on the same attribute is
# an error, so ask first. Deliberately not gated on table creation — a table
# made by an earlier version of this script has no TTL, and would silently keep
# every row forever.
TTL_STATUS=$(aws dynamodb describe-time-to-live --table-name "$TABLE" --region "$REGION" \
  --query TimeToLiveDescription.TimeToLiveStatus --output text 2>/dev/null || echo "DISABLED")
if [ "$TTL_STATUS" = "DISABLED" ]; then
  say "enabling TTL on expiresAt"
  aws dynamodb update-time-to-live --table-name "$TABLE" --region "$REGION" \
    --time-to-live-specification "Enabled=true,AttributeName=expiresAt" >/dev/null
fi

# ── The bundle ──────────────────────────────────────────────────────────────
#
# The relay's own code is three files with no dependencies. The DynamoDB client
# is the one exception and it is vendored in here rather than taken from the
# Lambda runtime: the runtime does ship an SDK, but AWS's own guidance is to
# bring your own so the version is yours rather than whatever the region
# happens to have. Hand-rolling SigV4 would have kept the zip dependency-free —
# tempting in a service with no other dependencies, and the wrong place to save,
# because a signing bug is a security bug and this is three API calls.
#
# `--omit=dev --no-package-lock` into a scratch directory: nothing is written
# into the repo, so a deploy cannot leave the working tree dirty.

BUILD="$(mktemp -d)"
ZIP="$BUILD/relay.zip"
PKG="$BUILD/pkg"
mkdir -p "$PKG"
cp "$here"/relay.mjs "$here"/lambda.mjs "$here"/quota.mjs "$here"/usage.mjs "$PKG/"

say "installing @aws-sdk/client-dynamodb"
( cd "$PKG" && npm install --silent --omit=dev --no-package-lock --no-audit --no-fund \
    @aws-sdk/client-dynamodb >/dev/null 2>&1 ) \
  || { echo "✗ npm install failed — the deploy needs network and a working npm"; exit 1; }

( cd "$PKG" && zip -qr "$ZIP" . )
say "bundle $(du -h "$ZIP" | cut -f1)"

# ── The execution role ──────────────────────────────────────────────────────

if ! ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text 2>/dev/null); then
  say "creating role $ROLE_NAME"
  ROLE_ARN=$(aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
    }' --query Role.Arn --output text)
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  # IAM is eventually consistent, and creating a function with a role that has
  # not propagated fails with a misleading "cannot be assumed" error.
  say "waiting for the role to propagate…"
  sleep 12
fi

# The usage table, scoped to that one table and those four actions.
#
# OUTSIDE the role-creation branch on purpose. A role made before metering
# existed already exists, so a policy attached only on creation would never
# reach it — the deploy would report success and every transcription would 503
# on AccessDenied. `put-role-policy` is idempotent, so running it every time is
# both the fix and the check.
#
# No `dynamodb:DeleteItem` and no `Scan`: rows expire by TTL and nothing here
# ever reads the table whole. A relay that cannot delete a usage row also
# cannot be talked into clearing somebody's quota.
say "attaching the usage-table policy"
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "${FUNCTION}-usage" \
  --policy-document "$(cat <<JSON
{"Version":"2012-10-17","Statement":[{
  "Effect":"Allow",
  "Action":["dynamodb:UpdateItem","dynamodb:GetItem","dynamodb:PutItem","dynamodb:DescribeTable"],
  "Resource":"arn:aws:dynamodb:$REGION:$ACCOUNT:table/$TABLE"
}]}
JSON
)"

# ── The function ────────────────────────────────────────────────────────────

# JSON IN A FILE, NOT SHORTHAND ON THE COMMAND LINE. Three reasons, and the
# first one is a bug this script actually had:
#
#   • `Variables={A=1,B=}` — a trailing EMPTY value — fails the shorthand
#     parser with "Expected: ',', received: 'EOF'". An unset revocation list is
#     the normal case, so the script broke on its very first run.
#   • an API key may contain a comma or an equals sign, either of which would
#     silently split the shorthand into the wrong pairs.
#   • a secret passed in argv is visible in `ps` to every process on the
#     machine, and gets echoed back verbatim by the CLI's own error messages.
#
# The file is created with a private umask and removed on exit.
ENV_FILE="$(mktemp)"
trap 'rm -f "$ENV_FILE"' EXIT
chmod 600 "$ENV_FILE"
FOVEA_USAGE_TABLE="$TABLE" node -e '
  const vars = {
    SARVAM_API_KEY: process.env.SARVAM_API_KEY,
    GROQ_API_KEY: process.env.GROQ_API_KEY,
    FOVEA_USAGE_TABLE: process.env.FOVEA_USAGE_TABLE,
  };
  // Omitted entirely when empty rather than sent as "" — Lambda would store a
  // variable that exists and means nothing.
  for (const name of [
    "FOVEA_REVOKED_TOKENS",
    // The daily ceiling and the Lemon Squeezy wiring all have working defaults
    // in code, so each is passed only when it has been chosen deliberately.
    "FOVEA_GLOBAL_DAILY_SECONDS",
    "FOVEA_PRO_VARIANT_IDS",
    "LEMONSQUEEZY_API_KEY",
  ]) {
    if (process.env[name]) vars[name] = process.env[name];
  }
  process.stdout.write(JSON.stringify({ Variables: vars }));
' > "$ENV_FILE"

if aws lambda get-function --function-name "$FUNCTION" --region "$REGION" >/dev/null 2>&1; then
  say "updating code"
  aws lambda update-function-code --function-name "$FUNCTION" --region "$REGION" \
    --zip-file "fileb://$ZIP" --query LastUpdateStatus --output text >/dev/null
  aws lambda wait function-updated --function-name "$FUNCTION" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FUNCTION" --region "$REGION" \
    --environment "file://$ENV_FILE" --timeout 60 --memory-size 512 \
    --query LastUpdateStatus --output text >/dev/null
  aws lambda wait function-updated --function-name "$FUNCTION" --region "$REGION"
else
  say "creating function $FUNCTION"
  # 60s timeout: Sarvam on a 25s chunk takes ~1-2s, but a cold provider or a
  # retry must not be cut off mid-flight — the client's own fallback is worse
  # than waiting. 512MB is for headroom on the buffered body, not for CPU;
  # Lambda scales CPU with memory and the work here is almost all I/O wait.
  aws lambda create-function --function-name "$FUNCTION" --region "$REGION" \
    --runtime nodejs22.x --role "$ROLE_ARN" --handler lambda.handler \
    --zip-file "fileb://$ZIP" --timeout 60 --memory-size 512 \
    --environment "file://$ENV_FILE" --query FunctionArn --output text >/dev/null
  aws lambda wait function-active --function-name "$FUNCTION" --region "$REGION"
fi

# Log retention. Lambda creates the group on first invocation and leaves it on
# "Never expire", so without this every status line the relay has ever written
# is kept and billed forever. Thirty days outlives any support conversation.
# `|| true` because the group does not exist until the function has run once —
# the next deploy sets it, and nothing depends on it having worked today.
aws logs put-retention-policy --region "$REGION" \
  --log-group-name "/aws/lambda/$FUNCTION" --retention-in-days 30 >/dev/null 2>&1 \
  && say "log retention 30 days" || true

# BEST-EFFORT, deliberately. Reserving concurrency requires the account to
# keep 10 slots unreserved, and a fresh AWS account's TOTAL limit is often
# exactly 10 — so any reservation at all is arithmetically impossible there.
# On such an account the account-wide cap is already doing the blast-radius
# job this reservation exists for, so failing the whole deploy over it would
# refuse a protection the account cannot hold in exchange for one it already
# has. On bigger accounts the reservation still lands.
if aws lambda put-function-concurrency --function-name "$FUNCTION" --region "$REGION" \
  --reserved-concurrent-executions "$CONCURRENCY" --output text >/dev/null 2>&1; then
  say "reserved concurrency $CONCURRENCY"
else
  ACCOUNT_LIMIT=$(aws lambda get-account-settings --region "$REGION" \
    --query AccountLimit.ConcurrentExecutions --output text 2>/dev/null || echo "?")
  say "⚠ could not reserve concurrency (account limit: $ACCOUNT_LIMIT, and AWS keeps 10 unreserved)"
  say "  the account-wide limit of $ACCOUNT_LIMIT is the effective cap instead"
fi

# ── The URL ─────────────────────────────────────────────────────────────────
#
# AuthType NONE with our own bearer check inside. IAM auth would mean signing
# every request from the app, which would mean AWS credentials on every user's
# Mac — a far worse trade than a token that gates a proxy.

if ! URL=$(aws lambda get-function-url-config --function-name "$FUNCTION" --region "$REGION" \
      --query FunctionUrl --output text 2>/dev/null); then
  say "creating function URL"
  URL=$(aws lambda create-function-url-config --function-name "$FUNCTION" --region "$REGION" \
    --auth-type NONE --query FunctionUrl --output text)
fi

# BOTH permission statements, ensured on every run rather than only when the
# URL is first created — and the second one is the hard-won part.
#
# The textbook policy (`lambda:InvokeFunctionUrl`, principal *, AuthType NONE)
# is NOT sufficient on recent AWS accounts: they ship with Lambda's public
# access block enabled, which rejects URL-based public grants and returns
# Forbidden with a perfectly correct-looking policy in place. A plain
# `lambda:InvokeFunction` for * is what actually opens the door. Diagnosed on
# this very account: direct invoke 200, URL 403, until this statement landed.
#
# That grant also makes DIRECT invoke public, which sounds broader than the
# URL — but is not, for this service: the only guard either way is the bearer
# check inside the handler, so a caller crafting a direct-invoke event gets
# exactly what a caller of the public URL gets. `|| true` because
# add-permission errors when the statement already exists, which is the normal
# case on a redeploy.
aws lambda add-permission --function-name "$FUNCTION" --region "$REGION" \
  --statement-id FunctionURLAllowPublicAccess --action lambda:InvokeFunctionUrl \
  --principal '*' --function-url-auth-type NONE >/dev/null 2>&1 || true
aws lambda add-permission --function-name "$FUNCTION" --region "$REGION" \
  --statement-id AllowPublicInvoke --action lambda:InvokeFunction \
  --principal '*' >/dev/null 2>&1 || true

URL="${URL%/}"

# ── Verify the deploy, rather than asking the user to ──────────────────────
#
# A relay with no key answers ok:true happily and then 503s every real
# request, so `transcription` is the field that matters — and since metering
# exists, so is `metering`. That one is a live DescribeTable from inside the
# function, which makes it the ONLY thing here that proves the table and the
# role's policy actually line up; both are created above, and both can be
# created wrong. A relay reporting metering:false 503s every transcription by
# design, so shipping past it would hand out a URL that cannot work.
#
# Cold start plus IAM propagation can take a few seconds on a fresh function;
# retry briefly before declaring failure.
say "verifying /health…"
HEALTH=""
healthy() {
  case "$1" in
    *'"transcription":true'*) case "$1" in *'"metering":true'*) return 0 ;; esac ;;
  esac
  return 1
}
for _ in 1 2 3 4 5 6; do
  HEALTH=$(curl -s --max-time 10 "$URL/health" 2>/dev/null) || HEALTH=""
  healthy "$HEALTH" && break
  sleep 5
done
if ! healthy "$HEALTH"; then
  echo
  echo "✗ deploy finished but /health is not fully healthy"
  echo "  got: ${HEALTH:-no response}"
  case "$HEALTH" in
    *'"transcription":false'*)
      echo "  transcription:false — the function has no SARVAM_API_KEY." ;;
    *'"metering":false'*)
      echo "  metering:false — the function cannot reach table '$TABLE'."
      echo "  Check the ${FUNCTION}-usage policy on role $ROLE_NAME, and that the"
      echo "  table exists in $REGION. IAM can also take a minute to propagate." ;;
  esac
  echo "  every real request would fail — fix before releasing."
  exit 1
fi

echo
echo "✓ $URL"
echo "  /health: $HEALTH"
echo
echo "  cut a release pointing at it:"
echo "    make release RELAY_URL=$URL"
