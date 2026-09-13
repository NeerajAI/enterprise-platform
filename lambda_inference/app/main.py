import io
import json
import logging
import os
import time

import boto3
import openpyxl

s3 = boto3.client("s3")

BUCKET_NAME = os.environ["BUCKET_NAME"]
OBJECT_KEY = os.environ.get("OBJECT_KEY", "dummy_data.xlsx")
RESULTS_PREFIX = os.environ.get("RESULTS_PREFIX", "results/")

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def log_stage(message: str, width: int = 80) -> None:
    text = f" {message} "
    dashes = max(width - len(text), 4)
    left = dashes // 2
    logger.info("-" * left + text + "-" * (dashes - left))


def read_dummy_data():
    obj = s3.get_object(Bucket=BUCKET_NAME, Key=OBJECT_KEY)
    # boto3's StreamingBody isn't seekable, but openpyxl (via zipfile) needs
    # random access to parse the .xlsx, so buffer it into memory first.
    workbook = openpyxl.load_workbook(io.BytesIO(obj["Body"].read()), read_only=True)
    sheet = workbook.active

    rows = list(sheet.iter_rows(values_only=True))
    header, data_rows = rows[0], rows[1:]
    return [dict(zip(header, row)) for row in data_rows]


def handler(event, context):
    # Invoked asynchronously (InvocationType="Event") by the orchestrator
    # Lambda, so there's no caller waiting on this return value — the result
    # is handed off via S3 instead, keyed by request_id for the orchestrator
    # to poll.
    request_id = event["request_id"]
    log_stage(f"STAGE 6: inference Lambda invoked asynchronously, request_id={request_id}")

    # TEMP: artificial delay to prove the orchestrator/inference split survives
    # work slower than API Gateway's 30s integration timeout. Remove once verified.
    time.sleep(120)

    log_stage(f"STAGE 7: reading dummy_data.xlsx from S3, request_id={request_id}")
    dummy_data = read_dummy_data()
    log_stage(f"STAGE 7 done: read {len(dummy_data)} rows from S3, request_id={request_id}")

    result = {
        "request_id": request_id,
        "status": "done",
        "message": "Hello World new test",
        "dummy_data": dummy_data,
    }

    log_stage(f"STAGE 8: writing result to S3, request_id={request_id}")
    s3.put_object(
        Bucket=BUCKET_NAME,
        Key=f"{RESULTS_PREFIX}{request_id}.json",
        Body=json.dumps(result).encode("utf-8"),
        ContentType="application/json",
    )
    log_stage(f"STAGE 8 done: result written to S3, request_id={request_id}")
