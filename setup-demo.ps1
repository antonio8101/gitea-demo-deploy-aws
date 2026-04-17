#!/usr/bin/env pwsh
# setup-demo.ps1 — run all steps or a single one.
#
# Usage:
#   .\setup-demo.ps1                  # runs all steps in order
#   .\setup-demo.ps1 -Step docker     # start containers
#   .\setup-demo.ps1 -Step admin      # create Gitea admin user
#   .\setup-demo.ps1 -Step curl       # create Gitea repository via API
#   .\setup-demo.ps1 -Step git        # init repo and push
#   .\setup-demo.ps1 -Step runner     # register and start Actions runner
#   .\setup-demo.ps1 -Step infra      # deploy CDK stack and write .env
#   .\setup-demo.ps1 -Step reset      # tear down everything (containers + volumes + git)
#
# Available steps: docker | admin | curl | git | runner | infra | reset | all (default)

param(
    [ValidateSet("all", "docker", "admin", "curl", "git", "runner", "infra", "reset")]
    [string]$Step          = "all",
    [string]$AdminUser     = "admin",
    [string]$AdminPassword = "Admin1234!",
    [string]$AdminEmail    = "admin@local.dev",
    [string]$RepoName      = "demo-app",
    [string]$GiteaUrl      = "http://localhost:3000",

    # S3 / AWS
    [string]$S3BucketName = "ailandings-demo-deployment-artifacts",
    [string]$S3Region     = "eu-west-1",
    [string]$AwsProfile   = "default"
)

$ErrorActionPreference = "Stop"

# ─── Helpers ────────────────────────────────────────────────────────────────

function Write-Step([string]$msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}

function Wait-ForGitea([string]$url, [int]$timeoutSec = 60) {
    Write-Host "    Waiting for Gitea to be ready..." -NoNewline
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri "$url/api/healthz" -UseBasicParsing -TimeoutSec 3
            if ($resp.StatusCode -eq 200) { Write-Host " OK" -ForegroundColor Green; return }
        } catch { }
        Write-Host "." -NoNewline
        Start-Sleep -Seconds 3
    }
    throw "Gitea did not become ready within $timeoutSec seconds."
}

# ─── Steps ──────────────────────────────────────────────────────────────────

function Step-Docker {
    Write-Step "Starting containers"
    docker compose up -d
    if ($LASTEXITCODE -ne 0) { throw "docker compose up failed." }
    Wait-ForGitea -url $GiteaUrl
}

function Step-Admin {
    Write-Step "Creating Gitea admin user '$AdminUser'"
    docker exec -u git gitea gitea admin user create `
        --admin `
        --username $AdminUser `
        --password $AdminPassword `
        --email $AdminEmail `
        --must-change-password=false
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    (user may already exist - continuing)" -ForegroundColor Yellow
    }
}

function Step-Curl {
    $base64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${AdminUser}:${AdminPassword}"))
    $authHeader = @{ "Content-Type" = "application/json"; "Authorization" = "Basic $base64" }

    # ── Create repository ─────────────────────────────────────────────────────
    Write-Step "Creating repository '$RepoName' via API"
    $repoBody = @{
        name           = $RepoName
        description    = "Laravel demo app"
        private        = $false
        auto_init      = $false
        default_branch = "main"
    } | ConvertTo-Json

    $repoResponse = Invoke-RestMethod `
        -Method Post `
        -Uri "$GiteaUrl/api/v1/user/repos" `
        -Headers $authHeader `
        -Body $repoBody

    Write-Host "    Repo created: $($repoResponse.html_url)" -ForegroundColor Green

    # ── Read CI pipeline credentials from .env and store as repo Actions secrets ─
    Write-Step "Storing CI pipeline credentials as repo secrets"
    $envFile = Join-Path $PSScriptRoot ".env"
    $envVars = @{}
    Get-Content $envFile | Where-Object { $_ -match "^S3_|^CI_" } | ForEach-Object {
        $parts = $_ -split "=", 2
        $envVars[$parts[0].Trim()] = $parts[1].Trim()
    }

    $secretsToStore = @(
        @{ name = "AWS_ACCESS_KEY_ID";     data = $envVars["CI_ACCESS_KEY_ID"] },
        @{ name = "AWS_SECRET_ACCESS_KEY"; data = $envVars["CI_SECRET_ACCESS_KEY"] },
        @{ name = "AWS_REGION";            data = $envVars["S3_REGION"] },
        @{ name = "S3_BUCKET_NAME";        data = $envVars["S3_BUCKET_NAME"] }
    )

    foreach ($secret in $secretsToStore) {
        Invoke-RestMethod `
            -Method Put `
            -Uri "$GiteaUrl/api/v1/repos/$AdminUser/$RepoName/actions/secrets/$($secret.name)" `
            -Headers $authHeader `
            -Body (@{ data = $secret.data } | ConvertTo-Json) | Out-Null
        Write-Host "    Secret $($secret.name) saved" -ForegroundColor Green
    }
}

function Step-Git {
    $remoteUrl = "http://${AdminUser}:${AdminPassword}@localhost:3000/${AdminUser}/${RepoName}.git"
    Write-Step "Initialising git and pushing to Gitea"

    if (-not (Test-Path ".git")) {
        git init
        git checkout -b main
    }

    $existingRemote = git remote | Where-Object { $_ -eq "origin" }
    if ($existingRemote) { git remote remove origin }
    git remote add origin $remoteUrl

    git add .
    git commit -m "chore: initial commit" --allow-empty
    git push -u origin main

    Write-Host "`n✅ Done! Open $GiteaUrl/$AdminUser/$RepoName" -ForegroundColor Green
}

