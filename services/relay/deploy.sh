#!/usr/bin/env bash
# Deploy the relay to AWS Lambda behind a Function URL.
#
#   GROQ_API_KEY=… ./services/relay/deploy.sh
#
# Plain AWS CLI, no SAM/CDK/Terraform. Idempotent: re-run it to ship a code
# change; it creates what is missing and updates the rest.
set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"        # Mumbai
# A new function gets a new function URL, so stamp it into the app after
# deploying a differently named function: `make bundle RELAY_URL=…`.
FUNCTION="${DEIKO_LAMBDA_NAME:-deiko-relay}"
ROLE_NAME="${FUNCTION}-role"
# Caps how many requests run at once: a blast-radius limit, not a quota. The
# in-process rate limiter is per warm container and cannot bound spend alone.
CONCURRENCY="${DEIKO_LAMBDA_CONCURRENCY:-5}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say() { printf '  %s\n' "$*"; }

# ── Preflight ──

command -v aws >/dev/null || { echo "✗ aws CLI not found"; exit 1; }

if ! ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo "✗ no AWS credentials. Run 'aws configure' (or 'aws sso login') first."
  exit 1
fi
say "account $ACCOUNT · region $REGION"

# Refuse to deploy a relay that answers /health but 503s every real request.
# The classifier and playground keys are required as well as Groq's.
: "${GROQ_API_KEY:?set GROQ_API_KEY (transcription AND summaries 503 without it)}"
: "${DEIKO_PLAYGROUND_SECRET:?set DEIKO_PLAYGROUND_SECRET (every /v1/playground route 503s without it)}"
if [ -z "${TYPESAFE_API_KEY:-}${AI_GATEWAY_API_KEY:-}${OPENROUTER_API_KEY:-}" ] \
  && { [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ] || [ -z "${CLOUDFLARE_AI_TOKEN:-}" ]; }; then
  echo "✗ no classifier key: set TYPESAFE_API_KEY, AI_GATEWAY_API_KEY or OPENROUTER_API_KEY,"
  echo "  or both CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_AI_TOKEN (/v1/classify 503s without one)"
  exit 1
fi

# `localhost` in DEIKO_PLAYGROUND_ORIGINS lets any page served from a visitor's
# own machine call the playground; it is only for testing the site locally.
case ",${DEIKO_PLAYGROUND_ORIGINS:-}," in
  *localhost*) say "⚠ DEIKO_PLAYGROUND_ORIGINS still allows localhost — remove it before launch" ;;
esac

# ── The usage table ──
#
# One table holds all of the relay's state: per-subject audio seconds, the
# cached Polar verdict, and the global daily total. See src/usage.mjs for the
# row shapes. The default name is mirrored there; change both.
#
# Provisioned at 25/25 rather than on-demand, to stay inside DynamoDB's
# always-free tier. Reserved concurrency (5) times two writes per request keeps
# the peak near ten writes a second; raise the capacity if CONCURRENCY goes
# past ~12.
#
# TTL is part of the design: monthly rows carry an `expiresAt` and expire on
# their own, so the billing period rolls over with no reset job.

TABLE="${DEIKO_USAGE_TABLE:-deiko-usage}"

if ! aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" >/dev/null 2>&1; then
  say "creating table $TABLE (provisioned 25/25 — inside the always-free tier)"
  aws dynamodb create-table --table-name "$TABLE" --region "$REGION" \
    --attribute-definitions AttributeName=subject,AttributeType=S \
    --key-schema AttributeName=subject,KeyType=HASH \
    --provisioned-throughput ReadCapacityUnits=25,WriteCapacityUnits=25 >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
fi

# Enabling TTL when it is already enabled is an error, so ask first. Not gated
# on table creation: a table made without TTL would otherwise keep every row.
TTL_STATUS=$(aws dynamodb describe-time-to-live --table-name "$TABLE" --region "$REGION" \
  --query TimeToLiveDescription.TimeToLiveStatus --output text 2>/dev/null || echo "DISABLED")
