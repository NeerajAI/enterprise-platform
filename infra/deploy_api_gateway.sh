#!/usr/bin/env bash
# Creates/updates an API Gateway REST API in front of the Lambda function,
# requiring an API key (authentication) and attaching a usage plan (tracking/throttling).
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
FUNCTION_NAME="${LAMBDA_FUNCTION_NAME:-hello-world-lambda}"
API_NAME="${API_NAME:-hello-world-api}"
STAGE_NAME="${STAGE_NAME:-prod}"
API_KEY_NAME="${API_KEY_NAME:-hello-world-client-key}"

# Every resource this pipeline creates is tagged AI=true so it can be found and torn down later.
TAG_KEY="AI"
TAG_VALUE="AI"

LAMBDA_ARN="$(aws lambda get-function --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}" --query 'Configuration.FunctionArn' --output text)"

echo "==> Ensuring REST API '${API_NAME}' exists"
API_ID="$(aws apigateway get-rest-apis --region "${AWS_REGION}" --query "items[?name=='${API_NAME}'].id | [0]" --output text)"
if [ -z "${API_ID}" ] || [ "${API_ID}" == "None" ]; then
  API_ID="$(aws apigateway create-rest-api --name "${API_NAME}" --region "${AWS_REGION}" \
    --tags "${TAG_KEY}=${TAG_VALUE}" --query 'id' --output text)"
fi

ROOT_ID="$(aws apigateway get-resources --rest-api-id "${API_ID}" --region "${AWS_REGION}" --query "items[?path=='/'].id | [0]" --output text)"

echo "==> Ensuring /hello resource exists"
RESOURCE_ID="$(aws apigateway get-resources --rest-api-id "${API_ID}" --region "${AWS_REGION}" --query "items[?pathPart=='hello'].id | [0]" --output text)"
if [ -z "${RESOURCE_ID}" ] || [ "${RESOURCE_ID}" == "None" ]; then
  RESOURCE_ID="$(aws apigateway create-resource --rest-api-id "${API_ID}" --parent-id "${ROOT_ID}" --path-part hello --region "${AWS_REGION}" --query 'id' --output text)"
fi

echo "==> Configuring GET /hello (API key required, Lambda proxy integration)"
aws apigateway put-method \
  --rest-api-id "${API_ID}" --resource-id "${RESOURCE_ID}" \
  --http-method GET --authorization-type NONE --api-key-required \
  --region "${AWS_REGION}" >/dev/null 2>&1 || true

aws apigateway put-integration \
  --rest-api-id "${API_ID}" --resource-id "${RESOURCE_ID}" \
  --http-method GET --type AWS_PROXY --integration-http-method POST \
  --uri "arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations" \
  --region "${AWS_REGION}" >/dev/null

echo "==> Granting API Gateway permission to invoke Lambda"
aws lambda add-permission \
  --function-name "${FUNCTION_NAME}" \
  --statement-id "apigateway-invoke-${API_ID}" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${AWS_REGION}:${AWS_ACCOUNT_ID}:${API_ID}/*/GET/hello" \
  --region "${AWS_REGION}" >/dev/null 2>&1 || true

echo "==> Deploying API stage '${STAGE_NAME}'"
aws apigateway create-deployment --rest-api-id "${API_ID}" --stage-name "${STAGE_NAME}" --region "${AWS_REGION}" >/dev/null

echo "==> Ensuring API key + usage plan (auth + per-client tracking)"
API_KEY_ID="$(aws apigateway get-api-keys --name-query "${API_KEY_NAME}" --region "${AWS_REGION}" --query 'items[0].id' --output text)"
if [ -z "${API_KEY_ID}" ] || [ "${API_KEY_ID}" == "None" ]; then
  API_KEY_ID="$(aws apigateway create-api-key --name "${API_KEY_NAME}" --enabled --region "${AWS_REGION}" \
    --tags "${TAG_KEY}=${TAG_VALUE}" --query 'id' --output text)"
fi

USAGE_PLAN_ID="$(aws apigateway get-usage-plans --region "${AWS_REGION}" --query "items[?name=='${API_NAME}-usage-plan'].id | [0]" --output text)"
if [ -z "${USAGE_PLAN_ID}" ] || [ "${USAGE_PLAN_ID}" == "None" ]; then
  USAGE_PLAN_ID="$(aws apigateway create-usage-plan \
    --name "${API_NAME}-usage-plan" \
    --api-stages "apiId=${API_ID},stage=${STAGE_NAME}" \
    --throttle burstLimit=10,rateLimit=5 \
    --quota limit=10000,period=MONTH \
    --tags "${TAG_KEY}=${TAG_VALUE}" \
    --region "${AWS_REGION}" --query 'id' --output text)"
fi

aws apigateway create-usage-plan-key \
  --usage-plan-id "${USAGE_PLAN_ID}" \
  --key-id "${API_KEY_ID}" \
  --key-type API_KEY \
  --region "${AWS_REGION}" >/dev/null 2>&1 || true

INVOKE_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com/${STAGE_NAME}/hello"
echo "API Gateway deployed. Invoke URL: ${INVOKE_URL}"

{
  echo "API_ID=${API_ID}"
  echo "API_KEY_ID=${API_KEY_ID}"
  echo "INVOKE_URL=${INVOKE_URL}"
} >> lambda_output.env
