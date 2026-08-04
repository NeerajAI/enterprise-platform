#!/usr/bin/env bash
# Builds the Lambda container image, pushes it to ECR, and creates/updates the Lambda function.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REPO_NAME="${ECR_REPO_NAME:-hello-world-lambda}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FUNCTION_NAME="${LAMBDA_FUNCTION_NAME:-hello-world-lambda}"
ROLE_NAME="${LAMBDA_ROLE_NAME:-hello-world-lambda-role}"
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"

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

echo "==> Building Lambda image"
docker build --provenance=false --sbom=false -t "${ECR_REPO_NAME}:${IMAGE_TAG}" ./lambda
docker tag "${ECR_REPO_NAME}:${IMAGE_TAG}" "${ECR_URI}:${IMAGE_TAG}"

echo "==> Pushing image to ECR"
docker push "${ECR_URI}:${IMAGE_TAG}"

echo "==> Ensuring Lambda execution role exists"
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

echo "==> Creating or updating Lambda function '${FUNCTION_NAME}'"
if aws lambda get-function --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  aws lambda update-function-code \
    --function-name "${FUNCTION_NAME}" \
    --image-uri "${ECR_URI}:${IMAGE_TAG}" \
    --region "${AWS_REGION}" >/dev/null
  aws lambda wait function-updated --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}"
else
  aws lambda create-function \
    --function-name "${FUNCTION_NAME}" \
    --package-type Image \
    --code ImageUri="${ECR_URI}:${IMAGE_TAG}" \
    --role "${ROLE_ARN}" \
    --timeout 15 \
    --memory-size 256 \
    --tags "${TAG_KEY}=${TAG_VALUE}" \
    --region "${AWS_REGION}" >/dev/null
  aws lambda wait function-active --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}"
fi

LAMBDA_ARN="$(aws lambda get-function --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}" --query 'Configuration.FunctionArn' --output text)"
aws lambda tag-resource --resource "${LAMBDA_ARN}" --tags "${TAG_KEY}=${TAG_VALUE}" --region "${AWS_REGION}"
echo "Lambda deployed: ${LAMBDA_ARN}"

{
  echo "LAMBDA_FUNCTION_NAME=${FUNCTION_NAME}"
  echo "LAMBDA_FUNCTION_ARN=${LAMBDA_ARN}"
} > lambda_output.env
