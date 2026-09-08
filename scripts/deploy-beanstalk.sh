#!/usr/bin/env bash
# Helper: Deploy to Elastic Beanstalk (call from Jenkins)
# Args: REGION ACCOUNT APP_NAME ENV_NAME APP_NAME BUILD_NUMBER IMAGE_TAG
set -euo pipefail

REGION="$1"
ACCOUNT="$2"
APP_NAME="$3"
ENV_NAME="$4"
BUILD_NUMBER="$5"
IMAGE_TAG="$6"

ECR_URI="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/ak-project:${IMAGE_TAG}"
EB_BUCKET="elasticbeanstalk-${REGION}-${ACCOUNT}"
SRC_DIR="$(mktemp -d)"
ZIP_PATH="/tmp/AK-${BUILD_NUMBER}-beanstalk.zip"
VER_LABEL="v-${IMAGE_TAG}"
S3_KEY="ak-project/AK-${BUILD_NUMBER}-beanstalk.zip"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "▶ Beanstalk deploy — app=$APP_NAME env=$ENV_NAME ver=$VER_LABEL"
export AWS_DEFAULT_REGION="$REGION"

log "▶ Populating Dockerrun.aws.json (ECR image: $ECR_URI)"
sed -e "s|AK_PROJECT_ECR_REGISTRY|${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com|g" \
    Dockerrun.aws.json > "$SRC_DIR/Dockerrun.aws.json"

log "▶ Creating zip bundle..."
( cd "$SRC_DIR" && zip -q -r "$ZIP_PATH" . )
log "   Size: $(du -h "$ZIP_PATH" | cut -f1)"

log "▶ Ensuring EB S3 bucket exists..."
set +e
aws s3 mb "s3://${EB_BUCKET}" >/dev/null 2>&1
set -e

log "▶ Uploading zip to s3://${EB_BUCKET}/${S3_KEY}"
aws s3 cp "$ZIP_PATH" "s3://${EB_BUCKET}/${S3_KEY}" --quiet

log "▶ Creating application version '$VER_LABEL'..."
aws elasticbeanstalk create-application-version \
    --application-name "$APP_NAME" \
    --version-label "$VER_LABEL" \
    --description "Build #${BUILD_NUMBER} tag=${IMAGE_TAG}" \
    --source-bundle "S3Bucket=${EB_BUCKET},S3Key=${S3_KEY}" \
    --process \
    >/dev/null 2>&1 || log "   ℹ Version '$VER_LABEL' already exists — continuing"

log "▶ Updating environment '$ENV_NAME' to version '$VER_LABEL'..."
aws elasticbeanstalk update-environment \
    --application-name "$APP_NAME" \
    --environment-name "$ENV_NAME" \
    --version-label "$VER_LABEL" \
    >/dev/null

log "▶ Waiting for environment update (max 15 min)..."
for i in $(seq 1 90); do
    STATUS=$(aws elasticbeanstalk describe-environments \
        --application-name "$APP_NAME" \
        --environment-names "$ENV_NAME" \
        --query 'Environments[0].{s:Status,h:Health}' --output text)
    S=$(echo "$STATUS" | awk '{print $1}')
    H=$(echo "$STATUS" | awk '{print $2}')
    echo "   [$i/90] status=$S health=$H"
    if [ "$S" = "Ready" ] && { [ "$H" = "Green" ] || [ "$H" = "Yellow" ]; }; then
        log "✅ Beanstalk environment is Ready / $H"
        break
    fi
    if [ "$S" = "Terminated" ] || [ "$S" = "Terminating" ]; then
        log "❌ Environment is Terminated"
        exit 1
    fi
    sleep 10
done

ENV_CNAME=$(aws elasticbeanstalk describe-environments \
    --application-name "$APP_NAME" \
    --environment-names "$ENV_NAME" \
    --query 'Environments[0].CNAME' --output text)

echo ""
echo "🌐 Visit: http://${ENV_CNAME}"

rm -rf "$SRC_DIR" "$ZIP_PATH"
