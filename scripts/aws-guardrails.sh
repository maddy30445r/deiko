#!/usr/bin/env bash
# Spend and error guardrails for the Deiko AWS account.
#
#   ./scripts/aws-guardrails.sh you@example.com
#
# Creates an AWS Budget that emails at 80% of a monthly cap and a CloudWatch
# alarm for relay errors. Idempotent: re-running changes nothing already in
# place.
#
# SNS sends a confirmation link; the alarm does not reach your inbox until you
# click it.
set -euo pipefail

EMAIL="${1:?usage: aws-guardrails.sh <alert-email>}"
# The address is pasted into the budget's JSON unescaped below, so a `"` in it
# (a display-name paste like `"Ops" <ops@x>`) would break the JSON and leave the
# account with no spend guardrail. Accept a plain address only.
case "$EMAIL" in
  *[!A-Za-z0-9._+@-]*|*@*@*) echo "✗ '$EMAIL' — a plain email address only"; exit 1 ;;
  *?@?*) ;;
  *) echo "✗ '$EMAIL' — a plain email address only"; exit 1 ;;
esac
REGION="${AWS_REGION:-ap-south-1}"           # where deiko-relay lives
FUNCTION="${DEIKO_LAMBDA_NAME:-deiko-relay}"
# Monthly budget cap for the alarm, in USD because the account bills in USD.
BUDGET_USD="${DEIKO_BUDGET_USD:-6}"
say() { printf '  %s\n' "$*"; }

command -v aws >/dev/null || { echo "✗ aws CLI not found"; exit 1; }
if ! ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo "✗ no AWS credentials. Run 'aws configure' first."
  exit 1
fi
say "account $ACCOUNT · alerts to $EMAIL"

# Budget: account-wide rather than per-service, so a surprise from an
# unbudgeted service is still caught. Budgets carry their own email
# subscribers, so no SNS is needed here.

if aws budgets describe-budget --account-id "$ACCOUNT" --budget-name deiko \
     >/dev/null 2>&1; then
  say "budget 'deiko' already exists — leaving it alone"
else
  say "creating budget 'deiko' (\$$BUDGET_USD/month)"
  aws budgets create-budget --account-id "$ACCOUNT" \
    --budget "{
      \"BudgetName\": \"deiko\",
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

# Error alarm: 5 or more errors in 5 minutes on the relay. A burst of errors is
# never routine (bad deploy, expired provider key, probing). CloudWatch alarms
# cannot email directly, so this goes through an SNS topic.

TOPIC_ARN=$(aws sns create-topic --name deiko-alerts --region "$REGION" \
  --query TopicArn --output text)   # returns the existing ARN if already there

# Re-running with an already-confirmed email is a no-op; with an unconfirmed
# one it just re-sends the confirmation.
aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email \
  --notification-endpoint "$EMAIL" --region "$REGION" \
  --query SubscriptionArn --output text >/dev/null
say "SNS topic deiko-alerts (confirm the subscription email if you have not)"

# put-metric-alarm is create-or-update by name, so this is naturally idempotent.
aws cloudwatch put-metric-alarm --region "$REGION" \
  --alarm-name "$FUNCTION-errors" \
  --alarm-description "The Deiko relay is failing requests" \
  --namespace AWS/Lambda --metric-name Errors \
  --dimensions "Name=FunctionName,Value=$FUNCTION" \
  --statistic Sum --period 300 --evaluation-periods 1 \
  --threshold 5 --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$TOPIC_ARN"
say "alarm $FUNCTION-errors (≥5 errors in 5 minutes)"

echo
echo "✓ guardrails in place — click the SNS confirmation link in $EMAIL"
