import json
import logging
import os
import uuid

import boto3
from botocore.exceptions import ClientError
from fastapi import FastAPI
from mangum import Mangum

app = FastAPI()

s3 = boto3.client("s3")
sqs = boto3.client("sqs")

BUCKET_NAME = os.environ["BUCKET_NAME"]
RESULTS_PREFIX = os.environ.get("RESULTS_PREFIX", "results/")
SQS_QUEUE_URL = os.environ["SQS_QUEUE_URL"]

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def log_stage(message: str, width: int = 80) -> None:
    text = f" {message} "
    dashes = max(width - len(text), 4)
    left = dashes // 2
    logger.info("-" * left + text + "-" * (dashes - left))


def start_inference():
    request_id = str(uuid.uuid4())
    log_stage(f"STAGE 2: orchestrator sending job to SQS queue, request_id={request_id}")
    # Fire-and-forget: send_message returns as soon as SQS accepts the message,
    # without waiting for the inference Lambda to pick it up or finish. That's what
    # keeps this orchestrator's own response time well under API Gateway's 30s
    # integration timeout, regardless of how long the actual work takes. The queue
    # also buffers/throttles the fan-out and moves jobs the inference Lambda keeps
    # failing on to a dead-letter queue instead of dropping them.
    sqs.send_message(
        QueueUrl=SQS_QUEUE_URL,
        MessageBody=json.dumps({"request_id": request_id}),
    )
    log_stage(f"STAGE 3: job queued in SQS, returning request_id={request_id} to caller")
    return request_id


def get_result(request_id: str):
    key = f"{RESULTS_PREFIX}{request_id}.json"
    try:
        obj = s3.get_object(Bucket=BUCKET_NAME, Key=key)
    except ClientError as e:
        # This role has s3:GetObject but not s3:ListBucket, so S3 reports a
        # missing key as 403 AccessDenied rather than 404 NoSuchKey (it won't
        # confirm non-existence to a principal that can't list the bucket).
        # Both mean the same thing here: the inference Lambda hasn't written
        # the result yet.
        if e.response["Error"]["Code"] in ("NoSuchKey", "AccessDenied"):
            log_stage(f"STAGE 5: result not ready yet, request_id={request_id}")
            return {"request_id": request_id, "status": "processing"}
        raise
    log_stage(f"STAGE 5: result found in S3, request_id={request_id}")
    return json.loads(obj["Body"].read())


@app.post("/hello")
def start_hello():
    # Creates a new inference job (side effect: invokes another Lambda, will
    # eventually write to S3) and isn't idempotent — every call spawns a new
    # request_id — so this is POST, not GET.
    log_stage("STAGE 1: API Gateway called orchestrator Lambda (start job)")
    new_request_id = start_inference()
    return {
        "message": "Hello World new test",
        "status": "processing",
        "request_id": new_request_id,
    }


@app.get("/hello")
def poll_hello(request_id: str):
    # Read-only, safe, idempotent, cacheable: GET fits.
    log_stage(f"STAGE 4: orchestrator polling S3 for result, request_id={request_id}")
    return get_result(request_id)


handler = Mangum(app)
