#!/usr/bin/env bash
# Creates the S3 bucket that holds tracking/reference data (the dummy Excel
# file the Lambda reads on every API call) and uploads that file to it.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
# S3 bucket names are globally unique and must be lowercase, so the account ID
# is appended to the human-friendly prefix instead of hardcoding a literal
# name that could collide with a bucket in someone else's AWS account.
S3_BUCKET_PREFIX="${S3_BUCKET_PREFIX:-enterprise-bucket}"
BUCKET_NAME="${S3_BUCKET_PREFIX}-${AWS_ACCOUNT_ID}"
S3_OBJECT_KEY="${S3_OBJECT_KEY:-dummy_data.xlsx}"
LOCAL_DATA_FILE="${LOCAL_DATA_FILE:-data/dummy_data.xlsx}"

# Every resource this pipeline creates is tagged AI=true so it can be found and torn down later.
TAG_KEY="AI"
TAG_VALUE="AI"

echo "==> Ensuring S3 bucket '${BUCKET_NAME}' exists"
if ! aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  if [ "${AWS_REGION}" == "us-east-1" ]; then
    aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${AWS_REGION}" >/dev/null
  else
    aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${AWS_REGION}" \
      --create-bucket-configuration LocationConstraint="${AWS_REGION}" >/dev/null
  fi
  aws s3api put-bucket-tagging --bucket "${BUCKET_NAME}" \
    --tagging "TagSet=[{Key=${TAG_KEY},Value=${TAG_VALUE}}]" --region "${AWS_REGION}"
fi

echo "==> Uploading ${LOCAL_DATA_FILE} to s3://${BUCKET_NAME}/${S3_OBJECT_KEY}"
aws s3 cp "${LOCAL_DATA_FILE}" "s3://${BUCKET_NAME}/${S3_OBJECT_KEY}" --region "${AWS_REGION}"

echo "S3 bucket ready: s3://${BUCKET_NAME}/${S3_OBJECT_KEY}"

{
  echo "S3_BUCKET_NAME=${BUCKET_NAME}"
  echo "S3_OBJECT_KEY=${S3_OBJECT_KEY}"
} > s3_output.env
