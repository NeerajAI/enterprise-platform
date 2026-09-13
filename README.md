# Enterprise Platform

A Jenkins CI/CD pipeline that builds a containerized "hello world" FastAPI service,
deploys it to AWS Lambda, and puts it behind API Gateway (with API-key auth and a
usage plan for tracking/throttling).

## Architecture

```
GitHub (this repo)
      |
      v
Jenkins (running on AWS EC2)
      |
      +-- Stage 1: Deploy S3 Bucket & Upload Data
      |       - create the tracking bucket (enterprise-bucket-<account-id>)
      |       - upload data/dummy_data.xlsx into it
      |
      +-- Stage 2: Build & Deploy Inference Lambda
      |       - build Docker image (lambda_inference/Dockerfile)
      |       - push image to ECR
      |       - grant the role s3:GetObject (source data) + s3:PutObject (results)
      |       - create/update the inference Lambda function
      |
      +-- Stage 3: Build & Deploy Lambda (orchestrator)
      |       - build Docker image (lambda/Dockerfile)
      |       - push image to ECR
      |       - grant the role s3:GetObject on the bucket + lambda:InvokeFunction
      |         on the inference Lambda
      |       - create/update the orchestrator Lambda function
      |
      +-- Stage 4: Deploy API Gateway
      |       - create REST API + /hello GET route
      |       - Lambda proxy integration (points at the orchestrator)
      |       - require an API key on the route
      |       - attach a usage plan (throttling + quota, for tracking)
      |
      +-- Stage 5: Smoke Test
              - call /hello, get back a request_id, poll /hello?request_id=...
                until the inference Lambda's result is ready, confirm it
                includes the "Hello World" message and the rows read from
                the Excel file in S3
```

Order matters: the S3 bucket must exist before either Lambda is deployed (so
its name/IAM policy can be wired in), the inference Lambda must exist before
the orchestrator (so the orchestrator's role can be granted `InvokeFunction`
on it), and the orchestrator must exist before API Gateway can create an
integration pointing at it.

### Two Lambdas: orchestrator + inference

API Gateway enforces a hard 30s integration timeout — if the backing Lambda
hasn't responded by then, it just returns a 504, no matter how long the
Lambda would eventually take. To stay safely under that regardless of how
slow the actual work gets, the work is split across two Lambdas:

