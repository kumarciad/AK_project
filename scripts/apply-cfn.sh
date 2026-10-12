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

PARAMS="ParameterKey=EnvironmentName,ParameterValue=${ENV_NAME}
ParameterKey=DBUsername,ParameterValue=${DB_USER}
ParameterKey=DBPassword,ParameterValue=${DB_PASSWORD}
ParameterKey=DBName,ParameterValue=${DB_NAME}
ParameterKey=FlaskSecretKey,ParameterValue=${FLASK_SECRET}
ParameterKey=ContainerImage,ParameterValue=${CONTAINER_IMAGE}"

PARAM_ARGS=$(echo "$PARAMS" | tr '\n' ' ' | sed -E 's/ +$//')

# ---- PREFLIGHT: List template-declared parameters vs what we're passing (defense against mismatches)
log "▶ Parameter mismatch preflight (declared in aws_infra_cfn.yaml vs passed from Jenkins)..."
set +e
TPL_PARAMS=$(aws cloudformation get-template-summary --template-body file://aws_infra_cfn.yaml --query 'Parameters[*].ParameterKey' --output text 2>/dev/null | tr '\t' '\n' | sort -u)
RC_T=$?
set -e
# Parameters WE are sending via PARAM_ARGS (extract ParameterKey=...,ParameterValue= pairs)
SENT_PARAMS=$(echo "$PARAMS" | awk -F',' '{print $1}' | awk -F'=' '{print $2}' | sort -u)
if [ $RC_T -eq 0 ] && [ -n "$TPL_PARAMS" ]; then
    MISSING_IN_SENT=""
    EXTRA_IN_SENT=""
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        if ! echo "$SENT_PARAMS" | grep -Fxq "$p"; then
            MISSING_IN_SENT="$MISSING_IN_SENT $p"
        fi
    done <<< "$TPL_PARAMS"
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        if ! echo "$TPL_PARAMS" | grep -Fxq "$p"; then
            EXTRA_IN_SENT="$EXTRA_IN_SENT $p"
        fi
    done <<< "$SENT_PARAMS"
    if [ -n "$MISSING_IN_SENT" ]; then
        log "   ℹ Template-declared parameters NOT explicitly passed (will use CFN Defaults if declared):$MISSING_IN_SENT"
    fi
    if [ -n "$EXTRA_IN_SENT" ]; then
        log "   ⚠ Parameters we are passing BUT template does NOT DECLARE (CloudFormation will throw ValidationError 'Unrecognized parameter parameters...'):$EXTRA_IN_SENT"
        log "     FIX: remove these from PARAM_ARGS in apply-cfn.sh, or add them to the Parameters: section of aws_infra_cfn.yaml"
        # Don't abort — let CFN give us the explicit error, but warn loudly
    fi
    log "   ✔ Parameter preflight complete"
else
    log "   ⚠ Skipping parameter preflight (get-template-summary did not run — likely needs IAM allow 'cloudformation:GetTemplateSummary')"
fi

log "▶ Checking if stack '$CFN_STACK' exists..."
set +e
STACK_INFO=$(aws cloudformation describe-stacks --stack-name "$CFN_STACK" 2>&1)
RC=$?
set -e

OP="CREATE"
if [ $RC -eq 0 ]; then
    EXISTING_STATUS=$(echo "$STACK_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['Stacks'][0]['StackStatus'])" 2>/dev/null || echo "UNKNOWN")
    if [ "$EXISTING_STATUS" = "ROLLBACK_COMPLETE" ] || [ "$EXISTING_STATUS" = "CREATE_FAILED" ]; then
        log "   Stack '$CFN_STACK' exists but is in FAILED state ($EXISTING_STATUS) → cannot UPDATE. Deleting it automatically first and waiting for delete-complete, then CREATE fresh."
        log "   ⚠ This will wipe the failed stack (no resources should be running). If this is NOT desired hit Ctrl-C NOW (5s grace)..."
        sleep 5
        aws cloudformation delete-stack --stack-name "$CFN_STACK"
        log "▶ Waiting for delete-stack-complete (usually <3 min for a rolled-back stack)..."
        aws cloudformation wait stack-delete-complete --stack-name "$CFN_STACK" || {
            log "   ❌ delete-stack did not finish cleanly. Forcibly check status and delete remaining: aws cloudformation describe-stacks --region $REGION --stack-name $CFN_STACK"
            exit 8
        }
        log "   ✔ Failed stack cleaned. Proceeding with CREATE."
        # Now treat as "doesn't exist" -> create branch
        RC=1
    fi
fi

dump_create_failed_events() {
    # helper: dump all resource-level CREATE_FAILED rows with full reasons (not just stack-level summary!)
    log ""
    log "   🔎 Resource-level CREATE_FAILED rows (the N specific validation errors are printed below individually):"
    set +e
    RAW=$(aws cloudformation describe-stack-events --stack-name "$1" --region "$REGION" --max-items 200 --output json 2>/dev/null)
    if command -v jq >/dev/null 2>&1 && [ -n "$RAW" ]; then
        echo "$RAW" | jq -r '
def safe: . // "<null>";
.StackEvents[]
| select(.ResourceStatus == "CREATE_FAILED")
| [ .Timestamp, .ResourceType, .LogicalResourceId, .ResourceStatusReason|safe ]
| @tsv' 2>/dev/null | while IFS=$'\t' read -r TS TYP LID REA; do
            log ""
            log "     • [$TS] CREATE_FAILED   $TYP   $LID"
            # wrap REA nicely, replacing literal \n with newlines inside reason
            echo "$REA" | awk '{gsub(/\\n/,"\n           ")} {print "           Reason: "$0}'
        done
    else
        # no jq: fallback to grep -A 2 for CREATE_FAILED
        aws cloudformation describe-stack-events --stack-name "$1" --region "$REGION" --max-items 200 --output text 2>/dev/null | grep -E "CREATE_FAILED|ResourceStatusReason" | head -80 | sed 's/^/     /'
    fi
    set -e
    log ""
}

if [ $RC -eq 0 ]; then
    OP="UPDATE"
    EXISTING_STATUS=$(echo "$STACK_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['Stacks'][0]['StackStatus'])" 2>/dev/null || echo "UNKNOWN")
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
            # Check for Validation errors and dump resource events
            if echo "$UPDATE_OUT" | grep -qiE "ValidationError|error(s?)\."; then
                dump_create_failed_events "$CFN_STACK"
            fi
            log "   Debug with: aws cloudformation describe-stack-events --stack-name $CFN_STACK --region $REGION --max-items 30"
            exit 1
        fi
    fi
    log "▶ Waiting for stack-update-complete..."
    aws cloudformation wait stack-update-complete --stack-name "$CFN_STACK" || {
        log "   ❌ UPDATE failed."
        dump_create_failed_events "$CFN_STACK"
        log "   Last 20 events (as table):"
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
    set +e
    CREATE_OUT=$(aws cloudformation create-stack \
        --stack-name "$CFN_STACK" \
        --template-body file://aws_infra_cfn.yaml \
        --capabilities CAPABILITY_NAMED_IAM CAPABILITY_IAM \
        --parameters ${PARAM_ARGS} 2>&1)
    RC3=$?
    set -e
    if [ $RC3 -ne 0 ]; then
        log "   ❌ create-stack call failed IMMEDIATELY:"
        echo "$CREATE_OUT" | sed 's/^/     /'
        # dump validation details if applicable
        dump_create_failed_events "$CFN_STACK"
        exit 9
    fi
    log "▶ Waiting for stack-create-complete..."
    aws cloudformation wait stack-create-complete --stack-name "$CFN_STACK" || {
        log "   ❌ CREATE failed (rollback after initial validation errors)."
        log ""
        log "   Most probable causes: 1) Invalid RDS EngineVersion/DBInstanceClass for ap-south-2; 2) Wrong region/AZ selectors; 3) Parameter sent but undeclared in template; 4) IAM PassRole/capability missing"
        dump_create_failed_events "$CFN_STACK"
        log "   Top 40 stack events (as table):"
        aws cloudformation describe-stack-events --stack-name "$CFN_STACK" --region "$REGION" \
            --max-items 40 --output table 1>&2 || true
        exit 3
    }
fi

log "✅ Stack operation finished (op=$OP)"
echo ""
log "▶ Stack outputs:"
aws cloudformation describe-stacks --stack-name "$CFN_STACK" \
    --query 'Stacks[0].Outputs[*].{Key:OutputKey,Val:OutputValue}' --output table
