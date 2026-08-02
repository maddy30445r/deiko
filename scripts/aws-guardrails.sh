#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Spend and error guardrails for the Fovea AWS account.
#
#   ./scripts/aws-guardrails.sh you@example.com
#
# Two things, because right now there are zero: an AWS Budget that emails at
# 80% of a monthly cap, and a CloudWatch alarm when the relay starts erroring.
# Without these, "watch the dashboard" is the entire spend control on an
# account whose keys fund the whole team — a runaway client or a leaked token
# would be discovered on the invoice.
#
# Idempotent, like deploy-aws.sh: run it again and it changes nothing that is
# already in place.
#
# The email arrives with a confirmation link (SNS requires it) — the alarm is
# not actually wired to your inbox until you click it.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

EMAIL="${1:?usage: aws-guardrails.sh <alert-email>}"
REGION="${AWS_REGION:-ap-south-1}"           # where fovea-relay lives
FUNCTION="${FOVEA_LAMBDA_NAME:-fovea-relay}"
# ₹500/month is the cap the owner chose. The budget is denominated in USD
# anyway because THIS ACCOUNT BILLS IN USD (checked via Cost Explorer) — an
# INR budget on a USD-billed account would compare rupees against dollars
# and alert at 88× the intended spend. $6 ≈ ₹500; adjust here if the rate
# drifts far enough to matter.
BUDGET_USD="${FOVEA_BUDGET_USD:-6}"
say() { printf '  %s\n' "$*"; }

command -v aws >/dev/null || { echo "✗ aws CLI not found"; exit 1; }
if ! ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo "✗ no AWS credentials. Run 'aws configure' first."
  exit 1
fi
say "account $ACCOUNT · alerts to $EMAIL"

# ── The budget ──────────────────────────────────────────────────────────────
#
# Account-wide, not per-service: the point is bounding the AWS bill, and a
# per-service budget would miss the surprise coming from a service nobody
# thought to budget. 80% actual = act now; 100% forecasted = act this week.
# Budgets carry their own email subscribers, so no SNS is needed here.

if aws budgets describe-budget --account-id "$ACCOUNT" --budget-name fovea \
     >/dev/null 2>&1; then
  say "budget 'fovea' already exists — leaving it alone"
else
  say "creating budget 'fovea' (\$$BUDGET_USD/month)"
  aws budgets create-budget --account-id "$ACCOUNT" \
    --budget "{
      \"BudgetName\": \"fovea\",
      \"BudgetLimit\": {\"Amount\": \"$BUDGET_USD\", \"Unit\": \"USD\"},
      \"TimeUnit\": \"MONTHLY\",
      \"BudgetType\": \"COST\"
    }" \
    --notifications-with-subscribers "[
      {
        \"Notification\": {\"NotificationType\": \"ACTUAL\",
          \"ComparisonOperator\": \"GREATER_THAN\", \"Threshold\": 80},
        \"Subscribers\": [{\"SubscriptionType\": \"EMAIL\", \"Address\": \"$EMAIL\"}]
      },
      {
        \"Notification\": {\"NotificationType\": \"FORECASTED\",
          \"ComparisonOperator\": \"GREATER_THAN\", \"Threshold\": 100},
        \"Subscribers\": [{\"SubscriptionType\": \"EMAIL\", \"Address\": \"$EMAIL\"}]
      }
    ]"
fi

# ── The error alarm ─────────────────────────────────────────────────────────
#
# Errors ≥ 5 in 5 minutes on the relay. Not latency, not invocation count:
# a burst of errors is the one signal that is never routine — a bad deploy,
# an expired provider key, or someone probing. SNS topic + email because
# CloudWatch alarms cannot email directly.

TOPIC_ARN=$(aws sns create-topic --name fovea-alerts --region "$REGION" \
  --query TopicArn --output text)   # returns the existing ARN if already there

# Re-running with an already-confirmed email is a no-op; with an unconfirmed
# one it just re-sends the confirmation.
aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email \
  --notification-endpoint "$EMAIL" --region "$REGION" \
  --query SubscriptionArn --output text >/dev/null
say "SNS topic fovea-alerts (confirm the subscription email if you have not)"

# put-metric-alarm is create-or-update by name, so this is naturally idempotent.
aws cloudwatch put-metric-alarm --region "$REGION" \
  --alarm-name "$FUNCTION-errors" \
  --alarm-description "The Fovea relay is failing requests" \
  --namespace AWS/Lambda --metric-name Errors \
  --dimensions "Name=FunctionName,Value=$FUNCTION" \
  --statistic Sum --period 300 --evaluation-periods 1 \
  --threshold 5 --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$TOPIC_ARN"
say "alarm $FUNCTION-errors (≥5 errors in 5 minutes)"

echo
echo "✓ guardrails in place — click the SNS confirmation link in $EMAIL"
