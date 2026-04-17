# AWS Deploy Demo App

A **Laravel 13** demo application that showcases a complete CI/CD pipeline using a self-hosted [Gitea](https://gitea.io) instance, a custom Docker runner image, and AWS for artifact storage and deployment.

---

## What's inside

| Layer | Technology |
|---|---|
| Application | Laravel 13, PHP 8.3, Vite, SQLite |
| Local Git & CI/CD | Gitea + Gitea Actions (Docker Compose) |
| CI runner image | Custom Docker image (PHP + Composer + Node.js 20 + AWS CLI) |
| Cloud infrastructure | AWS CDK (S3 artifact bucket, IAM users, SSM, Auto Scaling Group) |

### Pipeline overview

- **CI** — triggered on every push/PR to `main`: installs dependencies, builds frontend assets, prepares the Laravel environment, runs unit tests.
- **CD** — triggered on version tags (`v*`): builds a production artifact, uploads it to S3, updates an SSM parameter with the deployed version, and triggers an Auto Scaling Group instance refresh.

---

## Prerequisites

- Docker Desktop (or Docker Engine + Compose)
- Node.js 20+ and npm
- AWS CLI configured with a profile that has CDK deploy permissions
- PowerShell 7+ (for `setup-demo.ps1`)

---

## Quick start

### 1. Clone and install app dependencies

```bash
composer run setup
```

This copies `.env.example` → `.env`, generates the app key, runs migrations, and builds frontend assets.

### 2. Spin up the full local environment (Gitea + runner + AWS infra)

```bash
# Deploy everything in one shot
.\setup-demo.ps1

# Or run individual steps
.\setup-demo.ps1 -Step docker   # start Gitea containers
.\setup-demo.ps1 -Step admin    # create Gitea admin user
.\setup-demo.ps1 -Step infra    # deploy CDK stack and write AWS credentials to .env
.\setup-demo.ps1 -Step curl     # create Gitea repo and push pipeline secrets
.\setup-demo.ps1 -Step runner   # register and start Actions runner
.\setup-demo.ps1 -Step git      # init repo and push code
```

Gitea will be available at **http://localhost:3000** after the `docker` step.

### 3. Run the dev server

```bash
composer run dev
```

Starts Laravel, the queue worker, log viewer and Vite — all concurrently.

---

## CI runner Docker image

The pipelines use a custom image instead of pulling generic images from Docker Hub.  
The `Dockerfile` lives at `.docker/ci/Dockerfile` and includes:

- PHP 8.3 + extensions (`mbstring`, `bcmath`, `pdo_sqlite`, `xml`, `zip`, `sodium`, `curl`)
- Composer 2
- Node.js 20 + npm
- Docker CLI
- AWS CLI v2

Build and tag it locally before running the pipelines:

```bash
docker build -t ci-runner:latest .docker/ci/
```

---

## Useful commands

```bash
# Run all tests
composer run test

# Run a single test file or method
php artisan test tests/Feature/ExampleTest.php
php artisan test --filter=test_method_name

# Lint / format
./vendor/bin/pint          # fix
./vendor/bin/pint --test   # check only

# Healthcheck endpoint
curl http://localhost:8000/healthcheck
```

---

## Tear down

```bash
.\setup-demo.ps1 -Step reset
```

Destroys the CDK stack, stops and removes Docker containers and volumes, and cleans up the local `.git` and `.env`.

---

## Project structure

```
.
├── .docker/ci/          # Custom CI runner Dockerfile
├── .gitea/workflows/    # CI and CD pipeline definitions
├── .infrastructure/     # AWS CDK stack (S3, IAM, SSM)
├── app/                 # Laravel application code
├── resources/           # Views and frontend assets
├── routes/              # web.php, console.php
├── tests/               # PHPUnit test suites
├── docker-compose.yml   # Gitea + Postgres + Actions runner
├── runner-config.yaml   # Gitea runner configuration
└── setup-demo.ps1       # One-shot environment setup script
```

