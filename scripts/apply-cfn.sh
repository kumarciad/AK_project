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

# ---- HELPERS ----
mask_secret() {
    # usage: mask_secret "supersecretpass"  ->  prints s*********s
    local s="$1"
    local n=${#s}
    if [ "$n" -le 2 ]; then
        printf '%s' "$s" | sed 's/./*/g'
        return
    fi
    local first="${s:0:1}"
    local last="${s:n-1:1}"
    local stars=""
    local i=0
    while [ $i -lt $((n-2)) ]; do stars="${stars}*"; i=$((i+1)); done
    printf '%s%s%s' "$first" "$stars" "$last"
}

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

# SECURITY: DB master password MUST NOT equal Flask SECRET_KEY (defense in depth)
if [ "$DB_PASSWORD" = "$FLASK_SECRET" ]; then
    log "   ❌ SECURITY: CFN_DB_PASSWORD and CFN_FLASK_SECRET are IDENTICAL strings."
    log "      These two secrets serve different purposes and MUST be different values:"
    log "        CFN_DB_PASSWORD  = grants access to the Postgres RDS master user"
    log "        CFN_FLASK_SECRET = signs session cookies for your Flask app"
    log "      If one leaks and both are identical, attackers get BOTH DB + user session impersonation."
    log "   FIX: go back to Jenkins ▶ Build With Parameters, enter 2 DIFFERENT random secrets for those 2 fields."
    log "        Suggested CLI generators (run on Jenkins Linux agent shell, paste outputs):"
    log "          CFN_DB_PASSWORD:  openssl rand -base64 21 | tr -d '=\"\\x60@/\\\\ ' | cut -c1-21"
    log "          CFN_FLASK_SECRET: openssl rand -base64 32"
    ABORT=1
fi

# Summary of secrets (MASKED — first-char/last-char only, never full value)
PW_MASK=$(mask_secret "$DB_PASSWORD")
SK_MASK=$(mask_secret "$FLASK_SECRET")

if [ $ABORT -ne 0 ]; then
    log ""
    log "   FIX: go back to Jenkins ▶ Build With Parameters, fill or correct the 4 params:"
    log "         CFN_DB_USER, CFN_DB_PASSWORD, CFN_DB_NAME, CFN_FLASK_SECRET"
    log "        (and ensure APPLY_CLOUDFORMATION is CHECKED for this run)."
    exit 5
fi
log "   ✔ All required parameters pass validation"
log "     user           = ${DB_USER}"
log "     database name  = ${DB_NAME}"
log "     DB password    = ${PW_MASK}  (len=${#DB_PASSWORD}, masked)"
log "     Flask SECRET   = ${SK_MASK}  (len=${#FLASK_SECRET}, masked)"

log "▶ Validating CloudFormation template..."
set +e
VALIDATE_OUT=$(aws cloudformation validate-template --template-body file://aws_infra_cfn.yaml 2>&1)
RC_VAL=$?
set -e
if [ $RC_VAL -ne 0 ]; then
    log "   ❌ Template validation FAILED"
    # Common case: IAM policy scoped ValidateTemplate to stack ARN, but ValidateTemplate has NO Resource -> triggers AccessDenied
    if echo "$VALIDATE_OUT" | grep -qi "AccessDenied" || echo "$VALIDATE_OUT" | grep -qi "no identity-based policy allows the cloudformation:ValidateTemplate action"; then
        log ""
        log "   REASON (IAM): The IAM policy attached to jenkins-deploy-bot scopes the action"
        log "   cloudformation:ValidateTemplate to a stack ARN pattern. ValidateTemplate has NO stack"
        log "   resource (runs BEFORE a stack exists), so AWS requires Resource: \"*\" for this action."
        log ""
        log "   FIX (do it once in AWS IAM console):"
        log "     1) IAM → Policies → search JenkinsDeployAKProjectPolicy → Edit policy → JSON"
        log "     2) SPLIT the existing Statement with Sid CloudFormationDeploy INTO TWO SEPARATE STATEMENTS:"
        log "        Sid: CFNValidateAndEstimateUnscoped → Effect:Allow, Action:[cloudformation:ValidateTemplate,cloudformation:EstimateTemplateCost,cloudformation:GetTemplateSummary,cloudformation:ListStackResources], Resource:\"*\""
        log "        Sid: CloudFormationDeployScoped → Effect:Allow, Action:[cloudformation:CreateStack,cloudformation:UpdateStack,cloudformation:DescribeStacks,cloudformation:DescribeStackEvents,cloudformation:ListStacks], Resource:arn:aws:cloudformation:*:931228356673:stack/ak-project-*-infra/*"
        log "     3) Save changes → RERUN Jenkins Build (same params — no changes required there)."
        log ""
        log "   Raw AWS error for reference:"
        echo "$VALIDATE_OUT" | sed 's/^/     /'
        exit 6
    fi
    log ""
    echo "$VALIDATE_OUT" | sed 's/^/   /'
    log ""
    log "   Validate YAML syntax / intrinsic functions locally with: cfn-lint -t aws_infra_cfn.yaml"
    exit 7
fi
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

OP="CREATE"
if [ $RC -eq 0 ]; then
    EXISTING_STATUS=$(echo "$STACK_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['Stacks'][0]['StackStatus'])" 2>/dev/null || echo "UNKNOWN")
    OP="UPDATE"
    log "   Stack '$CFN_STACK' exists (status=$EXISTING_STATUS) → UPDATE operation"
    log "   Estimated wait time: 5-15 minutes (RDS modifications and SG updates are the slowest parts)."
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
            log "   Debug with: aws cloudformation describe-stack-events --stack-name $CFN_STACK --region $REGION --max-items 30"
            exit 1
        fi
    fi
    log "▶ Waiting for stack-update-complete..."
    aws cloudformation wait stack-update-complete --stack-name "$CFN_STACK" || {
        log "   ❌ UPDATE failed. Last 20 events:"
        aws cloudformation describe-stack-events --stack-name "$CFN_STACK" --region "$REGION" \
            --max-items 20 --output table 1>&2 || true
        exit 2
    }
else
    log "   Stack '$CFN_STACK' does NOT exist → CREATE operation (FIRST-TIME INFRA SETUP)"
    log "   Estimated wait time: 15-25 minutes. Bottlenecks:"
    log "     • NAT Gateway creation in 2 AZs: ~5 min each"
    log "     • RDS Postgres t3.micro single-AZ create: ~10 min"
    log "     • ALB + Target Group + Listeners: ~2 min"
    log "   Please don't cancel this job while waiting."
    aws cloudformation create-stack \
        --stack-name "$CFN_STACK" \
        --template-body file://aws_infra_cfn.yaml \
        --capabilities CAPABILITY_NAMED_IAM CAPABILITY_IAM \
        --parameters ${PARAM_ARGS} >/dev/null
    log "▶ Waiting for stack-create-complete..."
    aws cloudformation wait stack-create-complete --stack-name "$CFN_STACK" || {
        log "   ❌ CREATE failed. Last 30 events:"
        aws cloudformation describe-stack-events --stack-name "$CFN_STACK" --region "$REGION" \
            --max-items 30 --output table 1>&2 || true
        exit 3
    }
fi

log "✅ Stack operation finished (op=$OP)"
echo ""
log "▶ Stack outputs:"
aws cloudformation describe-stacks --stack-name "$CFN_STACK" \
    --query 'Stacks[0].Outputs[*].{Key:OutputKey,Val:OutputValue}' --output table
