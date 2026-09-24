#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Deploy the relay to AWS Lambda behind a Function URL.
#
#   GROQ_API_KEY=… ./services/relay/deploy-aws.sh
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
# These names changed with the rename from Fovea to Deiko. A `fovea-relay`
# function and a `fovea-usage` table are still in the account, orphaned: this
# script creates the `deiko-*` pair on its first run rather than migrating,
# because the table held nothing but trial counters and there were no paying
# users. Delete the old pair once a deploy has succeeded.
#
# What a rename does NOT carry over is the Lambda's function URL — a new
# function gets a new one, and the old URL is stamped into every build already
# handed out. Restamp with `make bundle RELAY_URL=…` after deploying.
#
# Change the names here and in relay.mjs/quota.mjs/usage.mjs together or not
# at all. A PARTIAL rename is worse than either: the relay would read
# undefined and fall back to defaults, silently reopening the daily spend
# ceiling that DEIKO_GLOBAL_DAILY_SECONDS exists to hold shut.
FUNCTION="${DEIKO_LAMBDA_NAME:-deiko-relay}"
ROLE_NAME="${FUNCTION}-role"
# Caps how many transcriptions can run at once. Not a quota — a blast radius.
# The in-process rate limiter is per warm container and cannot bound spend on
# its own, so this is the lever that actually can.
CONCURRENCY="${DEIKO_LAMBDA_CONCURRENCY:-5}"

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
# request — the failure that looks healthy and is not. The classifier and the
# playground are part of the product too, so their keys are required as well.
: "${GROQ_API_KEY:?set GROQ_API_KEY (transcription AND summaries 503 without it)}"
: "${DEIKO_PLAYGROUND_SECRET:?set DEIKO_PLAYGROUND_SECRET (every /v1/playground route 503s without it)}"
if [ -z "${TYPESAFE_API_KEY:-}${AI_GATEWAY_API_KEY:-}${OPENROUTER_API_KEY:-}" ] \
  && { [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ] || [ -z "${CLOUDFLARE_AI_TOKEN:-}" ]; }; then
  echo "✗ no classifier key: set TYPESAFE_API_KEY, AI_GATEWAY_API_KEY or OPENROUTER_API_KEY,"
  echo "  or both CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_AI_TOKEN (/v1/classify 503s without one)"
  exit 1
fi

# LAUNCH STEP: `localhost` in DEIKO_PLAYGROUND_ORIGINS lets any page served from
# a visitor's own machine call the playground. It is there for testing the
# site locally; take it out of .env before the playground goes public.
case ",${DEIKO_PLAYGROUND_ORIGINS:-}," in
  *localhost*) say "⚠ DEIKO_PLAYGROUND_ORIGINS still allows localhost — remove it before launch" ;;
esac

# ── The usage table ─────────────────────────────────────────────────────────
#
# One table holds every stateful thing the relay knows: per-subject audio
# seconds, the cached Polar verdict, and the global daily total. See
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

TABLE="${DEIKO_USAGE_TABLE:-deiko-usage}"

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
# `npm ci` FROM THE RELAY'S OWN LOCKFILE, into a scratch directory. It used to
# install whatever `@aws-sdk/client-dynamodb` was newest on the day, so two
# deploys of the same commit could ship different SDKs, and neither was the one
# the tests had run against. `package-lock.json` here pins the SDK and every
# package under it to the versions in the repo's root lockfile — the ones
# `npm test` exercises. Scripts are not run: nothing in the tree needs one.
# Nothing is written into the repo, so a deploy cannot leave it dirty.

BUILD="$(mktemp -d)"
ZIP="$BUILD/relay.zip"
PKG="$BUILD/pkg"
mkdir -p "$PKG"
cp "$here"/relay.mjs "$here"/lambda.mjs "$here"/quota.mjs "$here"/usage.mjs \
  "$here"/package.json "$here"/package-lock.json "$PKG/"

