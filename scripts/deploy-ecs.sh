#!/usr/bin/env bash
# Helper: Deploy new image to ECS Fargate (call from Jenkins — avoids Groovy backtick escaping)
# Args: REGION ACCOUNT ENV_NAME CFN_STACK IMAGE_TAG [SVC_NAME_OVERRIDE]
set -euo pipefail

REGION="$1"
ACCOUNT="$2"
ENV_NAME="$3"
CFN_STACK="$4"
IMAGE_TAG="$5"
SVC_NAME="${6:-${ENV_NAME}-flask-svc}"
ECR_URI="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/ak-project:${IMAGE_TAG}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

get_cfn_output() {
    local key="$1"
    aws cloudformation describe-stacks --stack-name "$CFN_STACK" --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='$key'].OutputValue" --output text
}

log "▶ ECS Fargate Deploy — image=$ECR_URI"

export AWS_DEFAULT_REGION="$REGION"

ECS_CLUSTER="$(get_cfn_output ECSClusterName)"
TG_ARN="$(get_cfn_output ALBTargetGroupArn)"
ALB_DNS="$(get_cfn_output ALBDNSName)"

[ -n "$ECS_CLUSTER" ] || { log "❌ ECSClusterName not found in CFN stack output"; exit 1; }
[ -n "$TG_ARN" ]      || log "⚠ ALBTargetGroupArn not found (first deploy?)"

log "   Cluster = $ECS_CLUSTER"
log "   TG ARN  = $TG_ARN"
log "   ALB URL = $ALB_DNS"

# --- populate task def template ---
log "▶ Populating task definition template..."
TMP_TASK="$(mktemp)"
sed -e "s|AWS_ACCOUNT|${ACCOUNT}|g" \
    -e "s|AWS_REGION|${REGION}|g" \
    -e "s|AK_PROJECT_ENV|${ENV_NAME}|g" \
    -e "s|IMAGE_TAG|${IMAGE_TAG}|g" \
    ecs_task_definition.json > "$TMP_TASK"

log "▶ Registering task definition..."
TASK_DEF_ARN="$(aws ecs register-task-definition \
    --cli-input-json "file://${TMP_TASK}" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)"
rm -f "$TMP_TASK"
log "   → $TASK_DEF_ARN"

# --- service exists / update ---
log "▶ Checking service status..."
SVC_JSON="$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$SVC_NAME" 2>/dev/null || true)"
SVC_STATUS="$(echo "$SVC_JSON" | jq -r '.services[0]?.status // "NONE"')"
log "   Service '$SVC_NAME' status: $SVC_STATUS"

if [ "$SVC_STATUS" = "ACTIVE" ] || [ "$SVC_STATUS" = "DRAINING" ]; then
    log "▶ Updating service (rolling deploy + force-new)..."
    aws ecs update-service \
        --cluster "$ECS_CLUSTER" \
        --service "$SVC_NAME" \
        --task-definition "$TASK_DEF_ARN" \
        --desired-count 2 \
        --force-new-deployment \
        --health-check-grace-period-seconds 120 \
        >/dev/null
    log "   ✔ Service update started"
else
    log "ℹ Service '$SVC_NAME' not active yet — it will be created by CloudFormation when ContainerImage param is set."
fi

# --- wait for deploy ---
sleep 10
DEPLOY_ID="$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$SVC_NAME" \
    | jq -r '.services[0].deployments[] | select(.status=="PRIMARY") | .id' | head -1)"
log "▶ Waiting for deployment ID '$DEPLOY_ID' (max 10 min)..."

for i in $(seq 1 60); do
    INFO="$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$SVC_NAME" \
        | jq -r --arg did "$DEPLOY_ID" '
            .services[0].deployments[]
            | select(.id==$did)
            | "\(.status) \(.runningCount) \(.desiredCount)"
        ')"
    STATUS=$(echo "$INFO" | awk '{print $1}')
    RUNNING=$(echo "$INFO" | awk '{print $2}')
    DESIRED=$(echo "$INFO" | awk '{print $3}')
    echo "   [$i/60] status=$STATUS running=$RUNNING/$DESIRED"
    if [ "$STATUS" = "COMPLETED" ] && [ "$RUNNING" = "$DESIRED" ] && [ -n "$RUNNING" ]; then
        log "✅ ECS deployment COMPLETED — all ${RUNNING}/${DESIRED} tasks RUNNING"
        break
    fi
    sleep 10
done

# --- TG health ---
if [ -n "$TG_ARN" ]; then
    log "▶ Target group health:"
    aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
        --query 'TargetHealthDescriptions[*].{Id:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
        --output table || true
fi

echo ""
echo "🌐 Visit: ${ALB_DNS}"