- **`hello-world-lambda` (orchestrator)** — sits behind API Gateway. On
  `GET /hello` (no `request_id`), it generates a `request_id`, invokes the
  inference Lambda **asynchronously** (`InvocationType="Event"` — returns as
  soon as AWS accepts the invoke, without waiting for it to finish), and
  immediately replies `{"status": "processing", "request_id": ...}`. On
  `GET /hello?request_id=...`, it instead checks S3 for that request's result
  and returns it (or `{"status": "processing"}` if it isn't there yet).
- **`hello-world-inference-lambda` (inference)** — does the actual work that
  used to run inline: downloads `dummy_data.xlsx` from S3, reads its rows,
  and writes the result to `s3://<bucket>/results/<request_id>.json`. Nothing
  is waiting on its return value, so it's free to take as long as it needs
  (its own Lambda timeout is 60s, independent of API Gateway's 30s limit).

Callers therefore poll: call `/hello` to kick off a job, then call
`/hello?request_id=<id>` (see `test.py`) until `status` comes back `"done"`.

### Infrastructure as code — or lack thereof

There's no CloudFormation, SAM, CDK, or Terraform here. `infra/deploy_lambda.sh`,
`infra/deploy_inference_lambda.sh`, and `infra/deploy_api_gateway.sh` are plain
AWS CLI shell scripts that check whether each resource exists (`get-rest-apis`,
`get-function`, etc.) and create it if not — hand-rolled idempotency instead of
a declarative template engine managing state/diffs. Fine for a hello-world demo;
worth revisiting (e.g. SAM or CDK) if this grows into something with more
resources or environments.

## Repo layout

| Path | Purpose |
|---|---|
| `lambda/app/main.py` | Orchestrator: FastAPI app with `GET /hello` → starts an async inference job (or polls S3 for its result if given `request_id`), wrapped with [Mangum](https://github.com/jordaneremieff/mangum) so it runs on Lambda |
| `lambda/app/requirements.txt` | Orchestrator Python deps (`fastapi`, `mangum`, `boto3`) |
| `lambda/Dockerfile` | Orchestrator Lambda container image, based on `public.ecr.aws/lambda/python:3.12` |
| `lambda_inference/app/main.py` | Inference Lambda: plain `handler(event, context)` invoked asynchronously by the orchestrator — reads the Excel file from S3 and writes the result to `s3://<bucket>/results/<request_id>.json` |
| `lambda_inference/app/requirements.txt` | Inference Lambda Python deps (`boto3`, `openpyxl`) |
| `lambda_inference/Dockerfile` | Inference Lambda container image |
| `data/dummy_data.xlsx` | Dummy Excel data uploaded to S3 and read by the inference Lambda on each job |
| `infra/deploy_s3.sh` | Creates/updates the S3 tracking bucket and uploads `data/dummy_data.xlsx` to it |
| `infra/deploy_inference_lambda.sh` | Builds the inference image, pushes to ECR, creates/updates the inference Lambda function and its execution role (S3 read + write) |
| `infra/deploy_lambda.sh` | Builds the orchestrator image, pushes to ECR, creates/updates the orchestrator Lambda function and its execution role (S3 read + permission to invoke the inference Lambda) |
| `infra/deploy_api_gateway.sh` | Creates/updates the REST API, `/hello` route, API key, and usage plan |
| `Jenkinsfile` | Declarative pipeline wiring the above stages together |

## Branch strategy

- `main` — currently unused/empty
- `dev` — active development branch; the Jenkins job builds from here
- `QA`, `PROD` — promoted copies of `dev`'s pipeline code; not yet wired to their own Jenkins jobs (the `Enterprise-pipeline` job still builds from `dev`)

## AWS resource tagging

Every AWS resource the scripts create (S3 bucket, ECR repo, IAM role, Lambda
function, REST API, API key, usage plan) is tagged `AI: AI`. This makes it
possible to find and bulk-delete everything this pipeline provisioned, as
opposed to resources created by hand.

## Jenkins setup

Jenkins runs on an AWS EC2 instance. To reproduce this setup on a fresh box
(Ubuntu 24.04 in this case):

```bash
# Docker
sudo apt-get update
sudo apt-get install -y docker.io
sudo systemctl enable --now docker
sudo usermod -aG docker jenkins
sudo systemctl restart jenkins

# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
sudo apt-get install -y unzip
unzip /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install
```

(On Amazon Linux, swap the Docker install for `sudo dnf install -y docker`.)

### Job configuration

- Job name: `Enterprise-pipeline`
- Type: Pipeline
- Definition: **Pipeline script from SCM**
  - SCM: Git
  - Repository URL: `https://github.com/NeerajAI/enterprise-platform.git`
  - Branch specifier: `*/dev`
  - Script path: `Jenkinsfile`

### Required credential

The pipeline needs one Jenkins credential:

| Field | Value |
|---|---|
| Kind | Username with password |
| Username | AWS Access Key ID |
| Password | AWS Secret Access Key |
| ID | `aws-jenkins-creds` (must match exactly — referenced by the Jenkinsfile) |

The IAM user behind these keys needs permissions for ECR, Lambda, IAM (role
create/attach), and API Gateway.

Add it under **Manage Jenkins → Credentials → System → Global → Add Credentials**.

## Running the pipeline

From the job page, click **Build Now**. Progress and logs are visible under
**Console Output** for each build number. On success, the invoke URL and API key
ID are written to `lambda_output.env`, the inference Lambda's name/ARN to
`inference_lambda_output.env`, and both are archived as build artifacts.

## Status

- [x] GitHub repo created, `dev`/`QA`/`PROD` branches pushed
- [x] Jenkins installed and reachable on EC2, Docker + AWS CLI installed
- [x] `Enterprise-pipeline` job created and linked to this repo/branch
- [x] `aws-jenkins-creds` credential added
- [x] AWS resource tagging (`AI: AI`) added to both deploy scripts
- [x] First successful end-to-end pipeline run (build #7 — Checkout → Build &
      Deploy Lambda → Deploy API Gateway → Smoke Test all green)
- [x] Promoted pipeline code to `QA` / `PROD` branches
- [ ] S3 tracking bucket + dummy Excel read wired into the pipeline (not yet
      run — needs a pipeline build to confirm green end-to-end)

### S3 bucket naming

Requested name was `EnterpriseBucket`, but S3 bucket names must be lowercase
and globally unique across all AWS accounts, so the actual name is computed
as `enterprise-bucket-<aws-account-id>` (see `infra/deploy_s3.sh`).

Live endpoint (from the `dev` build): `https://pi0wh7lzll.execute-api.us-east-1.amazonaws.com/prod/hello`
(requires an `x-api-key` header — see the API key created by `infra/deploy_api_gateway.sh`).

### Fixes that got the pipeline green

- **`STAGE_NAME` collision**: Jenkins Declarative Pipeline auto-injects
  `env.STAGE_NAME` with the *current stage's display name*, which silently
  shadowed our own `STAGE_NAME = 'prod'` and made `create-deployment` fail
  with `Stage name only allows a-zA-Z0-9_`. Fixed by renaming our variable to
  `API_STAGE_NAME` and passing it explicitly to the script as `STAGE_NAME`.
- **Smoke test flakiness**: a freshly created API key / usage-plan link can
  take a few seconds to propagate, so the very first request could 403.
  Fixed by adding `curl --retry 8 --retry-delay 3 --retry-all-errors` to the
  smoke test step.
- **Smoke test flakiness, round 2**: the 8x3s retry budget (~28s) wasn't
  always enough — one run exhausted every retry while the API key/usage-plan
  link was still propagating, even though the config was correct (confirmed
  by re-curling the same URL/key manually a few minutes later — 200 OK).
  Widened to `--retry 15 --retry-delay 5` (~75s of headroom).
