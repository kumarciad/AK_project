pipeline {
    agent any

    options {
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 60, unit: 'MINUTES')
        timestamps()
        ansiColor('xterm')
    }

    environment {
        APP_NAME               = 'AK_project'
        ECR_REPO_NAME          = 'ak-project'
        ENVIRONMENT_NAME       = "${params.ENVIRONMENT_NAME}"
        AWS_DEFAULT_REGION     = "${params.AWS_REGION}"
        AWS_ACCOUNT            = "${params.AWS_ACCOUNT}"
        DEPLOY_TARGET          = "${params.DEPLOY_TARGET}"
        IMAGE_TAG              = "${BUILD_NUMBER}-${GIT_COMMIT.take(7)}"
        ECR_URI                = "${params.AWS_ACCOUNT}.dkr.ecr.${params.AWS_REGION}.amazonaws.com/ak-project"
        CFN_STACK_NAME         = "ak-project-${params.ENVIRONMENT_NAME}-infra"
    }

    parameters {
        string(
            name: 'AWS_REGION',
            defaultValue: 'us-east-1',
            description: 'AWS region for all resources (e.g., us-east-1, eu-west-1)'
        )
        string(
            name: 'AWS_ACCOUNT',
            defaultValue: '123456789012',
            description: 'Your 12-digit AWS Account ID'
        )
        string(
            name: 'ENVIRONMENT_NAME',
            defaultValue: 'ak-project-prod',
            description: 'Environment prefix (matches CloudFormation stack. e.g., ak-project-prod)'
        )
        choice(
            name: 'DEPLOY_TARGET',
            choices: ['ECS_FARGATE', 'ELASTIC_BEANSTALK', 'PACKAGE_ONLY'],
            description: 'Where to deploy the containerized app'
        )
        booleanParam(
            name: 'APPLY_CLOUDFORMATION',
            defaultValue: false,
            description: '☑ Apply the aws_infra_cfn.yaml CloudFormation template to create/update VPC+RDS+ECS infra'
        )
        string(
            name: 'CFN_DB_USER',
            defaultValue: 'akadmin',
            description: '[if APPLY_CLOUDFORMATION=true] New RDS Postgres master username'
        )
        password(
            name: 'CFN_DB_PASSWORD',
            defaultValue: '',
            description: '[if APPLY_CLOUDFORMATION=true] New RDS Postgres master password (min 12 chars)'
        )
        string(
            name: 'CFN_DB_NAME',
            defaultValue: 'akprojectdb',
            description: '[if APPLY_CLOUDFORMATION=true] New RDS Postgres DB name'
        )
        password(
            name: 'CFN_FLASK_SECRET',
            defaultValue: '',
            description: '[if APPLY_CLOUDFORMATION=true] Flask SECRET_KEY (random long string, min 16 chars)'
        )
        string(
            name: 'BEANSTALK_APP_NAME',
            defaultValue: 'AK-Project',
            description: '[DEPLOY_TARGET=ELASTIC_BEANSTALK] Elastic Beanstalk Application name'
        )
        string(
            name: 'BEANSTALK_ENV_NAME',
            defaultValue: 'AK-Project-env',
            description: '[DEPLOY_TARGET=ELASTIC_BEANSTALK] Elastic Beanstalk Environment name'
        )
    }

    stages {
        stage('Checkout SCM') {
            steps {
                echo '▶ Checking out source from Git...'
                checkout scm
                sh "echo \"Build #${BUILD_NUMBER} commit ${GIT_COMMIT.take(7)} tag=${IMAGE_TAG}\""
            }
        }

        stage('Python Syntax & Unit Tests') {
            agent {
                docker { image 'python:3.12-slim' }
            }
            steps {
                sh '''
                    set -e
                    python -m venv .venv
                    . .venv/bin/activate
                    pip install --quiet --upgrade pip
                    pip install --quiet -r requirements.txt

                    echo "▶ Syntax validation..."
                    python -m py_compile app.py wsgi.py && echo "  OK"

                    echo "▶ Smoke testing Flask app..."
                    python - <<'PY'
from app import app, db
with app.app_context():
    db.create_all()
c = app.test_client()
for path, expect in [('/login', 200), ('/register', 200), ('/home', 302)]:
    r = c.get(path)
    assert r.status_code == expect, f"{path}: expected {expect}, got {r.status_code}"
    print(f"  GET {path} → {r.status_code} OK")
r = c.post('/register', data={
    'username': 'jenkins_tester',
    'password': 'Test1234!'
}, follow_redirects=True)
assert b'account has been created' in r.data or b'Login' in r.data, "register flow broken"
print("  POST /register → OK")
print("All smoke tests PASSED")
PY
                '''
            }
        }

        stage('Build & Push Docker Image → ECR') {
            when {
                expression { return params.DEPLOY_TARGET != 'PACKAGE_ONLY' }
            }
            steps {
                withAWS(region: "${AWS_DEFAULT_REGION}", credentials: 'jenkins-aws-creds') {
                    sh '''
                        set -e

                        echo "▶ Authenticating Docker with ECR..."
                        aws ecr get-login-password --region ${AWS_DEFAULT_REGION} | \
                            docker login --username AWS --password-stdin ${ECR_URI}

                        echo "▶ Ensuring ECR repo exists..."
                        aws ecr describe-repositories --repository-names ${ECR_REPO_NAME} --region ${AWS_DEFAULT_REGION} \
                            >/dev/null 2>&1 || \
                            aws ecr create-repository \
                                --repository-name ${ECR_REPO_NAME} \
                                --region ${AWS_DEFAULT_REGION} \
                                --image-scanning-configuration scanOnPush=true

                        echo "▶ Building image ${ECR_URI}:${IMAGE_TAG} ..."
                        docker build --progress=plain -t ${ECR_URI}:${IMAGE_TAG} -t ${ECR_URI}:latest .

                        echo "▶ Pushing image to ECR..."
                        docker push ${ECR_URI}:${IMAGE_TAG}
                        docker push ${ECR_URI}:latest
                        echo "Pushed: ${ECR_URI}:${IMAGE_TAG}"
                    '''
                }
            }
        }

        stage('Apply CloudFormation (Infra)') {
            when {
                expression { return params.APPLY_CLOUDFORMATION == true }
            }
            steps {
                withAWS(region: "${AWS_DEFAULT_REGION}", credentials: 'jenkins-aws-creds') {
                    sh '''
                        set -e
                        echo "▶ Validating CloudFormation template..."
                        aws cloudformation validate-template \
                            --template-body file://aws_infra_cfn.yaml \
                            --region ${AWS_DEFAULT_REGION}

                        echo "▶ Creating/Updating stack ${CFN_STACK_NAME}..."
                        set +e
                        STACK_EXISTS=$(aws cloudformation describe-stacks \
                            --stack-name ${CFN_STACK_NAME} \
                            --region ${AWS_DEFAULT_REGION} 2>/dev/null && echo yes || echo no)
                        set -e

                        if [ "$STACK_EXISTS" = "yes" ]; then
                            ACTION=update
                            CMD="update-stack"
                        else
                            ACTION=create
                            CMD="create-stack"
                        fi

                        echo "  → Stack action: $ACTION"

                        aws cloudformation ${CMD} \
                            --stack-name ${CFN_STACK_NAME} \
                            --template-body file://aws_infra_cfn.yaml \
                            --capabilities CAPABILITY_NAMED_IAM CAPABILITY_IAM \
                            --parameters \
                                ParameterKey=EnvironmentName,ParameterValue="${ENVIRONMENT_NAME}" \
                                ParameterKey=DBUsername,ParameterValue="${CFN_DB_USER}" \
                                ParameterKey=DBPassword,ParameterValue="${CFN_DB_PASSWORD}" \
                                ParameterKey=DBName,ParameterValue="${CFN_DB_NAME}" \
                                ParameterKey=FlaskSecretKey,ParameterValue="${CFN_FLASK_SECRET}" \
                                ParameterKey=ContainerImage,ParameterValue="${ECR_URI}:${IMAGE_TAG}" \
                            --region ${AWS_DEFAULT_REGION} \
                            --no-disable-rollback || true

                        echo "▶ Waiting for stack operation to complete..."
                        if [ "$ACTION" = "create" ]; then
                            aws cloudformation wait stack-create-complete \
                                --stack-name ${CFN_STACK_NAME} --region ${AWS_DEFAULT_REGION}
                        else
                            set +e
                            aws cloudformation wait stack-update-complete \
                                --stack-name ${CFN_STACK_NAME} --region ${AWS_DEFAULT_REGION}
                            RC=$?
                            set -e
                            if [ $RC -ne 0 ]; then
                                echo "Update wait returned non-zero; checking for NoUpdates..."
                                STATUS=$(aws cloudformation describe-stacks --stack-name ${CFN_STACK_NAME} \
                                    --region ${AWS_DEFAULT_REGION} \
                                    --query Stacks[0].StackStatus --output text)
                                echo "  Stack status: $STATUS"
                                if [ "$STATUS" != "UPDATE_COMPLETE" ] && [ "$STATUS" != "CREATE_COMPLETE" ]; then
                                    exit 1
                                fi
                            fi
                        fi

                        echo "✅ Stack ${ACTION} complete!"
                        echo "▶ Stack outputs:"
                        aws cloudformation describe-stacks \
                            --stack-name ${CFN_STACK_NAME} \
                            --region ${AWS_DEFAULT_REGION} \
                            --query 'Stacks[0].Outputs[*].{Key:OutputKey,Val:OutputValue}' \
                            --output table
                    '''
                }
            }
        }

        stage('Deploy to ECS Fargate') {
            when {
                expression { return params.DEPLOY_TARGET == 'ECS_FARGATE' }
            }
            steps {
                withAWS(region: "${AWS_DEFAULT_REGION}", credentials: 'jenkins-aws-creds') {
                    sh '''
                        set -e

                        echo "▶ Looking up ECS cluster from CFN stack output..."
                        ECS_CLUSTER=$(aws cloudformation describe-stacks \
                            --stack-name ${CFN_STACK_NAME} \
                            --region ${AWS_DEFAULT_REGION} \
                            --query "Stacks[0].Outputs[?OutputKey=='ECSClusterName'].OutputValue" \
                            --output text)
                        echo "  ECS Cluster: $ECS_CLUSTER"

                        TG_ARN=$(aws cloudformation describe-stacks \
                            --stack-name ${CFN_STACK_NAME} \
                            --region ${AWS_DEFAULT_REGION} \
                            --query "Stacks[0].Outputs[?OutputKey=='ALBTargetGroupArn'].OutputValue" \
                            --output text)
                        echo "  TG ARN: $TG_ARN"

                        echo "▶ Populating ECS task definition template..."
                        sed -e "s|AWS_ACCOUNT|${AWS_ACCOUNT}|g" \
                            -e "s|AWS_REGION|${AWS_DEFAULT_REGION}|g" \
                            -e "s|AK_PROJECT_ENV|${ENVIRONMENT_NAME}|g" \
                            -e "s|IMAGE_TAG|${IMAGE_TAG}|g" \
                            ecs_task_definition.json > /tmp/ecs_task.json

                        echo "▶ Registering new ECS task definition..."
                        TASK_DEF_ARN=$(aws ecs register-task-definition \
                            --cli-input-json file:///tmp/ecs_task.json \
                            --region ${AWS_DEFAULT_REGION} \
                            --query 'taskDefinition.taskDefinitionArn' \
                            --output text)
                        echo "  → $TASK_DEF_ARN"

                        echo "▶ Updating ECS service (rolling deploy)..."
                        set +e
                        SVC_EXISTS=$(aws ecs describe-services \
                            --cluster "$ECS_CLUSTER" \
                            --services "${ENVIRONMENT_NAME}-flask-svc" \
                            --region ${AWS_DEFAULT_REGION} 2>/dev/null \
                            | jq -r '.services[0]?.status // "NONE"')
                        set -e
                        echo "  svc status: $SVC_EXISTS"

                        if [ "$SVC_EXISTS" = "ACTIVE" ] || [ "$SVC_EXISTS" = "DRAINING" ]; then
                            aws ecs update-service \
                                --cluster "$ECS_CLUSTER" \
                                --service "${ENVIRONMENT_NAME}-flask-svc" \
                                --task-definition "$TASK_DEF_ARN" \
                                --desired-count 2 \
                                --force-new-deployment \
                                --health-check-grace-period-seconds 120 \
                                --region ${AWS_DEFAULT_REGION}
                        else
                            echo "⚠ Service not found — assuming CloudFormation created it via stage above."
                        fi

                        echo "▶ Waiting for deployment to stabilize..."
                        sleep 10
                        DEPLOY_ID=$(aws ecs describe-services \
                            --cluster "$ECS_CLUSTER" \
                            --services "${ENVIRONMENT_NAME}-flask-svc" \
                            --region ${AWS_DEFAULT_REGION} \
                            --query 'services[0].deployments[?status==`PRIMARY`].id' --output text)
                        echo "  Primary deployment ID: $DEPLOY_ID"

                        for i in $(seq 1 60); do
                            DEPLOY_STATUS=$(aws ecs describe-services \
                                --cluster "$ECS_CLUSTER" \
                                --services "${ENVIRONMENT_NAME}-flask-svc" \
                                --region ${AWS_DEFAULT_REGION} \
                                --query "services[0].deployments[?id==\`$DEPLOY_ID\`].status" --output text)
                            RUNNING=$(aws ecs describe-services \
                                --cluster "$ECS_CLUSTER" \
                                --services "${ENVIRONMENT_NAME}-flask-svc" \
                                --region ${AWS_DEFAULT_REGION} \
                                --query "services[0].deployments[?id==\`$DEPLOY_ID\`].runningCount" --output text)
                            DESIRED=$(aws ecs describe-services \
                                --cluster "$ECS_CLUSTER" \
                                --services "${ENVIRONMENT_NAME}-flask-svc" \
                                --region ${AWS_DEFAULT_REGION} \
                                --query "services[0].deployments[?id==\`$DEPLOY_ID\`].desiredCount" --output text)
                            echo "  [$i/60] deployment=$DEPLOY_STATUS running=$RUNNING/$DESIRED"
                            if [ "$DEPLOY_STATUS" = "COMPLETED" ] && [ "$RUNNING" = "$DESIRED" ]; then
                                echo "✅ ECS deployment complete!"
                                break
                            fi
                            sleep 10
                        done

                        echo "▶ Target group health:"
                        aws elbv2 describe-target-health \
                            --target-group-arn "$TG_ARN" \
                            --region ${AWS_DEFAULT_REGION} \
                            --query 'TargetHealthDescriptions[*].{Id:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
                            --output table || true

                        ALB_URL=$(aws cloudformation describe-stacks \
                            --stack-name ${CFN_STACK_NAME} \
                            --region ${AWS_DEFAULT_REGION} \
                            --query "Stacks[0].Outputs[?OutputKey=='ALBDNSName'].OutputValue" --output text)
                        echo ""
                        echo "🌐 Visit your app here: $ALB_URL"
                    '''
                }
            }
        }

        stage('Deploy to Elastic Beanstalk') {
            when {
                expression { return params.DEPLOY_TARGET == 'ELASTIC_BEANSTALK' }
            }
            steps {
                withAWS(region: "${AWS_DEFAULT_REGION}", credentials: 'jenkins-aws-creds') {
                    sh '''
                        set -e

                        echo "▶ Populating Dockerrun.aws.json with ECR URI..."
                        sed -e "s|AK_PROJECT_ECR_REGISTRY|${AWS_ACCOUNT}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com|g" \
                            Dockerrun.aws.json > /tmp/Dockerrun.aws.json
                        cat /tmp/Dockerrun.aws.json

                        echo "▶ Creating Beanstalk source bundle (zip)..."
                        mkdir -p /tmp/beanstalk-src
                        cp /tmp/Dockerrun.aws.json /tmp/beanstalk-src/
                        cd /tmp/beanstalk-src
                        zip -r /tmp/${APP_NAME}-${IMAGE_TAG}-beanstalk.zip .
                        cd -

                        echo "▶ Uploading source bundle to S3..."
                        EB_BUCKET="elasticbeanstalk-${AWS_DEFAULT_REGION}-${AWS_ACCOUNT}"
                        set +e
                        aws s3 mb s3://${EB_BUCKET} --region ${AWS_DEFAULT_REGION} 2>/dev/null
                        set -e
                        aws s3 cp /tmp/${APP_NAME}-${IMAGE_TAG}-beanstalk.zip \
                            s3://${EB_BUCKET}/ak-project/${APP_NAME}-${IMAGE_TAG}-beanstalk.zip \
                            --region ${AWS_DEFAULT_REGION}

                        echo "▶ Creating Beanstalk application version..."
                        aws elasticbeanstalk create-application-version \
                            --application-name "${BEANSTALK_APP_NAME}" \
                            --version-label "v-${IMAGE_TAG}" \
                            --description "Build #${BUILD_NUMBER} ${GIT_COMMIT.take(7)}" \
                            --source-bundle "S3Bucket=${EB_BUCKET},S3Key=ak-project/${APP_NAME}-${IMAGE_TAG}-beanstalk.zip" \
                            --process \
                            --region ${AWS_DEFAULT_REGION} || true

                        echo "▶ Updating Beanstalk environment to version v-${IMAGE_TAG}..."
                        aws elasticbeanstalk update-environment \
                            --application-name "${BEANSTALK_APP_NAME}" \
                            --environment-name "${BEANSTALK_ENV_NAME}" \
                            --version-label "v-${IMAGE_TAG}" \
                            --region ${AWS_DEFAULT_REGION}

                        echo "▶ Waiting for environment update to complete (max 15 min)..."
                        for i in $(seq 1 90); do
                            STATUS=$(aws elasticbeanstalk describe-environments \
                                --application-name "${BEANSTALK_APP_NAME}" \
                                --environment-names "${BEANSTALK_ENV_NAME}" \
                                --region ${AWS_DEFAULT_REGION} \
                                --query 'Environments[0].{s:Status,h:Health}' --output text)
                            echo "  [$i/90] status=$STATUS"
                            case "$STATUS" in
                                Ready*Green*|Ready*Yellow*) echo "✅ Done"; break ;;
                                *Terminated*) echo "❌ env terminated"; exit 1 ;;
                            esac
                            sleep 10
                        done

                        ENV_URL=$(aws elasticbeanstalk describe-environments \
                            --application-name "${BEANSTALK_APP_NAME}" \
                            --environment-names "${BEANSTALK_ENV_NAME}" \
                            --region ${AWS_DEFAULT_REGION} \
                            --query 'Environments[0].CNAME' --output text)
                        echo ""
                        echo "🌐 Visit your app here: http://${ENV_URL}"
                    '''
                }
            }
        }

        stage('Package Artifacts') {
            steps {
                sh '''
                    set -e
                    mkdir -p build-artifacts
                    cp -r app.py wsgi.py requirements.txt Dockerfile Dockerrun.aws.json \
                          ecs_task_definition.json aws_infra_cfn.yaml \
                          templates static build-artifacts/ 2>/dev/null || true
                    echo "Build #${BUILD_NUMBER} tag=${IMAGE_TAG}" > build-artifacts/BUILD_INFO.txt
                    echo "✅ Artifacts staged in build-artifacts/"
                    ls -la build-artifacts/
                '''
                archiveArtifacts artifacts: 'build-artifacts/**', fingerprint: true, allowEmptyArchive: true
            }
        }
    }

    post {
        always {
            echo '🧹 Cleaning up...'
            cleanWs(
                cleanWhenNotBuilt: false,
                deleteDirs: true,
                notFailBuild: true,
                patterns: [
                    [pattern: '.venv/**', type: 'INCLUDE'],
                    [pattern: 'build-artifacts/**', type: 'INCLUDE'],
                    [pattern: '__pycache__/**', type: 'INCLUDE'],
                    [pattern: '*.tar', type: 'INCLUDE'],
                    [pattern: '*.zip', type: 'INCLUDE']
                ]
            )
        }
        success {
            echo """
            ╔══════════════════════════════════════════════════╗
            ║        ✅ Jenkins Pipeline SUCCESSFUL             ║
            ╠══════════════════════════════════════════════════╣
            ║  Build    : #${BUILD_NUMBER}
            ║  Commit   : ${GIT_COMMIT.take(7)}
            ║  Image    : ${ECR_URI}:${IMAGE_TAG}
            ║  Region   : ${AWS_DEFAULT_REGION}
            ║  Env      : ${ENVIRONMENT_NAME}
            ║  Target   : ${DEPLOY_TARGET}
            ╚══════════════════════════════════════════════════╝
            """
        }
        failure {
            echo '❌ Pipeline FAILED — please review the logs above.'
        }
    }
}
