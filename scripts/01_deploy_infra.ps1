
param(
    [string]$Region = "us-east-1",
    [string]$StackName = "ak-project-prod-infra",
    [string]$EnvName = "ak-project-prod",
    [string]$DbUser = "akadmin",
    [Parameter(Mandatory=$true)][string]$DbPassword,
    [string]$DbName = "akprojectdb",
    [Parameter(Mandatory=$true)][string]$FlaskSecretKey,
    [string]$EcrImageUri = ""
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   AK Project — AWS Infrastructure (CloudFormation)  ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

Write-Host "▶ Validating template..." -ForegroundColor Yellow
aws cloudformation validate-template --template-body file://aws_infra_cfn.yaml --region $Region | Out-Null
Write-Host "  ✔ Template is valid" -ForegroundColor Green

Write-Host "▶ Checking if stack [$StackName] exists..." -ForegroundColor Yellow
$stack = aws cloudformation describe-stacks --stack-name $StackName --region $Region 2>$null

$params = @(
    @{ ParameterKey="EnvironmentName"; ParameterValue=$EnvName },
    @{ ParameterKey="DBUsername";        ParameterValue=$DbUser },
    @{ ParameterKey="DBPassword";        ParameterValue=$DbPassword },
    @{ ParameterKey="DBName";            ParameterValue=$DbName },
    @{ ParameterKey="FlaskSecretKey";    ParameterValue=$FlaskSecretKey },
    @{ ParameterKey="ContainerImage";    ParameterValue=$EcrImageUri }
)

$paramsArg = ($params | ForEach-Object {
    "ParameterKey=$($_.ParameterKey),ParameterValue=$($_.ParameterValue)"
}) -join " "

if ($LASTEXITCODE -eq 0 -and $stack) {
    Write-Host "  → Stack exists, running UPDATE" -ForegroundColor Magenta
    $out = aws cloudformation update-stack `
        --stack-name $StackName `
        --template-body file://aws_infra_cfn.yaml `
        --capabilities CAPABILITY_NAMED_IAM CAPABILITY_IAM `
        --parameters $paramsArg.Split(" ") `
        --region $Region 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($out -match "No updates are to be performed") {
            Write-Host "  ℹ Stack is up-to-date, no changes needed." -ForegroundColor Cyan
        } else {
            throw "Stack update failed: $out"
        }
    } else {
        Write-Host "▶ Waiting for update to complete..." -ForegroundColor Yellow
        aws cloudformation wait stack-update-complete --stack-name $StackName --region $Region
    }
} else {
    Write-Host "  → Stack does not exist, running CREATE (~15-20 min)" -ForegroundColor Magenta
    aws cloudformation create-stack `
        --stack-name $StackName `
        --template-body file://aws_infra_cfn.yaml `
        --capabilities CAPABILITY_NAMED_IAM CAPABILITY_IAM `
        --parameters $paramsArg.Split(" ") `
        --region $Region | Out-Null
    Write-Host "▶ Waiting for creation to complete..." -ForegroundColor Yellow
    aws cloudformation wait stack-create-complete --stack-name $StackName --region $Region
}

Write-Host ""
Write-Host "✅ Stack operation complete!" -ForegroundColor Green
Write-Host ""
Write-Host "▶ Stack outputs:" -ForegroundColor Yellow
aws cloudformation describe-stacks `
    --stack-name $StackName `
    --region $Region `
    --query 'Stacks[0].Outputs[*].{Key:OutputKey,Val:OutputValue}' `
    --output table
Write-Host ""