if [ "$TTL_STATUS" = "DISABLED" ]; then
  say "enabling TTL on expiresAt"
  aws dynamodb update-time-to-live --table-name "$TABLE" --region "$REGION" \
    --time-to-live-specification "Enabled=true,AttributeName=expiresAt" >/dev/null
fi

# ── The bundle ──
#
# The relay's own code has no dependencies except the DynamoDB client, which is
# bundled rather than taken from the Lambda runtime so the SDK version is
# pinned. SigV4 is not hand-rolled: a signing bug is a security bug.
#
# `npm ci` runs from the relay's own lockfile in a scratch directory, so two
# deploys of the same commit ship the same SDK, matching the repo's root
# lockfile (the versions the tests run against). Install scripts are skipped and
# nothing is written into the repo.

BUILD="$(mktemp -d)"
ZIP="$BUILD/relay.zip"
PKG="$BUILD/pkg"
mkdir -p "$PKG"
cp "$here"/src/relay.mjs "$here"/src/lambda.mjs "$here"/src/quota.mjs "$here"/src/usage.mjs \
  "$here"/package.json "$here"/package-lock.json "$PKG/"

say "installing @aws-sdk/client-dynamodb (locked)"
( cd "$PKG" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund >/dev/null 2>&1 ) \
  || { echo "✗ npm ci failed — the deploy needs network and a working npm"; exit 1; }

( cd "$PKG" && zip -qr "$ZIP" . )
say "bundle $(du -h "$ZIP" | cut -f1)"

# ── The execution role ──

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

# The usage-table policy, scoped to that one table and those four actions.
#
# Outside the role-creation branch on purpose: a role that already exists would
# otherwise never get it. `put-role-policy` is idempotent.
#
# No `dynamodb:DeleteItem` and no `Scan`: rows expire by TTL and nothing reads
# the table whole. A relay that cannot delete a usage row cannot be talked into
# clearing somebody's quota.
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

# ── The function ──

# The environment goes in as JSON in a file, not CLI shorthand:
#   - a trailing empty value (`Variables={A=1,B=}`) fails the shorthand parser;
#   - a key containing a comma or equals sign would split into the wrong pairs;
#   - a secret in argv is visible in `ps` and echoed back in CLI error messages.
# The file is mode 600 and removed on exit.
ENV_FILE="$(mktemp)"
trap 'rm -f "$ENV_FILE"' EXIT
chmod 600 "$ENV_FILE"
DEIKO_USAGE_TABLE="$TABLE" node -e '
  const vars = {
    GROQ_API_KEY: process.env.GROQ_API_KEY,
    DEIKO_USAGE_TABLE: process.env.DEIKO_USAGE_TABLE,
  };
  // Omitted entirely when empty rather than sent as "" — Lambda would store a
  // variable that exists and means nothing.
  for (const name of [
    "DEIKO_REVOKED_TOKENS",
    // The daily ceiling and the Polar wiring all have working defaults
    // in code, so each is passed only when it has been chosen deliberately.
    "DEIKO_GLOBAL_DAILY_SECONDS",
    "DEIKO_SUMMARIES_PER_DAY",
    "DEIKO_SUMMARIES_PER_CALLER_PER_DAY",
    "DEIKO_CLASSIFIES_PER_CALLER_PER_DAY",
    "DEIKO_TEXT_CALLS_PER_IP_PER_DAY",
    // The classifier. Without a key /v1/classify 503s and briefs are filed locally.
    "TYPESAFE_API_KEY",
    // Or the same model through a gateway; the first one set wins, in this order.
    // No apostrophes in this block: it sits inside a single-quoted shell string.
    "AI_GATEWAY_API_KEY",
    "OPENROUTER_API_KEY",
    "CLOUDFLARE_ACCOUNT_ID",
    "CLOUDFLARE_AI_TOKEN",
    "DEIKO_CLASSIFIES_PER_DAY",
    "DEIKO_PRO_BENEFIT_IDS",
    "POLAR_API_BASE",
    // The playground. The secret is required (checked at the top): without it
    // every /v1/playground/* route 503s and the site demo is dead.
    "DEIKO_PLAYGROUND_SECRET",
    "DEIKO_PLAYGROUND_CLIPS_PER_DAY",
    "DEIKO_PLAYGROUND_INTENTS_PER_DAY",
    "DEIKO_PLAYGROUND_CLIPS_PER_TICKET",
    "DEIKO_PLAYGROUND_MAX_CLIP_BYTES",
    "DEIKO_PLAYGROUND_MODEL",
    "DEIKO_PLAYGROUND_ORIGINS",
    "DEIKO_PLAYGROUND_QUERIES_PER_TICKET",
    "DEIKO_PLAYGROUND_TICKETS_PER_IP_PER_DAY",
    "DEIKO_PLAYGROUND_TICKET_TTL_MS",
  ]) {
    if (process.env[name]) vars[name] = process.env[name];
  }
  process.stdout.write(JSON.stringify({ Variables: vars }));
