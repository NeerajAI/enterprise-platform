#!/usr/bin/env bash
# Builds the inference Lambda container image, pushes it to ECR, and creates/updates
# the Lambda function. This Lambda does the actual (potentially slow) work that the
# orchestrator Lambda used to do inline; it's triggered by messages on the SQS queue
# (via an event source mapping) so it isn't bound by API Gateway's 30s integration timeout.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REPO_NAME="${INFERENCE_ECR_REPO_NAME:-hello-world-inference-lambda}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FUNCTION_NAME="${INFERENCE_LAMBDA_FUNCTION_NAME:-hello-world-inference-lambda}"
ROLE_NAME="${INFERENCE_LAMBDA_ROLE_NAME:-hello-world-inference-lambda-role}"
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"
RESULTS_PREFIX="${RESULTS_PREFIX:-results/}"
RESERVED_CONCURRENCY="${INFERENCE_LAMBDA_RESERVED_CONCURRENCY:-10}"
# Keep in sync with the queue's visibility timeout (6x this), set in infra/deploy_sqs.sh.
LAMBDA_TIMEOUT="${INFERENCE_LAMBDA_TIMEOUT:-600}"
# Caps how many inference invocations the queue can run in parallel. Kept below the
# reserved concurrency so SQS doesn't over-poll, get throttled, and burn through a
# message's receive count (which would push it to the DLQ for no real failure).
SQS_MAX_CONCURRENCY="${INFERENCE_SQS_MAX_CONCURRENCY:-5}"

# Populated by infra/deploy_s3.sh (run earlier in the pipeline) so this script
# knows which bucket/object the Lambda should be wired up to read from / write results to.
if [ -f s3_output.env ]; then
  . ./s3_output.env
fi

# Populated by infra/deploy_sqs.sh (run earlier in the pipeline) so this script
# knows which queue should trigger the Lambda.
if [ -f sqs_output.env ]; then
  . ./sqs_output.env
fi

# Every resource this pipeline creates is tagged AI=true so it can be found and torn down later.
TAG_KEY="AI"
TAG_VALUE="AI"

echo "==> Ensuring ECR repo '${ECR_REPO_NAME}' exists"
aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "${ECR_REPO_NAME}" --region "${AWS_REGION}" \
       --tags "Key=${TAG_KEY},Value=${TAG_VALUE}" >/dev/null

echo "==> Logging in to ECR"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "==> Building inference Lambda image"
docker build --provenance=false --sbom=false -t "${ECR_REPO_NAME}:${IMAGE_TAG}" ./lambda_inference
docker tag "${ECR_REPO_NAME}:${IMAGE_TAG}" "${ECR_URI}:${IMAGE_TAG}"

echo "==> Pushing image to ECR"
docker push "${ECR_URI}:${IMAGE_TAG}"

echo "==> Ensuring inference Lambda execution role exists"
ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text 2>/dev/null || true)"
if [ -z "${ROLE_ARN}" ]; then
  ROLE_ARN="$(aws iam create-role --role-name "${ROLE_NAME}" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --tags "Key=${TAG_KEY},Value=${TAG_VALUE}" \
    --query 'Role.Arn' --output text)"
  aws iam attach-role-policy --role-name "${ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  echo "Waiting for IAM role propagation..."
  sleep 10
fi

if [ -n "${S3_BUCKET_NAME:-}" ]; then
  echo "==> Granting inference Lambda role read (source data) + write (results) access to s3://${S3_BUCKET_NAME}"
  aws iam put-role-policy --role-name "${ROLE_NAME}" \
    --policy-name "s3-read-write-${S3_BUCKET_NAME}" \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\"],\"Resource\":\"arn:aws:s3:::${S3_BUCKET_NAME}/*\"}]}"
fi

if [ -n "${SQS_QUEUE_ARN:-}" ]; then
  # Lambda validates these on event source mapping creation, so they have to be in
  # place before the mapping below.
  echo "==> Granting inference Lambda role permission to consume from '${SQS_QUEUE_NAME}'"
  aws iam put-role-policy --role-name "${ROLE_NAME}" \
    --policy-name "sqs-consume-${SQS_QUEUE_NAME}" \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"${SQS_QUEUE_ARN}\"}]}"
fi

LAMBDA_ENV_VARS="Variables={BUCKET_NAME=${S3_BUCKET_NAME:-},OBJECT_KEY=${S3_OBJECT_KEY:-dummy_data.xlsx},RESULTS_PREFIX=${RESULTS_PREFIX}}"

