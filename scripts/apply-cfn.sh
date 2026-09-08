#!/usr/bin/env bash
# Helper: Apply CloudFormation infrastructure stack
# Args: REGION CFN_STACK ENV_NAME DB_USER DB_PASSWORD DB_NAME FLASK_SECRET CONTAINER_IMAGE
set -euo pipefail

REGION="$1"
CFN_STACK="$2"
ENV_NAME="$3"
DB_USER="$4"
DB_PASSWORD="$5"
DB_NAME="$6"
FLASK_SECRET="$7"
CONTAINER_IMAGE="${8:-}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

export AWS_DEFAULT_REGION="$REGION"

log "▶ Validating CloudFormation template..."
aws cloudformation validate-template --template-body file://aws_infra_cfn.yaml >/dev/null
log "   ✔ Template valid"

log "▶ Checking if stack '$CFN_STACK' exists..."
set +e
STACK_INFO=$(aws cloudformation describe-stacks --stack-name "$CFN_STACK" 2>&1)
RC=$?
set -e

PARAMS="ParameterKey=EnvironmentName,ParameterValue=${ENV_NAME}
ParameterKey=DBUsername,ParameterValue=${DB_USER}
ParameterKey=DBPassword,ParameterValue=${DB_PASSWORD}
ParameterKey=DBName,ParameterValue=${DB_NAME}
ParameterKey=FlaskSecretKey,ParameterValue=${FLASK_SECRET}
ParameterKey=ContainerImage,ParameterValue=${CONTAINER_IMAGE}"

PARAM_ARGS=$(echo "$PARAMS" | tr '\n' ' ' | sed -E 's/ +$//')

if [ $RC -eq 0 ]; then
    log "   Stack exists → running update-stack"
    set +e
    UPDATE_OUT=$(aws cloudformation update-stack \
        --stack-name "$CFN_STACK" \
        --template-body file://aws_infra_cfn.yaml \
        --capabilities CAPABILITY_NAMED_IAM CAPABILITY_IAM \
        --parameters ${PARAM_ARGS} 2>&1)
    RC2=$?
    set -e
    if [ $RC2 -ne 0 ]; then
        if echo "$UPDATE_OUT" | grep -qi "No updates are to be performed"; then
            log "ℹ Stack is already up-to-date (no changes)"
            echo ""
            log "▶ Stack outputs:"
            aws cloudformation describe-stacks --stack-name "$CFN_STACK" \
                --query 'Stacks[0].Outputs[*].{Key:OutputKey,Val:OutputValue}' --output table
            exit 0
        else
            log "❌ update-stack failed: $UPDATE_OUT"
            exit 1
        fi
    fi
    log "▶ Waiting for stack-update-complete (~5-15 min)..."
    aws cloudformation wait stack-update-complete --stack-name "$CFN_STACK"
else
    log "   Stack doesn't exist → running create-stack (~15-25 min)"
    aws cloudformation create-stack \
        --stack-name "$CFN_STACK" \
        --template-body file://aws_infra_cfn.yaml \
        --capabilities CAPABILITY_NAMED_IAM CAPABILITY_IAM \
        --parameters ${PARAM_ARGS} >/dev/null
    log "▶ Waiting for stack-create-complete..."
    aws cloudformation wait stack-create-complete --stack-name "$CFN_STACK"
fi

log "✅ Stack operation finished!"
echo ""
log "▶ Stack outputs:"
aws cloudformation describe-stacks --stack-name "$CFN_STACK" \
    --query 'Stacks[0].Outputs[*].{Key:OutputKey,Val:OutputValue}' --output table