' > "$ENV_FILE"

if aws lambda get-function --function-name "$FUNCTION" --region "$REGION" >/dev/null 2>&1; then
  # Never ship fewer settings than are live: `--environment` replaces the whole
  # set, so a shell missing one variable would strip it from the function
  # (a classifier key gone, a daily ceiling back to its default). Only names are
  # compared; values reach the CLI process but are never printed or stored.
  # Checked before anything is changed.
  LIVE_NAMES=$(aws lambda get-function-configuration --function-name "$FUNCTION" --region "$REGION" \
    --query 'keys(Environment.Variables || `{}`)' --output text)
  DROPPED=$(LIVE_NAMES="$LIVE_NAMES" node -e '
    const next = Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).Variables);
    const live = (process.env.LIVE_NAMES || "").split(/\s+/).filter((n) => n && n !== "None");
    process.stdout.write(live.filter((n) => !next.includes(n)).join(" "));
  ' "$ENV_FILE")
  if [ -n "$DROPPED" ] && [ -z "${DEIKO_ALLOW_ENV_DROP:-}" ]; then
    echo "✗ this deploy would remove settings the live relay has: $DROPPED"
    echo "  set them (in .env for make relay-deploy) and run again, or"
    echo "  DEIKO_ALLOW_ENV_DROP=1 to remove them on purpose. Nothing was changed."
    exit 1
  fi
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
  # 60s timeout so a cold provider or a retry is not cut off mid-flight. 512MB
  # is headroom for the buffered body, not CPU; the work is almost all I/O wait.
  aws lambda create-function --function-name "$FUNCTION" --region "$REGION" \
    --runtime nodejs22.x --role "$ROLE_ARN" --handler lambda.handler \
    --zip-file "fileb://$ZIP" --timeout 60 --memory-size 512 \
    --environment "file://$ENV_FILE" --query FunctionArn --output text >/dev/null
  aws lambda wait function-active --function-name "$FUNCTION" --region "$REGION"
fi

# Log retention. Lambda creates the log group on first invocation with "Never
# expire". The group is created here first because it does not exist until the
# function has run once; `|| true` because it exists on every later deploy.
aws logs create-log-group --region "$REGION" \
  --log-group-name "/aws/lambda/$FUNCTION" >/dev/null 2>&1 || true
if aws logs put-retention-policy --region "$REGION" \
  --log-group-name "/aws/lambda/$FUNCTION" --retention-in-days 30 >/dev/null 2>&1; then
  say "log retention 30 days"
else
  say "⚠ could not set log retention on /aws/lambda/$FUNCTION — it keeps everything until fixed"
fi

