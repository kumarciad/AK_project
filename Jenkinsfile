pipeline {
    agent any

    options {
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 60, unit: 'MINUTES')
        timestamps()
    }

    environment {
        APP_NAME         = 'AK_project'
        ECR_REPO_NAME    = 'ak-project'
        ENVIRONMENT_NAME = "${params.ENVIRONMENT_NAME}"
        AWS_DEFAULT_REGION = "${params.AWS_REGION}"
        AWS_ACCOUNT      = "${params.AWS_ACCOUNT}"
        DEPLOY_TARGET    = "${params.DEPLOY_TARGET}"
        IMAGE_TAG        = "${BUILD_NUMBER}-${env.GIT_COMMIT ? GIT_COMMIT.take(7) : 'local'}"
        ECR_URI          = "${params.AWS_ACCOUNT}.dkr.ecr.${params.AWS_REGION}.amazonaws.com/ak-project"
        CFN_STACK_NAME   = "ak-project-${params.ENVIRONMENT_NAME}-infra"
    }

    parameters {
        string(
            name: 'AWS_REGION',
            defaultValue: 'us-east-1',
            description: 'AWS region (e.g., us-east-1, eu-west-1)'
        )
        string(
            name: 'AWS_ACCOUNT',
            defaultValue: '123456789012',
            description: '12-digit AWS Account ID'
        )
        string(
            name: 'ENVIRONMENT_NAME',
            defaultValue: 'ak-project-prod',
            description: 'Environment prefix (CFN stack: ak-project-<ENV>-infra)'
        )
        choice(
            name: 'DEPLOY_TARGET',
            choices: ['ECS_FARGATE', 'ELASTIC_BEANSTALK', 'PACKAGE_ONLY'],
            description: 'Where to deploy the containerized app'
        )
        booleanParam(
            name: 'APPLY_CLOUDFORMATION',
            defaultValue: false,
            description: 'Apply aws_infra_cfn.yaml (VPC+RDS+ALB+ECS Cluster). CHECK on FIRST RUN ONLY.'
        )
        string(
            name: 'CFN_DB_USER',
            defaultValue: 'akadmin',
            description: '[APPLY_CLOUDFORMATION] New RDS Postgres username'
        )
        password(
            name: 'CFN_DB_PASSWORD',
            defaultValue: '',
            description: '[APPLY_CLOUDFORMATION] RDS Postgres password (min 12 chars)'
        )
        string(
            name: 'CFN_DB_NAME',
            defaultValue: 'akprojectdb',
            description: '[APPLY_CLOUDFORMATION] RDS Postgres database name'
        )
        password(
            name: 'CFN_FLASK_SECRET',
            defaultValue: '',
            description: '[APPLY_CLOUDFORMATION] Flask SECRET_KEY (min 16 chars, random)'
        )
        string(
            name: 'BEANSTALK_APP_NAME',
            defaultValue: 'AK-Project',
            description: '[ELASTIC_BEANSTALK] Beanstalk Application name'
        )
        string(
            name: 'BEANSTALK_ENV_NAME',
            defaultValue: 'AK-Project-env',
            description: '[ELASTIC_BEANSTALK] Beanstalk Environment name'
        )
    }

    stages {
        stage('Checkout SCM') {
            steps {
                echo 'Checking out source...'
                checkout scm
            }
        }

        stage('Lint + Syntax + Smoke Tests') {
            steps {
                sh '''
                    set -e
                    python3 --version
                    python3 -m venv .venv
                    . .venv/bin/activate
                    pip install --quiet --upgrade pip
                    pip install --quiet -r requirements.txt

                    echo "-- Syntax validation --"
                    python3 -m py_compile app.py wsgi.py
                    echo "OK"

                    echo "-- Smoke tests --"
                    python3 - <<'PYEOF'
from app import app, db
with app.app_context():
    db.create_all()
c = app.test_client()
for p, e in [("/login",200),("/register",200),("/home",302)]:
    r = c.get(p)
    assert r.status_code == e, f"{p}: expected {e}, got {r.status_code}"
    print(f"  GET {p} -> {r.status_code} OK")
r = c.post("/register", data={"username":"ci_smoke","password":"Smoke123!"}, follow_redirects=True)
assert r.status_code == 200
print("  POST /register flow OK")
r = c.post("/login", data={"username":"ci_smoke","password":"Smoke123!"}, follow_redirects=True)
assert r.status_code == 200
print("  POST /login flow OK")
r = c.get("/logout", follow_redirects=True)
assert r.status_code == 200
print("  GET /logout flow OK")
print("ALL SMOKE TESTS PASSED")
PYEOF
                '''
            }
        }

        stage('Build Docker image + Push to ECR') {
            when { expression { return params.DEPLOY_TARGET != 'PACKAGE_ONLY' } }
            steps {
                withAWS(region: "${AWS_DEFAULT_REGION}", credentials: 'jenkins-aws-creds') {
                    sh '''
                        set -e
                        ECR_FULL="${ECR_URI}:${IMAGE_TAG}"
                        ECR_LATEST="${ECR_URI}:latest"
                        REGISTRY="${AWS_ACCOUNT}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"

                        echo "-- Logging Docker to ECR --"
                        aws ecr get-login-password --region "${AWS_DEFAULT_REGION}" | \
                            docker login --username AWS --password-stdin "$REGISTRY"

                        echo "-- Ensuring ECR repo ${ECR_REPO_NAME} exists --"
                        set +e
                        aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" --region "${AWS_DEFAULT_REGION}" >/dev/null 2>&1
                        RC=$?
                        set -e
                        if [ "$RC" -ne 0 ]; then
                            aws ecr create-repository \
                                --repository-name "${ECR_REPO_NAME}" \
                                --region "${AWS_DEFAULT_REGION}" \
                                --image-scanning-configuration scanOnPush=true
                        fi

                        echo "-- Building image ${ECR_FULL} --"
                        docker build \
                            -t "$ECR_FULL" \
                            -t "$ECR_LATEST" \
                            .

                        echo "-- Pushing to ECR --"
                        docker push "$ECR_FULL"
                        docker push "$ECR_LATEST"
                        echo "Pushed: $ECR_FULL"
                    '''
                }
            }
        }

        stage('Apply CloudFormation (Infrastructure)') {
            when { expression { return params.APPLY_CLOUDFORMATION == true } }
            steps {
                withAWS(region: "${AWS_DEFAULT_REGION}", credentials: 'jenkins-aws-creds') {
                    sh '''
                        set -e
                        chmod +x scripts/apply-cfn.sh
                        ./scripts/apply-cfn.sh \
                            "${AWS_DEFAULT_REGION}" \
                            "${CFN_STACK_NAME}" \
                            "${ENVIRONMENT_NAME}" \
                            "${CFN_DB_USER}" \
                            "${CFN_DB_PASSWORD}" \
                            "${CFN_DB_NAME}" \
                            "${CFN_FLASK_SECRET}" \
                            "${ECR_URI}:${IMAGE_TAG}"
                    '''
                }
            }
        }

        stage('Deploy to ECS Fargate') {
            when { expression { return params.DEPLOY_TARGET == 'ECS_FARGATE' } }
            steps {
                withAWS(region: "${AWS_DEFAULT_REGION}", credentials: 'jenkins-aws-creds') {
                    sh '''
                        set -e
                        chmod +x scripts/deploy-ecs.sh
                        ./scripts/deploy-ecs.sh \
                            "${AWS_DEFAULT_REGION}" \
                            "${AWS_ACCOUNT}" \
                            "${ENVIRONMENT_NAME}" \
                            "${CFN_STACK_NAME}" \
                            "${IMAGE_TAG}"
                    '''
                }
            }
        }

        stage('Deploy to Elastic Beanstalk') {
            when { expression { return params.DEPLOY_TARGET == 'ELASTIC_BEANSTALK' } }
            steps {
                withAWS(region: "${AWS_DEFAULT_REGION}", credentials: 'jenkins-aws-creds') {
                    sh '''
                        set -e
                        chmod +x scripts/deploy-beanstalk.sh
                        ./scripts/deploy-beanstalk.sh \
                            "${AWS_DEFAULT_REGION}" \
                            "${AWS_ACCOUNT}" \
                            "${BEANSTALK_APP_NAME}" \
                            "${BEANSTALK_ENV_NAME}" \
                            "${BUILD_NUMBER}" \
                            "${IMAGE_TAG}"
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
                          ecs_task_definition.json aws_infra_cfn.yaml templates static \
                          scripts build-artifacts/ 2>/dev/null || true
                    echo "Build #${BUILD_NUMBER} image_tag=${IMAGE_TAG}" > build-artifacts/BUILD_INFO.txt
                    echo "Artifacts ready"
                    ls -la build-artifacts/
                '''
                archiveArtifacts artifacts: 'build-artifacts/**', fingerprint: true, allowEmptyArchive: true
            }
        }
    }

    post {
        always {
            echo 'Cleaning workspace...'
            cleanWs(
                cleanWhenNotBuilt: false,
                deleteDirs: true,
                notFailBuild: true,
                patterns: [
                    [pattern: '.venv/**', type: 'INCLUDE'],
                    [pattern: 'build-artifacts/**', type: 'INCLUDE'],
                    [pattern: '__pycache__/**', type: 'INCLUDE']
                ]
            )
        }
        success {
            echo "Pipeline OK: Build #${BUILD_NUMBER}, Image: ${ECR_URI}:${IMAGE_TAG}"
        }
        failure {
            echo 'Pipeline FAILED — review logs above.'
        }
    }
}
