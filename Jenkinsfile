pipeline {
    agent any

    environment {
        AWS_REGION           = 'us-east-1'
        AWS_DEFAULT_REGION   = "${AWS_REGION}"
        ECR_REPO_NAME        = 'hello-world-lambda'
        LAMBDA_FUNCTION_NAME = 'hello-world-lambda'
        API_NAME             = 'hello-world-api'
        // Named API_STAGE_NAME (not STAGE_NAME) because Jenkins Declarative
        // Pipeline auto-injects its own env.STAGE_NAME holding the current
        // stage's display name, which would otherwise shadow this value.
        API_STAGE_NAME       = 'prod'
        IMAGE_TAG            = "${env.BUILD_NUMBER}"
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
                        curl -sf -H "x-api-key: ${API_KEY_VALUE}" "${INVOKE_URL}"
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
            archiveArtifacts artifacts: 'lambda_output.env', allowEmptyArchive: true
        }
    }
}