function Step-Infra {
    Write-Step "Deploying CDK infrastructure"

    # ── Copy .env.example → .env if not present ──────────────────────────────
    $envFile = Join-Path $PSScriptRoot ".env"
    if (-not (Test-Path $envFile)) {
        Copy-Item (Join-Path $PSScriptRoot ".env.example") $envFile
        Write-Host "    .env created from .env.example" -ForegroundColor Yellow
    }

    # ── Deploy CDK (creates bucket + IAM user + access key) ──────────────────
    Push-Location ".infrastructure"
    try {
        $awsAccount = aws sts get-caller-identity --query Account --output text --profile $AwsProfile 2>&1
        if ($LASTEXITCODE -ne 0) { throw "aws sts get-caller-identity failed. Check AWS credentials/profile '$AwsProfile'." }
        Write-Host "    AWS account: $awsAccount" -ForegroundColor Green

        $env:CDK_DEFAULT_ACCOUNT = $awsAccount
        $env:CDK_DEFAULT_REGION  = $S3Region

        npm install --silent

        Write-Host "    Bootstrapping CDK environment (skipped if already done)..." -ForegroundColor Yellow
        npx cdk bootstrap aws://$awsAccount/$S3Region --profile $AwsProfile
        if ($LASTEXITCODE -ne 0) { throw "cdk bootstrap failed." }

        npx cdk deploy --all --require-approval never `
            --profile $AwsProfile `
            --outputs-file cdk-outputs.json `
            -c bucketName=$S3BucketName `
            -c region=$S3Region
        if ($LASTEXITCODE -ne 0) { throw "cdk deploy failed." }

        # ── Read outputs and write to .env ────────────────────────────────────
        $outputs = Get-Content "cdk-outputs.json" | ConvertFrom-Json
        $stack   = $outputs.AILandingsDemoDeploymentArtifacts

        $envContent = Get-Content $envFile -Raw
        $envContent = $envContent -replace "S3_BUCKET_NAME=.*",      "S3_BUCKET_NAME=$($stack.BucketName)"
        $envContent = $envContent -replace "S3_REGION=.*",            "S3_REGION=$($stack.BucketRegion)"
        $envContent = $envContent -replace "S3_ACCESS_KEY_ID=.*",     "S3_ACCESS_KEY_ID=$($stack.AccessKeyId)"
        $envContent = $envContent -replace "S3_SECRET_ACCESS_KEY=.*", "S3_SECRET_ACCESS_KEY=$($stack.SecretAccessKey)"
        $envContent = $envContent -replace "CI_ACCESS_KEY_ID=.*",     "CI_ACCESS_KEY_ID=$($stack.CIAccessKeyId)"
        $envContent = $envContent -replace "CI_SECRET_ACCESS_KEY=.*", "CI_SECRET_ACCESS_KEY=$($stack.CISecretAccessKey)"
        Set-Content (Join-Path $PSScriptRoot ".env") $envContent -Encoding UTF8

        Write-Host "    .env updated with credentials from CDK outputs:" -ForegroundColor Green
        Write-Host "      Bucket      : $($stack.BucketName)"    -ForegroundColor Green
        Write-Host "      Region      : $($stack.BucketRegion)"  -ForegroundColor Green
        Write-Host "      S3 Key ID   : $($stack.AccessKeyId)"   -ForegroundColor Green
        Write-Host "      CI Key ID   : $($stack.CIAccessKeyId)" -ForegroundColor Green
    }
    finally {
        Pop-Location
    }
}