echo "==> Creating or updating inference Lambda function '${FUNCTION_NAME}'"
if aws lambda get-function --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  aws lambda update-function-code \
    --function-name "${FUNCTION_NAME}" \
    --image-uri "${ECR_URI}:${IMAGE_TAG}" \
    --region "${AWS_REGION}" >/dev/null
  aws lambda wait function-updated --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}"
  aws lambda update-function-configuration \
    --function-name "${FUNCTION_NAME}" \
    --environment "${LAMBDA_ENV_VARS}" \
    --timeout "${LAMBDA_TIMEOUT}" \
    --region "${AWS_REGION}" >/dev/null
  aws lambda wait function-updated --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}"
else
  aws lambda create-function \
    --function-name "${FUNCTION_NAME}" \
    --package-type Image \
    --code ImageUri="${ECR_URI}:${IMAGE_TAG}" \
    --role "${ROLE_ARN}" \
    --timeout "${LAMBDA_TIMEOUT}" \
    --memory-size 256 \
    --environment "${LAMBDA_ENV_VARS}" \
    --tags "${TAG_KEY}=${TAG_VALUE}" \
    --region "${AWS_REGION}" >/dev/null
  aws lambda wait function-active --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}"
fi

echo "==> Account Lambda concurrency limits (diagnostic, in case the reservation below is rejected):"
aws lambda get-account-settings --region "${AWS_REGION}" --query 'AccountLimit' --output json || true

# Best-effort: AWS requires >=10 executions to stay in the account's shared
# unreserved pool after any reservation, and some accounts (new/sandboxed)
# start with a total "Concurrent executions" quota as low as 10 -- on those,
# no positive reservation is possible until AWS approves a quota increase
# (Service Quotas -> Lambda -> Concurrent executions -> Request increase).
# Don't let that block the rest of the deploy; just warn.
echo "==> Capping reserved concurrency at ${RESERVED_CONCURRENCY} (bounds fan-out from the orchestrator, keeps a slice out of the account's shared pool)"
aws lambda put-function-concurrency \
  --function-name "${FUNCTION_NAME}" \
  --reserved-concurrent-executions "${RESERVED_CONCURRENCY}" \
  --region "${AWS_REGION}" >/dev/null \
  || echo "WARNING: could not set reserved concurrency (likely insufficient account-level Concurrent executions quota) -- continuing without it"

LAMBDA_ARN="$(aws lambda get-function --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}" --query 'Configuration.FunctionArn' --output text)"
aws lambda tag-resource --resource "${LAMBDA_ARN}" --tags "${TAG_KEY}=${TAG_VALUE}" --region "${AWS_REGION}"
echo "Inference Lambda deployed: ${LAMBDA_ARN}"

if [ -n "${SQS_QUEUE_ARN:-}" ]; then
  echo "==> Ensuring SQS trigger (event source mapping) '${SQS_QUEUE_NAME}' -> '${FUNCTION_NAME}'"
  MAPPING_UUID="$(aws lambda list-event-source-mappings --function-name "${FUNCTION_NAME}" \
    --event-source-arn "${SQS_QUEUE_ARN}" --region "${AWS_REGION}" \
    --query 'EventSourceMappings[0].UUID' --output text)"
  if [ -z "${MAPPING_UUID}" ] || [ "${MAPPING_UUID}" == "None" ]; then
    # A role policy attached moments ago can take a few seconds to propagate, and
    # Lambda rejects the mapping until it sees the SQS permissions, so retry.
    for attempt in 1 2 3 4 5 6; do
      if aws lambda create-event-source-mapping \
          --function-name "${FUNCTION_NAME}" \
          --event-source-arn "${SQS_QUEUE_ARN}" \
          --batch-size 1 \
          --scaling-config "MaximumConcurrency=${SQS_MAX_CONCURRENCY}" \
          --tags "${TAG_KEY}=${TAG_VALUE}" \
          --region "${AWS_REGION}" >/dev/null; then
        break
      fi
      if [ "${attempt}" -eq 6 ]; then
        echo "Could not create the SQS event source mapping" >&2
        exit 1
      fi
      echo "Event source mapping not accepted yet (attempt ${attempt}/6), waiting for IAM propagation..."
      sleep 10
    done
  else
    aws lambda update-event-source-mapping \
      --uuid "${MAPPING_UUID}" \
      --batch-size 1 \
      --scaling-config "MaximumConcurrency=${SQS_MAX_CONCURRENCY}" \
      --enabled \
      --region "${AWS_REGION}" >/dev/null
  fi
fi

{
  echo "INFERENCE_LAMBDA_FUNCTION_NAME=${FUNCTION_NAME}"
  echo "INFERENCE_LAMBDA_FUNCTION_ARN=${LAMBDA_ARN}"
  echo "RESULTS_PREFIX=${RESULTS_PREFIX}"
} > inference_lambda_output.env