say "installing @aws-sdk/client-dynamodb (locked)"
( cd "$PKG" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund >/dev/null 2>&1 ) \
  || { echo "✗ npm ci failed — the deploy needs network and a working npm"; exit 1; }

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
    // The classifier. Without the key /v1/classify 503s and the app renders
    // every brief without earlier work, which is the right default until a
    // TypeSafe account exists.
    "TYPESAFE_API_KEY",
    // Or the same model through a gateway. Vercel is free on the Hobby plan
    // and takes the TypeSafe request shape; Cloudflare wants a prepaid
    // balance. All optional; the first one set wins, in this order.
    // NO APOSTROPHES IN THIS BLOCK: it sits inside a single-quoted shell
    // string, and one ended the script mid-comment on a real deploy.
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
  # NEVER SHIP FEWER SETTINGS THAN ARE LIVE. `--environment` replaces the whole
  # set, so a shell that is missing one variable used to strip it from the
  # function and report success — a classifier key gone, a daily ceiling back
  # to its default. NAMES only: the values do reach the CLI process (`keys()`
  # is applied to the response it receives) but are never printed, stored or
  # handed to this script. Checked before anything is changed.
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
# The group is CREATED here first: it does not exist until the function has
# run once, so on a first deploy the retention call used to fail quietly and
# the group Lambda made later kept everything. `|| true` on the create because
# it already exists on every deploy after the first.
aws logs create-log-group --region "$REGION" \
  --log-group-name "/aws/lambda/$FUNCTION" >/dev/null 2>&1 || true
if aws logs put-retention-policy --region "$REGION" \
  --log-group-name "/aws/lambda/$FUNCTION" --retention-in-days 30 >/dev/null 2>&1; then
  say "log retention 30 days"
else
  say "⚠ could not set log retention on /aws/lambda/$FUNCTION — it keeps everything until fixed"
fi

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

# TWO STATEMENTS, AND BOTH OPEN THE URL ONLY. Since October 2025 a function
# URL with AuthType NONE needs `lambda:InvokeFunctionUrl` AND
# `lambda:InvokeFunction` in the resource policy — that, not a public-access
# block, is what "direct invoke 200, URL 403" on this account was. AWS's own
# policy for it scopes the second statement with `lambda:InvokedViaFunctionUrl`
# (docs.aws.amazon.com/lambda/latest/dg/urls-auth.html), and so does this.
#
# IT USED TO BE AN UNCONDITIONED InvokeFunction FOR *, which let any AWS
# account invoke the function directly — with a hand-built event whose
# `requestContext.http.sourceIp` is whatever it likes, walking straight past
# the per-address caps, or asynchronously, which Lambda retries for hours.
# That statement (`AllowPublicInvoke`) is removed on every deploy, AFTER its
# replacement is in place so the URL never goes a moment without a grant.
#
# The replacement is (re)written only when the live policy lacks it with its
# condition: removing and re-adding it every run would 403 the URL for that
# instant, and the app reads a 403 as "your token was revoked" for the rest
# of the session. Added WITHOUT `|| true`, so an AWS CLI too old to know
# `--invoked-via-function-url` stops the deploy while the old grant still
# stands. The first statement keeps its `|| true`: add-permission errors when
# a statement exists, which is the normal case on a redeploy.
#
# THE POLICY MUST BE READABLE. A deployer without `lambda:GetPolicy` used to
# read as "no policy", which re-added the grant (the 403 blink above) on
# every deploy and could verify nothing. Now "there is none" and "may not
# look" are told apart, and the second stops the deploy with the reason.
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
POLICY=$(policy) || { echo "  no grant was changed."; exit 1; }
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

# VERIFIED, NOT ASSUMED. The removal above swallows its errors — it fails on
# every deploy after the first, when there is nothing to remove — so what
# decides is the policy as it now stands: no statement may let anybody (`*`)
# invoke the function, by `lambda:InvokeFunction` or any wildcard that
# covers it, without the function-URL condition. Whatever put one there —
# this script before, the console, a hand-run add-permission — the deploy
# fails and names it.
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

# ── Verify the deploy, rather than asking the user to ──────────────────────
#
# A relay with no key answers ok:true happily and then 503s the route it
# cannot serve, so EVERY route's flag must be true — transcription, summary,
# classify and the playground — and so must `metering`. That one is a live
# DescribeTable from inside the function, which makes it the ONLY thing here
# that proves the table and the role's policy actually line up; both are
# created above, and both can be created wrong. Any flag false means a route
# that 503s by design, and the deploy FAILS rather than hand out that URL.
#
# Cold start plus IAM propagation can take a while on a fresh function, and the
# relay caches its DescribeTable answer for a minute — so a `false` seen while
# IAM propagates stands for up to sixty seconds. Retry for ninety.
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