# Best-effort: reserving concurrency requires the account to keep 10 slots
# unreserved, and a fresh AWS account's total limit is often exactly 10, which
# makes any reservation impossible. There the account-wide cap already bounds
# the blast radius, so the deploy continues.
if aws lambda put-function-concurrency --function-name "$FUNCTION" --region "$REGION" \
  --reserved-concurrent-executions "$CONCURRENCY" --output text >/dev/null 2>&1; then
  say "reserved concurrency $CONCURRENCY"
else
  ACCOUNT_LIMIT=$(aws lambda get-account-settings --region "$REGION" \
    --query AccountLimit.ConcurrentExecutions --output text 2>/dev/null || echo "?")
  say "⚠ could not reserve concurrency (account limit: $ACCOUNT_LIMIT, and AWS keeps 10 unreserved)"
  say "  the account-wide limit of $ACCOUNT_LIMIT is the effective cap instead"
fi

# ── The URL ──
#
# AuthType NONE with a bearer check inside the relay. IAM auth would need AWS
# credentials on every user's Mac.

if ! URL=$(aws lambda get-function-url-config --function-name "$FUNCTION" --region "$REGION" \
      --query FunctionUrl --output text 2>/dev/null); then
  say "creating function URL"
  URL=$(aws lambda create-function-url-config --function-name "$FUNCTION" --region "$REGION" \
    --auth-type NONE --query FunctionUrl --output text)
fi

# Two resource-policy statements, both scoped to the URL: a function URL with
# AuthType NONE needs `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction`,
# and the second is conditioned on `lambda:InvokedViaFunctionUrl` (see
# docs.aws.amazon.com/lambda/latest/dg/urls-auth.html). An unconditioned
# InvokeFunction would let any AWS account invoke the function directly with a
# hand-built event, bypassing the per-address caps. The unconditioned statement
# (`AllowPublicInvoke`) is removed on every deploy, after its replacement is in
# place so the URL is never without a grant.
#
# The replacement is rewritten only when the live policy lacks it with its
# condition: removing and re-adding it every run would 403 the URL for that
# instant, and the app reads a 403 as a revoked token. It is added without
# `|| true` so an AWS CLI too old for `--invoked-via-function-url` stops the
# deploy. The first statement keeps `|| true` because add-permission errors when
# a statement already exists.
#
# The policy must be readable: `policy()` tells "there is none" apart from
# "may not look" (missing `lambda:GetPolicy`) and stops the deploy on the latter.
policy() {
  local err="$BUILD/get-policy.err" out
  if out=$(aws lambda get-policy --function-name "$FUNCTION" --region "$REGION" \
      --query Policy --output text 2>"$err"); then
    printf '%s' "$out"
  elif grep -q ResourceNotFoundException "$err"; then
    printf '{}'
  else
    echo "✗ could not read the function's resource policy:" >&2
    sed 's/^/    /' "$err" >&2
    echo "  the deployer needs lambda:GetPolicy so the invoke grant can be checked." >&2
    return 1
  fi
}
aws lambda add-permission --function-name "$FUNCTION" --region "$REGION" \
  --statement-id FunctionURLAllowPublicAccess --action lambda:InvokeFunctionUrl \
  --principal '*' --function-url-auth-type NONE >/dev/null 2>&1 || true
POLICY=$(policy) || { echo "  neither InvokeFunction grant was changed."; exit 1; }
if ! POLICY="$POLICY" node -e '
  const s = (JSON.parse(process.env.POLICY).Statement || [])
    .find((x) => x.Sid === "FunctionURLInvokeAllowPublicAccess");
  process.exit(String(s?.Condition?.Bool?.["lambda:InvokedViaFunctionUrl"]) === "true" ? 0 : 1);
'; then
  aws lambda remove-permission --function-name "$FUNCTION" --region "$REGION" \
    --statement-id FunctionURLInvokeAllowPublicAccess >/dev/null 2>&1 || true
  aws lambda add-permission --function-name "$FUNCTION" --region "$REGION" \
    --statement-id FunctionURLInvokeAllowPublicAccess --action lambda:InvokeFunction \
    --principal '*' --invoked-via-function-url >/dev/null
  say "function URL grant scoped to the URL"