function Step-Reset {
    Write-Step "Resetting environment"

    # ── SSM parameter ─────────────────────────────────────────────────────────
    $awsAccount = aws sts get-caller-identity --query Account --output text --profile $AwsProfile 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    Deleting SSM parameter /ai-landings/demo-app/version..." -ForegroundColor Yellow
        try {
            $ErrorActionPreference = "Continue"
            aws ssm delete-parameter --name "/ai-landings/demo-app/version" --profile $AwsProfile 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    SSM parameter deleted" -ForegroundColor Yellow
            } else {
                Write-Host "    SSM parameter not found, skipping" -ForegroundColor Yellow
            }
        } finally {
            $ErrorActionPreference = "Stop"
        }
    }

    # ── CDK destroy ───────────────────────────────────────────────────────────
    if (Test-Path ".infrastructure\node_modules") {
        Write-Host "    Destroying CDK stack..." -ForegroundColor Yellow
        Push-Location ".infrastructure"
        try {
            $awsAccount = aws sts get-caller-identity --query Account --output text --profile $AwsProfile 2>&1
            if ($LASTEXITCODE -eq 0) {
                $env:CDK_DEFAULT_ACCOUNT = $awsAccount
                $env:CDK_DEFAULT_REGION  = $S3Region
                npx cdk destroy --all --force --profile $AwsProfile
                Write-Host "    CDK stack destroyed" -ForegroundColor Yellow
            } else {
                Write-Host "    AWS credentials not available, skipping CDK destroy" -ForegroundColor Yellow
            }
        }
        finally {
            Pop-Location
        }
    }

    # ── Docker ────────────────────────────────────────────────────────────────
    docker compose down -v
    if ($LASTEXITCODE -ne 0) { throw "docker compose down failed." }

    # ── Git ───────────────────────────────────────────────────────────────────
    if (Test-Path ".git") {
        Remove-Item -Recurse -Force ".git"
        Write-Host "    .git removed" -ForegroundColor Yellow
    }

    # ── .env ──────────────────────────────────────────────────────────────────
    if (Test-Path ".env") {
        Remove-Item -Force ".env"
        Write-Host "    .env removed" -ForegroundColor Yellow
    }

    Write-Host "    Reset complete. Run '.\setup-demo.ps1' to restore." -ForegroundColor Green
}

function Step-Runner {
    Write-Step "Registering and starting Gitea Actions runner"

    # Get registration token via API
    $base64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${AdminUser}:${AdminPassword}"))
    $tokenResponse = Invoke-RestMethod `
        -Method GET `
        -Uri "$GiteaUrl/api/v1/admin/runners/registration-token" `
        -Headers @{ "Authorization" = "Basic $base64" }

    $env:GITEA_RUNNER_TOKEN = $tokenResponse.token
    Write-Host "    Token obtained: $($env:GITEA_RUNNER_TOKEN)" -ForegroundColor Green

    docker compose up -d gitea-runner
    if ($LASTEXITCODE -ne 0) { throw "Failed to start gitea-runner." }

    Write-Host "    Runner started. It will self-register in a few seconds." -ForegroundColor Green
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

switch ($Step) {
    "docker" { Step-Docker }
    "admin"  { Step-Admin  }
    "curl"   { Step-Curl   }
    "git"    { Step-Git    }
    "runner" { Step-Runner }
    "infra"  { Step-Infra  }
    "reset"  { Step-Reset  }
    "all"    { Step-Infra; Step-Docker; Step-Admin; Step-Curl; Step-Runner; Step-Git }
}
