#!/usr/bin/env python3
"""Smoke-test the deployed hello-world API (API Gateway -> Lambda).

Usage:
    python test.py
    python test.py --url https://<id>.execute-api.<region>.amazonaws.com/prod/hello --api-key-value <key>
    python test.py --api-key-id <id>   # fetches the value via boto3 (needs AWS creds)

With no arguments it reads INVOKE_URL / API_KEY_ID from lambda_output.env,
the artifact the Jenkins pipeline writes after a deploy.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))

ENV_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lambda_output.env")


def load_env_file(path):
    values = {}
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip()
    return values


def resolve_api_key_value(api_key_id, region):
    try:
        import boto3
    except ImportError:
        sys.exit(
            "No API key value provided and boto3 isn't installed to look it up.\n"
            "Either `pip install boto3` (with AWS credentials configured) or pass "
            "--api-key-value directly."
        )
    client = boto3.client("apigateway", region_name=region)
    return client.get_api_key(apiKey=api_key_id, includeValue=True)["value"]


def main():
    env = load_env_file(ENV_FILE)

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default=env.get("INVOKE_URL"), help="Full invoke URL to call")
    parser.add_argument("--api-key-id", default=env.get("API_KEY_ID"), help="API Gateway API key ID")
    parser.add_argument("--api-key-value", default=os.environ.get("API_KEY_VALUE"), help="API key value (skips boto3 lookup)")
    parser.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    args = parser.parse_args()

    if not args.url:
        sys.exit("No URL to test: pass --url or run this next to a lambda_output.env with INVOKE_URL set.")

    api_key_value = args.api_key_value
    if not api_key_value:
        if not args.api_key_id:
            sys.exit("No API key: pass --api-key-value, or --api-key-id (to look it up via boto3).")
        api_key_value = resolve_api_key_value(args.api_key_id, args.region)

    request = urllib.request.Request(args.url, headers={"x-api-key": api_key_value})

    print(f"GET {args.url}")
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            status = response.status
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        status = e.code
        body = e.read().decode("utf-8")

    print(f"Status: {status}")
    print(f"Body:   {body}")

    try:
        payload = json.loads(body)
    except ValueError:
        payload = None

    if status == 200 and payload == {"message": "Hello World"}:
        print("PASS")
        sys.exit(0)

    print("FAIL")
    sys.exit(1)


if __name__ == "__main__":
    main()