fi
aws lambda remove-permission --function-name "$FUNCTION" --region "$REGION" \
  --statement-id AllowPublicInvoke >/dev/null 2>&1 || true

# Verify the result. The removal above swallows its errors (nothing to remove
# on most deploys), so what decides is the policy as it now stands: no statement
# may let anybody (`*`) invoke the function, by `lambda:InvokeFunction` or any
# wildcard covering it, without the function-URL condition. Whatever put one
# there, the deploy fails and names it.
POLICY=$(policy) || exit 1
OPEN=$(POLICY="$POLICY" node -e '
  const covers = (pattern) => new RegExp("^" + String(pattern)
    .replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$", "i")
    .test("lambda:InvokeFunction");
  const open = (JSON.parse(process.env.POLICY).Statement || []).filter((s) =>
    s.Effect === "Allow"
    && (s.Principal === "*" || [].concat(s.Principal?.AWS ?? []).includes("*"))
    && [].concat(s.Action ?? []).some(covers)
    && String(s.Condition?.Bool?.["lambda:InvokedViaFunctionUrl"]) !== "true");
  process.stdout.write(open.map((s) => s.Sid || "(unnamed)").join(" "));
')
if [ -n "$OPEN" ]; then
  echo "✗ anybody can still invoke $FUNCTION directly, past its URL: $OPEN"
  echo "  remove each with: aws lambda remove-permission --function-name $FUNCTION --region $REGION --statement-id <Sid>"
  exit 1
fi

URL="${URL%/}"

# ── Verify the deploy ──
#
# A relay with a missing key answers ok:true and then 503s the route it cannot
# serve, so every route flag (transcription, summary, classify, playground) and
# `metering` must be true. `metering` is a live DescribeTable from inside the
# function, the only check that the table and the role's policy line up. Any
# false flag fails the deploy.
#
# Cold start and IAM propagation can take a while, and the relay caches its
# DescribeTable answer for a minute, so retry for ninety seconds.
say "verifying /health…"
HEALTH=""
unhealthy() {  # the flags that are not true; nothing printed means healthy
  node -e '
    let h = {};
    try { h = JSON.parse(process.argv[1]); } catch {}
    const flags = ["transcription", "summary", "classify", "playground", "metering"];
    process.stdout.write(flags.filter((k) => h[k] !== true).join(" "));
  ' "$1"
}
for _ in $(seq 18); do
  HEALTH=$(curl -s --max-time 10 "$URL/health" 2>/dev/null) || HEALTH=""
  [ -z "$(unhealthy "$HEALTH")" ] && break
  sleep 5
done
MISSING=$(unhealthy "$HEALTH")
if [ -n "$MISSING" ]; then
  echo
  echo "✗ deploy finished but /health is not fully healthy"
  echo "  got: ${HEALTH:-no response}"
  for flag in $MISSING; do
    case "$flag" in
      transcription|summary)
        echo "  $flag:false — the function has no GROQ_API_KEY." ;;
      classify)
        echo "  classify:false — the function has no classifier key (TYPESAFE_API_KEY,"
        echo "  AI_GATEWAY_API_KEY, OPENROUTER_API_KEY, or the CLOUDFLARE pair)." ;;
      playground)
        echo "  playground:false — the function has no DEIKO_PLAYGROUND_SECRET." ;;
      metering)
        echo "  metering:false — the function cannot reach table '$TABLE'."
        echo "  Check the ${FUNCTION}-usage policy on role $ROLE_NAME, and that the"
        echo "  table exists in $REGION. IAM can also take a minute to propagate." ;;
    esac
  done
  echo "  some real requests would fail — fix before releasing."
  exit 1
fi

echo
echo "✓ $URL"
echo "  /health: $HEALTH"
echo
echo "  cut a release pointing at it:"
echo "    make release RELAY_URL=$URL"
