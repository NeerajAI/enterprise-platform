#!/usr/bin/env bash
# Creates the SQS queue that sits between the orchestrator and inference
# Lambdas (orchestrator -> queue -> inference), plus a dead-letter queue that
# captures messages the inference Lambda repeatedly fails to process.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
QUEUE_NAME="${SQS_QUEUE_NAME:-hello-world-jobs}"
DLQ_NAME="${QUEUE_NAME}-dlq"
# SQS recommends a visibility timeout of at least 6x the consumer Lambda's
# timeout, otherwise a still-running message can become visible again and get
# picked up a second time. Must match the timeout set in deploy_inference_lambda.sh.
INFERENCE_LAMBDA_TIMEOUT="${INFERENCE_LAMBDA_TIMEOUT:-600}"
VISIBILITY_TIMEOUT=$((INFERENCE_LAMBDA_TIMEOUT * 6))
MAX_RECEIVE_COUNT="${SQS_MAX_RECEIVE_COUNT:-5}"

# Every resource this pipeline creates is tagged AI=true so it can be found and torn down later.
TAG_KEY="AI"
TAG_VALUE="AI"

# Returns the queue URL, creating the queue (tagged) first if it doesn't exist yet.
ensure_queue() {
  local name="$1"
  local url
  url="$(aws sqs get-queue-url --queue-name "${name}" --region "${AWS_REGION}" --query 'QueueUrl' --output text 2>/dev/null || true)"
  if [ -z "${url}" ] || [ "${url}" == "None" ]; then
    url="$(aws sqs create-queue --queue-name "${name}" --region "${AWS_REGION}" \
      --tags "${TAG_KEY}=${TAG_VALUE}" --query 'QueueUrl' --output text)"
  fi
  echo "${url}"
}

queue_arn() {
  aws sqs get-queue-attributes --queue-url "$1" --attribute-names QueueArn \
    --region "${AWS_REGION}" --query 'Attributes.QueueArn' --output text
}

echo "==> Ensuring dead-letter queue '${DLQ_NAME}' exists"
DLQ_URL="$(ensure_queue "${DLQ_NAME}")"
DLQ_ARN="$(queue_arn "${DLQ_URL}")"
# Keep failed messages for the SQS maximum (14 days) so there's time to inspect them.
aws sqs set-queue-attributes --queue-url "${DLQ_URL}" --region "${AWS_REGION}" \
  --attributes MessageRetentionPeriod=1209600

echo "==> Ensuring queue '${QUEUE_NAME}' exists"
QUEUE_URL="$(ensure_queue "${QUEUE_NAME}")"
QUEUE_ARN="$(queue_arn "${QUEUE_URL}")"

# set-queue-attributes (rather than only passing attributes at create time) so
# re-running the pipeline also converges an existing queue to this config.
ATTRIBUTES_FILE="sqs_attributes.json"
cat > "${ATTRIBUTES_FILE}" <<EOF
{
  "VisibilityTimeout": "${VISIBILITY_TIMEOUT}",
  "RedrivePolicy": "{\"deadLetterTargetArn\":\"${DLQ_ARN}\",\"maxReceiveCount\":\"${MAX_RECEIVE_COUNT}\"}"
}
EOF
aws sqs set-queue-attributes --queue-url "${QUEUE_URL}" --region "${AWS_REGION}" \
  --attributes "file://${ATTRIBUTES_FILE}"
rm -f "${ATTRIBUTES_FILE}"

echo "SQS ready: ${QUEUE_URL} (visibility timeout ${VISIBILITY_TIMEOUT}s, DLQ after ${MAX_RECEIVE_COUNT} receives -> ${DLQ_NAME})"

{
  echo "SQS_QUEUE_NAME=${QUEUE_NAME}"
  echo "SQS_QUEUE_URL=${QUEUE_URL}"
  echo "SQS_QUEUE_ARN=${QUEUE_ARN}"
  echo "SQS_DLQ_URL=${DLQ_URL}"
  echo "SQS_DLQ_ARN=${DLQ_ARN}"
} > sqs_output.env
