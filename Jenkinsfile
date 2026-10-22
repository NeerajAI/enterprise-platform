pipeline {
    agent any

    environment {
        AWS_REGION           = 'us-east-1'
        AWS_DEFAULT_REGION   = "${AWS_REGION}"
        ECR_REPO_NAME        = 'hello-world-lambda'
        LAMBDA_FUNCTION_NAME = 'hello-world-lambda'
        INFERENCE_ECR_REPO_NAME        = 'hello-world-inference-lambda'
        INFERENCE_LAMBDA_FUNCTION_NAME = 'hello-world-inference-lambda'
        RESULTS_PREFIX       = 'results/'
        // Queue between the orchestrator and inference Lambdas; its dead-letter
        // queue is named "<SQS_QUEUE_NAME>-dlq".
        SQS_QUEUE_NAME       = 'hello-world-jobs'
        API_NAME             = 'hello-world-api'
        // Named API_STAGE_NAME (not STAGE_NAME) because Jenkins Declarative
        // Pipeline auto-injects its own env.STAGE_NAME holding the current
        // stage's display name, which would otherwise shadow this value.
        API_STAGE_NAME       = 'prod'
        IMAGE_TAG            = "${env.BUILD_NUMBER}"
        // Bucket name is the prefix + AWS account ID (computed in the script) since
        // S3 bucket names must be globally unique and lowercase.
        S3_BUCKET_PREFIX     = 'enterprise-bucket'
        S3_OBJECT_KEY        = 'dummy_data.xlsx'
    }

    options {
        timestamps()
        disableConcurrentBuilds()
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        // Runs before Lambda so the bucket (and s3_output.env, which records its
        // name) exists in time for deploy_lambda.sh to wire up IAM + env vars.
        stage('Deploy S3 Bucket & Upload Data') {
            steps {
                withCredentials([usernamePassword(
                        credentialsId: 'aws-jenkins-creds',
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY')]) {
                    sh '''
                        chmod +x infra/deploy_s3.sh
                        ./infra/deploy_s3.sh
                    '''
                }
            }
        }

        // Runs before both Lambdas: the orchestrator needs the queue URL + send
        // permission, and the inference Lambda needs the queue ARN to be triggered
        // by it (both read sqs_output.env).
        stage('Deploy SQS Queues') {
            steps {
                withCredentials([usernamePassword(
                        credentialsId: 'aws-jenkins-creds',
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY')]) {
                    sh '''
                        chmod +x infra/deploy_sqs.sh
                        ./infra/deploy_sqs.sh
                    '''
                }
            }
        }

        // Runs before the orchestrator Lambda so the queue's consumer exists by the
        // time the orchestrator starts sending jobs to it.
        stage('Build & Deploy Inference Lambda') {
            steps {
                withCredentials([usernamePassword(
                        credentialsId: 'aws-jenkins-creds',
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY')]) {
                    sh '''
                        chmod +x infra/deploy_inference_lambda.sh
                        ./infra/deploy_inference_lambda.sh
                    '''
                }
            }
        }

        // Order matters: the Lambda function must exist before API Gateway can
        // point an integration at it.
        stage('Build & Deploy Lambda') {
            steps {
                withCredentials([usernamePassword(
                        credentialsId: 'aws-jenkins-creds',
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY')]) {
                    sh '''
                        chmod +x infra/deploy_lambda.sh
                        ./infra/deploy_lambda.sh
                    '''
                }
            }
        }

        stage('Deploy API Gateway') {
            steps {
                withCredentials([usernamePassword(
                        credentialsId: 'aws-jenkins-creds',
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY')]) {
                    sh '''
                        chmod +x infra/deploy_api_gateway.sh
                        STAGE_NAME="${API_STAGE_NAME}" ./infra/deploy_api_gateway.sh
                    '''
                }
            }
        }

        stage('Smoke Test') {
            steps {
                withCredentials([usernamePassword(
                        credentialsId: 'aws-jenkins-creds',
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY')]) {
                    sh '''
                        . ./lambda_output.env
                        API_KEY_VALUE=$(aws apigateway get-api-key --api-key "${API_KEY_ID}" --include-value --query value --output text --region "${AWS_REGION}")

                        # A freshly created API key / usage-plan link can take a while to
                        # propagate, so the first call(s) may 403 — retry with backoff instead
                        # of failing immediately.
                        START_RESPONSE=$(curl -X POST --retry 15 --retry-delay 5 --retry-all-errors -sf -H "x-api-key: ${API_KEY_VALUE}" "${INVOKE_URL}")
                        echo "Start response: ${START_RESPONSE}"
                        REQUEST_ID=$(echo "${START_RESPONSE}" | grep -oP "\\"request_id\\"\\s*:\\s*\\"\\K[^\\"]+" || true)
                        [ -n "${REQUEST_ID}" ] || { echo "No request_id in orchestrator response"; exit 1; }

                        # The orchestrator only kicks off the inference Lambda asynchronously,
                        # so poll for the result instead of expecting it in the first response.
                        # No -f here, and every step is guarded with `|| true`: Jenkins' sh step
                        # runs with set -e, so an unguarded failure on any single poll attempt
                        # (a transient non-2xx, or no match in the JSON yet) would kill this whole
                        # script instead of letting the loop retry.
                        for i in $(seq 1 60); do
                            RESULT=$(curl -s -H "x-api-key: ${API_KEY_VALUE}" "${INVOKE_URL}?request_id=${REQUEST_ID}" || true)
                            STATUS=$(echo "${RESULT}" | grep -oP "\\"status\\"\\s*:\\s*\\"\\K[^\\"]+" || true)
                            if [ "${STATUS}" = "done" ]; then
                                echo "Result: ${RESULT}"
                                exit 0
                            fi
                            sleep 5
                        done
                        echo "Inference Lambda did not finish in time"
                        exit 1
                    '''
                }
            }
        }
    }

    post {
        success {
            echo 'Pipeline finished: hello-world Lambda is live behind API Gateway.'
        }
        failure {
            echo 'Pipeline failed — check the stage logs above.'
        }
        always {
            archiveArtifacts artifacts: 'lambda_output.env, s3_output.env, sqs_output.env, inference_lambda_output.env', allowEmptyArchive: true
        }
    }
}
