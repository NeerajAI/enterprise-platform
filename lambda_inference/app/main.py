import io
import json
import logging
import os

import boto3
import openpyxl
from anthropic import AnthropicBedrockMantle

s3 = boto3.client("s3")
# Claude on Bedrock through the Anthropic SDK's "Mantle" client (the Messages API at
# bedrock-mantle.<region>.api.aws). Requests are SigV4-signed with this Lambda's
# execution-role credentials, so no API key is needed; the role needs
# bedrock-mantle:CreateInference (see infra/deploy_inference_lambda.sh).
# Generous timeout: the Lambda's own timeout (600s) is far larger than what a short
# summary needs, so allow the model time instead of failing early.
claude = AnthropicBedrockMantle(
    aws_region=os.environ["AWS_REGION"],
    default_headers={"anthropic-workspace-id": "default"},
    timeout=120,
)

BUCKET_NAME = os.environ["BUCKET_NAME"]
OBJECT_KEY = os.environ.get("OBJECT_KEY", "dummy_data.xlsx")
RESULTS_PREFIX = os.environ.get("RESULTS_PREFIX", "results/")
BEDROCK_MODEL_ID = os.environ["BEDROCK_MODEL_ID"]

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


def to_markdown_table(rows) -> str:
    headers = list(rows[0].keys())
    lines = ["| " + " | ".join(str(h) for h in headers) + " |", "| " + " | ".join("---" for _ in headers) + " |"]
    for row in rows:
        lines.append("| " + " | ".join(str(row.get(h, "")) for h in headers) + " |")
    return "\n".join(lines)


def summarize_table(rows) -> str:
    response = claude.messages.create(
        model=BEDROCK_MODEL_ID,
        max_tokens=300,
        system="You summarize tabular data for a technical audience. Be concise and factual.",
        messages=[{
            "role": "user",
            "content": "Summarize this table in 2-3 sentences, noting any patterns or notable values:\n\n" + to_markdown_table(rows),
        }],
    )
    return "".join(block.text for block in response.content if block.type == "text")


def process(request_id: str) -> None:
    log_stage(f"STAGE 6: inference Lambda triggered by SQS message, request_id={request_id}")

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

    # Runs after the result is already saved, and a failure here is logged rather
    # than raised: the summary is an extra, so a Bedrock hiccup (throttling, model
    # access not granted yet) must not fail the job, retry it, or re-invoke the
    # model up to maxReceiveCount times before the message lands in the DLQ.
    log_stage(f"STAGE 9: summarizing table with Bedrock model {BEDROCK_MODEL_ID}, request_id={request_id}")
    try:
        summary = summarize_table(dummy_data)
        logger.info("Bedrock summary of the table (request_id=%s):\n%s", request_id, summary)
        log_stage(f"STAGE 9 done: summary printed above, request_id={request_id}")
    except Exception:
        logger.exception("STAGE 9 failed: could not summarize the table with Bedrock, request_id=%s", request_id)


def handler(event, context):
    # Triggered by the SQS event source mapping (batch size 1), so there's no
    # caller waiting on this return value — the result is handed off via S3
    # instead, keyed by request_id for the orchestrator to poll.
    #
    # If anything raises, the message isn't deleted: it becomes visible again after
    # the queue's visibility timeout and is retried, and after maxReceiveCount
    # failed attempts SQS moves it to the dead-letter queue. Re-processing is safe
    # because the result is written to a key derived from request_id (idempotent).
    for record in event["Records"]:
        process(json.loads(record["body"])["request_id"])
