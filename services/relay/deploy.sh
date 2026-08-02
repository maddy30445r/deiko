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

# ── The bundle ──────────────────────────────────────────────────────────────
#
# Two files and no dependencies, so there is nothing to install and nothing to
# keep patched but the runtime itself.

ZIP="$(mktemp -d)/relay.zip"
( cd "$here" && zip -q "$ZIP" relay.mjs lambda.mjs )
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

# ── The function ────────────────────────────────────────────────────────────

ENV_VARS="Variables={SARVAM_API_KEY=$SARVAM_API_KEY,GROQ_API_KEY=$GROQ_API_KEY,FOVEA_REVOKED_TOKENS=${FOVEA_REVOKED_TOKENS:-}}"

if aws lambda get-function --function-name "$FUNCTION" --region "$REGION" >/dev/null 2>&1; then
  say "updating code"
  aws lambda update-function-code --function-name "$FUNCTION" --region "$REGION" \
    --zip-file "fileb://$ZIP" --query LastUpdateStatus --output text >/dev/null
  aws lambda wait function-updated --function-name "$FUNCTION" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FUNCTION" --region "$REGION" \
    --environment "$ENV_VARS" --timeout 60 --memory-size 512 \
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
    --environment "$ENV_VARS" --query FunctionArn --output text >/dev/null
  aws lambda wait function-active --function-name "$FUNCTION" --region "$REGION"
fi

aws lambda put-function-concurrency --function-name "$FUNCTION" --region "$REGION" \
  --reserved-concurrent-executions "$CONCURRENCY" --output text >/dev/null
say "reserved concurrency $CONCURRENCY"

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
  aws lambda add-permission --function-name "$FUNCTION" --region "$REGION" \
    --statement-id FunctionURLAllowPublicAccess --action lambda:InvokeFunctionUrl \
    --principal '*' --function-url-auth-type NONE >/dev/null
fi

URL="${URL%/}"
echo
echo "✓ $URL"
echo
echo "  verify — 'transcription' MUST be true, not just 'ok':"
echo "    curl -s $URL/health"
echo
echo "  then cut a release pointing at it:"
echo "    make release RELAY_URL=$URL"
