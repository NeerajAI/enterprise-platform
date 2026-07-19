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
      +-- Stage 1: Build & Deploy Lambda
      |       - build Docker image (lambda/Dockerfile)
      |       - push image to ECR
      |       - create/update Lambda function from that image
      |
      +-- Stage 2: Deploy API Gateway
      |       - create REST API + /hello GET route
      |       - Lambda proxy integration
      |       - require an API key on the route
      |       - attach a usage plan (throttling + quota, for tracking)
      |
      +-- Stage 3: Smoke Test
              - call the deployed endpoint with the API key, confirm "Hello World"
```

Order matters: the Lambda function must exist before API Gateway can create an
integration pointing at it, so the pipeline always deploys Lambda first.

## Repo layout

| Path | Purpose |
|---|---|
| `lambda/app/main.py` | FastAPI app with `GET /hello` → `{"message": "Hello World"}`, wrapped with [Mangum](https://github.com/jordaneremieff/mangum) so it runs on Lambda |
| `lambda/app/requirements.txt` | Python deps (`fastapi`, `mangum`) |
| `lambda/Dockerfile` | Lambda container image, based on `public.ecr.aws/lambda/python:3.12` |
| `infra/deploy_lambda.sh` | Builds the image, pushes to ECR, creates/updates the Lambda function and its execution role |
| `infra/deploy_api_gateway.sh` | Creates/updates the REST API, `/hello` route, API key, and usage plan |
| `Jenkinsfile` | Declarative pipeline wiring the above stages together |

## Branch strategy

- `main` — currently unused/empty
- `dev` — active development branch; the Jenkins job builds from here
- `QA`, `PROD` — promotion targets (currently only contain the README; not yet wired to their own Jenkins jobs)

## AWS resource tagging

Every AWS resource the scripts create (ECR repo, IAM role, Lambda function, REST
API, API key, usage plan) is tagged `AI: AI`. This makes it possible to find and
bulk-delete everything this pipeline provisioned, as opposed to resources created
by hand.

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
ID are written to `lambda_output.env` and archived as a build artifact.

## Status

- [x] GitHub repo created, `dev`/`QA`/`PROD` branches pushed
- [x] Jenkins installed and reachable on EC2, Docker + AWS CLI installed
- [x] `Enterprise-pipeline` job created and linked to this repo/branch
- [x] `aws-jenkins-creds` credential added
- [x] AWS resource tagging (`AI: AI`) added to both deploy scripts
- [ ] First successful end-to-end pipeline run (Lambda deploy stage was last
      seen running — build image push and Lambda creation in progress)
- [ ] Promote pipeline to `QA` / `PROD` branches
