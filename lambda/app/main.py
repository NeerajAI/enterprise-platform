import json
import os
import uuid
from typing import Optional

import boto3
from botocore.exceptions import ClientError
from fastapi import FastAPI
from mangum import Mangum

app = FastAPI()

s3 = boto3.client("s3")
lambda_client = boto3.client("lambda")

BUCKET_NAME = os.environ["BUCKET_NAME"]
RESULTS_PREFIX = os.environ.get("RESULTS_PREFIX", "results/")
INFERENCE_LAMBDA_NAME = os.environ["INFERENCE_LAMBDA_NAME"]


def start_inference():
    request_id = str(uuid.uuid4())
    # Fire-and-forget: InvocationType="Event" returns as soon as the invoke is
    # accepted, without waiting for the inference Lambda to finish. That's what
    # keeps this orchestrator's own response time well under API Gateway's 30s
    # integration timeout, regardless of how long the actual work takes.
    lambda_client.invoke(
        FunctionName=INFERENCE_LAMBDA_NAME,
        InvocationType="Event",
        Payload=json.dumps({"request_id": request_id}).encode("utf-8"),
    )
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
            return {"request_id": request_id, "status": "processing"}
        raise
    return json.loads(obj["Body"].read())


@app.get("/hello")
def hello(request_id: Optional[str] = None):
    # No request_id yet: kick off a new inference job and hand back its id.
    if not request_id:
        new_request_id = start_inference()
        return {
            "message": "Hello World new test",
            "status": "processing",
            "request_id": new_request_id,
        }

    # request_id given: report whatever the inference Lambda has written so far.
    return get_result(request_id)


handler = Mangum(app)
