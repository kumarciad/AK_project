
param(
    [string]$Region = "us-east-1",
    [string]$AccountId = $(aws sts get-caller-identity --query Account --output text),
    [string]$RepoName = "ak-project",
    [string]$ImageTag = "latest"
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║      AK Project — Build & Push to ECR              ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

if ([string]::IsNullOrEmpty($AccountId)) {
    throw "Could not determine AWS Account ID. Run 'aws configure' or set credentials first."
}

$EcrUri = "${AccountId}.dkr.ecr.${Region}.amazonaws.com/${RepoName}"
Write-Host "▶ ECR Repository: $EcrUri" -ForegroundColor Yellow

Write-Host "▶ Logging Docker into ECR..." -ForegroundColor Yellow
aws ecr get-login-password --region $Region | `
    docker login --username AWS --password-stdin "${AccountId}.dkr.ecr.${Region}.amazonaws.com"
if ($LASTEXITCODE -ne 0) { throw "Docker ECR login failed" }

Write-Host "▶ Ensuring ECR repo exists..." -ForegroundColor Yellow
aws ecr describe-repositories --repository-names $RepoName --region $Region 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  → Creating ECR repo..." -ForegroundColor Magenta
    aws ecr create-repository `
        --repository-name $RepoName `
        --region $Region `
        --image-scanning-configuration scanOnPush=true | Out-Null
    Write-Host "  ✔ Repo created" -ForegroundColor Green
}

Write-Host "▶ Building Docker image (tag: $ImageTag)..." -ForegroundColor Yellow
docker build --progress=plain -t "${EcrUri}:${ImageTag}" -t "${EcrUri}:latest" .
if ($LASTEXITCODE -ne 0) { throw "docker build failed" }
Write-Host "  ✔ Build complete" -ForegroundColor Green

Write-Host "▶ Pushing image to ECR..." -ForegroundColor Yellow
docker push "${EcrUri}:${ImageTag}"
if ($LASTEXITCODE -ne 0) { throw "docker push tag failed" }
docker push "${EcrUri}:latest"
if ($LASTEXITCODE -ne 0) { throw "docker push latest failed" }

Write-Host ""
Write-Host "✅ ECR push complete!" -ForegroundColor Green
Write-Host "   Image URI: ${EcrUri}:${ImageTag}" -ForegroundColor Cyan
Write-Host ""

return "${EcrUri}:${ImageTag}"
