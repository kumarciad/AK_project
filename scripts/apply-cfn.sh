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

# ---- EARLY VALIDATION: required secrets must be present & length rules ----
log "▶ Validating required parameter inputs..."
ABORT=0

if [ -z "$DB_USER" ] || [ "${#DB_USER}" -lt 2 ]; then
    log "   ❌ CFN_DB_USER is empty/too short. Set CFN_DB_USER in Jenkins params (min 2 chars)."
    ABORT=1
fi
if [ -z "$DB_PASSWORD" ] || [ "${#DB_PASSWORD}" -lt 12 ]; then
    log "   ❌ CFN_DB_PASSWORD is empty/too short. Set CFN_DB_PASSWORD in Jenkins params (min 12 chars — RDS master password requirement)."
    ABORT=1
fi
if [ -z "$DB_NAME" ] || [ "${#DB_NAME}" -lt 2 ]; then
    log "   ❌ CFN_DB_NAME is empty/too short. Set CFN_DB_NAME in Jenkins params (min 2 chars)."
    ABORT=1
fi
if [ -z "$FLASK_SECRET" ] || [ "${#FLASK_SECRET}" -lt 16 ]; then
    log "   ❌ CFN_FLASK_SECRET is empty/too short. Set CFN_FLASK_SECRET in Jenkins params (min 16 chars, e.g. 'head -c32 /dev/urandom | base64')."
    ABORT=1
fi

# RDS Postgres username rules: must start with letter, alphanumeric + underscore, 1..63
if echo "$DB_USER" | grep -Eq '^[^a-zA-Z]' || echo "$DB_USER" | grep -Eqv '^[A-Za-z][A-Za-z0-9_]*$' || [ "${#DB_USER}" -gt 63 ]; then
    log "   ❌ CFN_DB_USER = '$DB_USER' violates RDS Postgres rules. Must start with a letter and contain only letters, digits, and underscores (max 63)."
    ABORT=1
fi

# RDS Postgres password forbidden printable chars in AWS: no slashes, quotes, @, single-quote, backtick, space, and length 8..128
if echo "$DB_PASSWORD" | LC_ALL=C grep -Eq '[ \x27"\x60@/\\]' || [ "${#DB_PASSWORD}" -gt 128 ]; then
    log "   ❌ CFN_DB_PASSWORD contains characters forbidden by AWS RDS Postgres (no space, \", ', \`, @, /, \\), max length 128."
    ABORT=1
fi

if [ $ABORT -ne 0 ]; then
    log ""
    log "   FIX: go back to Jenkins ▶ Build With Parameters, fill or correct the 4 params:"
    log "         CFN_DB_USER, CFN_DB_PASSWORD, CFN_DB_NAME, CFN_FLASK_SECRET"
    log "        (and ensure APPLY_CLOUDFORMATION is CHECKED for this run)."
    exit 5
fi
log "   ✔ All required parameters pass validation (user=${DB_USER}, db=${DB_NAME}, pwlen=${#DB_PASSWORD}, secretlen=${#FLASK_SECRET})"

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
