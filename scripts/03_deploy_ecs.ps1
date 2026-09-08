
param(
    [string]$Region = "us-east-1",
    [string]$AccountId = $(aws sts get-caller-identity --query Account --output text),
    [string]$CfnStack = "ak-project-prod-infra",
    [string]$EnvName = "ak-project-prod",
    [Parameter(Mandatory=$true)][string]$ImageTag
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║      AK Project — Deploy to ECS Fargate             ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$EcrUri = "${AccountId}.dkr.ecr.${Region}.amazonaws.com/ak-project:${ImageTag}"
Write-Host "▶ Image: $EcrUri" -ForegroundColor Yellow

Write-Host "▶ Looking up CFN stack outputs..." -ForegroundColor Yellow
function Get-StackOutput($key) {
    return (aws cloudformation describe-stacks `
        --stack-name $CfnStack --region $Region `
        --query "Stacks[0].Outputs[?OutputKey=='$key'].OutputValue" --output text).Trim()
}
$EcsCluster   = Get-StackOutput ECSClusterName
$TgArn        = Get-StackOutput ALBTargetGroupArn
$AlbDns       = Get-StackOutput ALBDNSName
$TaskRoleArn  = "arn:aws:iam::${AccountId}:role/${EnvName}-task-role"
$ExecRoleArn  = "arn:aws:iam::${AccountId}:role/${EnvName}-task-exec-role"

if ([string]::IsNullOrEmpty($EcsCluster)) { throw "Could not find ECS cluster in stack. Did you run 01_deploy_infra.ps1 first?" }

Write-Host "   Cluster:  $EcsCluster" -ForegroundColor Gray
Write-Host "   Target:   $TgArn" -ForegroundColor Gray
Write-Host "   ALB URL:  $AlbDns" -ForegroundColor Gray
Write-Host ""

Write-Host "▶ Populating task definition template..." -ForegroundColor Yellow
$taskJson = (Get-Content ecs_task_definition.json -Raw) `
    -replace "AWS_ACCOUNT",    $AccountId `
    -replace "AWS_REGION",     $Region `
    -replace "AK_PROJECT_ENV", $EnvName `
    -replace "IMAGE_TAG",      $ImageTag
$taskFile = Join-Path $env:TEMP "ecs_task_$(Get-Random).json"
$taskJson | Out-File -FilePath $taskFile -Encoding utf8

Write-Host "▶ Registering new ECS task definition..." -ForegroundColor Yellow
$TaskDefArn = (aws ecs register-task-definition `
    --cli-input-json "file://$taskFile" `
    --region $Region `
    --query 'taskDefinition.taskDefinitionArn' --output text).Trim()
Write-Host "   → $TaskDefArn" -ForegroundColor Green
Remove-Item $taskFile -Force

Write-Host "▶ Updating ECS service..." -ForegroundColor Yellow
$SvcName = "${EnvName}-flask-svc"
$svc = (aws ecs describe-services --cluster $EcsCluster --services $SvcName --region $Region 2>$null | `
    ConvertFrom-Json).services
if ($null -eq $svc -or $svc.Count -eq 0) {
    Write-Host "   ℹ Service doesn't exist yet — it will be created when CloudFormation is applied with ContainerImage." -ForegroundColor Cyan
} else {
    aws ecs update-service `
        --cluster $EcsCluster --service $SvcName `
        --task-definition $TaskDefArn --desired-count 2 `
        --force-new-deployment `
        --health-check-grace-period-seconds 120 `
        --region $Region | Out-Null
    Write-Host "   ✔ Service update started" -ForegroundColor Green

    Write-Host ""
    Write-Host "▶ Waiting for deployment (this can take 2-5 min)..." -ForegroundColor Yellow
    Start-Sleep 10
    $max = 60
    for ($i=1; $i -le $max; $i++) {
        $svcInfo = (aws ecs describe-services --cluster $EcsCluster --services $SvcName --region $Region | ConvertFrom-Json).services[0]
        $primary = $svcInfo.deployments | Where-Object { $_.status -eq "PRIMARY" } | Select-Object -First 1
        if ($null -eq $primary) { break }
        Write-Host "   [$i/$max] status=$($primary.status) running=$($primary.runningCount)/$($primary.desiredCount)" -ForegroundColor Gray
        if ($primary.status -eq "COMPLETED" -and $primary.runningCount -eq $primary.desiredCount) {
            Write-Host ""
            Write-Host "✅ ECS deployment COMPLETE!" -ForegroundColor Green
            break
        }
        Start-Sleep 10
    }

    Write-Host ""
    Write-Host "▶ Target group health:" -ForegroundColor Yellow
    aws elbv2 describe-target-health --target-group-arn $TgArn --region $Region `
        --query 'TargetHealthDescriptions[*].{Id:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' `
        --output table
}

Write-Host ""
Write-Host "🌐 Your app is live at: $AlbDns" -ForegroundColor Cyan
Write-Host ""
