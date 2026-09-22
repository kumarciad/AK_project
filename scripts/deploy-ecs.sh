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

# ---- EARLY VALIDATION: CFN stack must exist BEFORE we query outputs ----
# User probably ran WITHOUT APPLY_CLOUDFORMATION=true in Jenkins params.
log "▶ Checking for infrastructure CFN stack '$CFN_STACK'..."
set +e
STACK_STATUS="$(aws cloudformation describe-stacks \
    --stack-name "$CFN_STACK" \
    --region "$REGION" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null)"
SET_RC=$?
set -e

if [ $SET_RC -ne 0 ] || [ -z "$STACK_STATUS" ] || [ "$STACK_STATUS" = "None" ]; then
    log ""
    log "❌ FATAL: CloudFormation stack '$CFN_STACK' DOES NOT EXIST in region '$REGION'."
    log ""
    log "   REASON: In your previous Jenkins Build With Parameters, the boolean flag"
    log "           APPLY_CLOUDFORMATION was FALSE (unchecked). The infrastructure"
    log "           (VPC, 2 public + 2 private subnets, NAT GW, RDS Postgres, ALB,"
    log "           ECS Cluster, SSM secrets, IAM roles, ECR repo) was NEVER CREATED,"
    log "           so there is no ECS cluster / ALB / DB endpoint to deploy into."
    log ""
    log "   FIX (next Jenkins build — do this EXACTLY once, then leave unchecked):"
    log ""
    log "     1) Open Jenkins → Python-project → ▶ Build With Parameters"
    log "     2) SET PARAMETERS AS FOLLOWS:"
    log "          ☐ APPLY_CLOUDFORMATION = ☑ CHECKED (TRUE)   ← only on FIRST run!"
    log "          CFN_DB_USER     = akadmin  (or your choice)"
    log "          CFN_DB_PASSWORD = <NEW random 12+ char password for RDS Postgres>"
    log "          CFN_DB_NAME     = akprojectdb"
    log "          CFN_FLASK_SECRET= <NEW random 16+ char string used as Flask SECRET_KEY>"
    log "          DEPLOY_TARGET   = ECS_FARGATE  (keep default)"
    log "     3) Click BUILD."
    log ""
    log "   Expected runtime: Stage 4 (CloudFormation) takes 15-22 MIN the first time"
    log "   (RDS + NAT Gateways take longest). On success stages 5-7 continue"
    log "   automatically and deploy this image onto ECS Fargate behind the new ALB."
    log ""
    log "   Verify: aws cloudformation list-stacks --region $REGION \ "
    log "              --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \ "
    log "              --query 'StackSummaries[?StackName==\`$CFN_STACK\`]'"
    log ""
    exit 10
fi

case "$STACK_STATUS" in
    CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE|IMPORT_COMPLETE)
        log "   ✔ Stack exists. Status = $STACK_STATUS"
        ;;
    CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS|UPDATE_ROLLBACK_IN_PROGRESS|ROLLBACK_IN_PROGRESS)
        log "   ⚠ Stack status = '$STACK_STATUS' (still in progress). Waiting up to 25 min for completion..."
        WAIT_MAX=150
        for i in $(seq 1 $WAIT_MAX); do
            STACK_STATUS="$(aws cloudformation describe-stacks --stack-name "$CFN_STACK" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo WAITING)"
            case "$STACK_STATUS" in
                CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE|IMPORT_COMPLETE)
                    log "   ✔ Stack stabilized. Status = $STACK_STATUS ($i/150 waits)"
                    break
                    ;;
                ROLLBACK_COMPLETE|ROLLBACK_FAILED|CREATE_FAILED|DELETE_FAILED|UPDATE_ROLLBACK_FAILED)
                    log "   ❌ Stack failed. Status = $STACK_STATUS"
                    log "   Run 'aws cloudformation describe-stack-events --stack-name $CFN_STACK --region $REGION' for failure reason."
                    exit 11
                    ;;
            esac
            sleep 10
        done
        case "$STACK_STATUS" in
            CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE|IMPORT_COMPLETE) ;;
            *)
                log "   ❌ Timeout waiting for stack $CFN_STACK to finish (last status: $STACK_STATUS)"
                exit 12
                ;;
        esac
        ;;
    ROLLBACK_COMPLETE|CREATE_FAILED|ROLLBACK_FAILED|DELETE_FAILED)
        log "   ❌ Stack in BROKEN status = '$STACK_STATUS'. Refusing to deploy."
        log "   Fix the stack in CloudFormation console or delete it then rerun with APPLY_CLOUDFORMATION=TRUE."
        exit 13
        ;;
    *)
        log "   ⚠ Unknown stack status = '$STACK_STATUS'. Continuing anyway..."
        ;;
esac

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
