# Deployment Guide

> Deploy the Lottery Verification Platform to AWS using Terraform and Docker.

| Document | Purpose |
|---|---|
| **Deployment Guide** ← you are here | Prerequisites, deployment steps, validation, cleanup |
| [Operations Guide](./operations_guide.md) | CloudWatch, alarms, monitoring, load testing |
| [Troubleshooting Guide](./troubleshooting.md) | Failure diagnosis, resolution, useful commands |

---

## Quick Start

For engineers with AWS CLI, Terraform ≥ 1.0, and Docker Desktop already configured. Follow the full guide below if you need additional context at any step.

```bash
# 1. Generate TLS certificate (from repo root)
cd terraform && mkdir -p certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/private.key \
  -out certs/certificate.crt

# 2. Configure variables
#    Set alarm_email and confirm enable_app_log_metric_filters = false
vi terraform.tfvars

# 3. Deploy infrastructure (~20–35 min, RDS takes the longest)
terraform fmt -recursive && terraform init && terraform validate
terraform plan
terraform apply   # enter DB password and 'yes' when prompted

# 4. Update AWS Account ID in deploy.sh, then build and push images
cd ../lottery-app
vi deploy.sh      # replace <ENTER_ACCNT_ID> with your AWS account ID
bash deploy.sh

# 5. Validate
ALB=$(cd ../terraform && terraform output -raw alb_dns_name)
curl -k https://$ALB/health
# Expected: {"status":"ok","db":"reachable","redis":"reachable"}

# 6. Access the platform
echo "https://$ALB/login"
```

> [!IMPORTANT]
> `enable_app_log_metric_filters` must be `false` on first deploy. ECS log groups do not exist until after ECS tasks start. Enabling filters before that will cause Terraform to fail. See [Step 7](#7-update-terraformtfvars) and [Enable Log Metric Filters](#enable-log-metric-filters).

---

## Deployment Overview

This guide deploys:

- A **multi-AZ VPC** with public, private app, and private DB subnet tiers
- Two **ECS Fargate** services (`verification-service`, `claims-service`)
- **Amazon RDS PostgreSQL** in private DB subnets
- **ElastiCache Redis** for ticket verification caching
- **Amazon SQS** with Dead Letter Queue for async WINNER event processing
- **Application Load Balancer** with HTTPS termination
- Full **observability stack** — CloudWatch, CloudTrail, VPC Flow Logs, SNS, S3

### Deployment Timeline

| Stage | What happens | Approximate duration |
|---|---|---|
| `terraform init` | Downloads providers and modules | ~30 seconds |
| Networking | VPC, subnets, NAT Gateway, security groups | 2–3 minutes |
| **RDS provisioning** | PostgreSQL instance creation — the slowest step | **10–15 minutes** |
| Remaining infrastructure | ECS, ALB, ECR, ElastiCache, SQS, monitoring | 3–5 minutes |
| Docker build + push | Multi-platform `linux/amd64` builds for both services | 3–7 minutes |
| ECS stabilization | Tasks pull images, initialize DB, pass health checks | 2–5 minutes |
| **Total** | | **~20–35 minutes** |

### Deployment Dependency Order

The deployment has strict sequencing requirements. Violating this order causes failures.

```text
Step 1 — terraform apply
         Provisions all AWS infrastructure including ECR repositories
              │
              ▼
Step 2 — bash deploy.sh
         Builds Docker images and pushes to ECR
         ⚠ ECR repositories must exist before this step
              │
              ▼
Step 3 — ECS auto-pull and start
         ECS tasks pull images from ECR and start
         ⚠ Images must exist in ECR before tasks can become RUNNING
              │
              ▼
Step 4 — ECS log groups created
         Log groups appear once tasks emit their first logs
         ⚠ Metric filters require log groups to exist
              │
              ▼
Step 5 — Enable metric filters (second terraform apply)
         enable_app_log_metric_filters = true
              │
              ▼
Step 6 — SNS subscription confirmation
         Alarm notifications require manual email confirmation
         ⚠ Alarms fire but emails are not delivered until confirmed
```

---

## Prerequisites

### 1. Install

- Terraform ≥ 1.0
- AWS CLI v2
- Docker Desktop
- Docker Buildx (bundled with Docker Desktop)
- Git
- OpenSSL

### 2. Verify

```bash
terraform version
aws --version
docker --version
docker buildx version
```

### 3. Configure AWS

```bash
aws configure
```

Provide:

- AWS Access Key ID
- AWS Secret Access Key
- Default region: `us-east-1`
- Output format: `json`

### 4. Confirm identity

```bash
aws sts get-caller-identity
```

Required AWS permissions:

- VPC, subnets, routes, security groups
- ECS and ECR
- ALB and target groups
- IAM roles and policies
- RDS
- Secrets Manager
- ACM
- ElastiCache (Redis)
- SQS
- CloudWatch Logs, dashboards, and alarms
- CloudTrail
- S3
- SNS

### 5. Enable Docker Buildx

The deployment uses multi-platform Docker builds for ECS Fargate (`linux/amd64` compatibility).

```bash
docker buildx version
```

### 6. Certificate Setup for HTTPS

The ALB HTTPS listener requires a certificate imported into ACM. This guide uses a self-signed certificate for demo purposes. In production, replace with a domain-validated public ACM certificate.

From the `terraform` directory:

```bash
cd terraform

mkdir -p certs

openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout certs/private.key \
  -out certs/certificate.crt
```

Expected files:

```text
terraform/certs/private.key
terraform/certs/certificate.crt
```

> **Note:** Browsers will show a security warning for self-signed certificates. This is expected in demo deployments.

### 7. Update terraform.tfvars

```hcl
alarm_email = "your-email@example.com"

enable_app_log_metric_filters = false
```

**`alarm_email`** — used for SNS CloudWatch alarm notifications. AWS sends a confirmation email after deployment that must be accepted before alerts are delivered.

**`enable_app_log_metric_filters`** — controls CloudWatch log metric filter creation.

> [!IMPORTANT]
> Set `enable_app_log_metric_filters = false` for the first deployment. The ECS log groups (`/ecs/verification-service`, `/ecs/claims-service`) do not exist until ECS tasks start. Creating metric filters against non-existent log groups will cause `terraform apply` to fail. See [Enable Log Metric Filters](#enable-log-metric-filters) for the two-step process.

### 8. Ensure Docker Is Running

Docker Desktop must be running before executing `deploy.sh`.

### 9. Make deploy.sh Executable

```bash
chmod +x lottery-app/deploy.sh
```

### 10. Confirm SNS Email Subscription

After deployment, AWS SNS sends a subscription confirmation email to `alarm_email`.

1. Check your inbox for an email from `AWS Notifications`
2. Click **Confirm Subscription**

CloudWatch alarms will fire but email notifications will not be delivered until the subscription is confirmed.

---

## Deployment Steps

Run all Terraform commands from the `terraform` directory.

### 1. Format, Initialize, and Validate

```bash
terraform fmt -recursive
terraform init
terraform validate
```

### 2. Deploy Full Infrastructure

```bash
terraform plan
terraform apply
```

Enter the database password when prompted:

```text
var.db_password
  Enter a value: <your-db-password>
```

Then confirm:

```text
Do you want to perform these actions?
  Enter a value: yes
```

> **Note:** RDS provisioning takes 10–15 minutes. Wait until Terraform outputs are printed before proceeding.

### 3. Docker Build and Push

> **Important:** Terraform creates the ECR repositories during `terraform apply`. Docker images must be built and pushed to ECR before ECS services can run successfully. This is a hard dependency — do not skip or reorder.

### 4. Run deploy.sh

Open `lottery-app/deploy.sh` and replace the AWS Account ID placeholder:

```bash
AWS_ACCOUNT_ID="<ENTER_ACCNT_ID>"
```

Replace with your actual 12-digit AWS account ID:

```bash
AWS_ACCOUNT_ID="123456789012"
```

From the `lottery-app` directory:

```bash
bash deploy.sh
```

Expected output:

```text
✅ Both images pushed to ECR
```

### 5. Verify ECR Repositories

Terraform creates these repositories automatically:

- `verification-service`
- `claims-service`

To verify images are present:

```bash
aws ecr list-images --repository-name verification-service --region us-east-1
aws ecr list-images --repository-name claims-service --region us-east-1
```

Both should return at least one image with tag `latest`.

### 6. ECS Auto Deployment

After images are pushed, ECS automatically retries pending task launches:

```text
PENDING → RUNNING
```

Once tasks are running:

- Target group health checks pass
- ALB begins routing traffic

ECS stabilization typically takes 2–5 minutes. Proceed to validation once tasks show `RUNNING`.

---

## Post-Deployment Validation

Work through each section in order. All checks should pass before considering the deployment complete.

### Infrastructure

Verify all Terraform outputs are present:

```bash
terraform output
```

Expected outputs:

| Output | What to check |
|---|---|
| `alb_dns_name` | Non-empty DNS hostname |
| `verification_ecr_url` | ECR URL for verification service |
| `claims_ecr_url` | ECR URL for claims service |
| `db_secret_arn` | Secrets Manager ARN |
| `rds_endpoint` | RDS hostname |
| `redis_endpoint` | ElastiCache hostname |
| `redis_url` | Full `redis://` URL |
| `sqs_queue_url` | SQS queue HTTPS URL |
| `sqs_dlq_arn` | DLQ ARN |
| `cloudwatch_dashboard_name` | Dashboard name |
| `cloudtrail_arn` | CloudTrail ARN |
| `cloudtrail_bucket_name` | S3 bucket name |
| `sns_alarm_topic_arn` | SNS topic ARN |
| `vpc_flow_log_group_name` | Log group name |
| `vpc_flow_log_id` | Flow log resource ID |

### ECS Services

```bash
aws ecs describe-services \
  --cluster lottery-platform-cluster \
  --services verification-service claims-service \
  --region us-east-1 \
  --query 'services[*].{name:serviceName,desired:desiredCount,running:runningCount,status:status}'
```

**Success criteria:** both services show `"status": "ACTIVE"` and `runningCount` equals `desiredCount`.

### ALB and Application

```bash
ALB=$(terraform output -raw alb_dns_name)

# Verification service health
curl -k https://$ALB/health

# Claims service health
curl -k https://$ALB/claims/health
```

**Success criteria:**

```json
{
  "status": "ok",
  "db": "reachable",
  "redis": "reachable"
}
```

If `"redis"` shows `"unreachable"` or `"disabled"`, see the [Troubleshooting Guide](./troubleshooting.md#redis-unreachable).

### Application Login

Navigate to:

```text
https://<alb_dns_name>/login
```

Log in with the agent test credentials:

```text
Username: agent1
Password: Agent@123
```

**Success criteria:** redirected to the ticket verification screen without error.

### SQS Queue

```bash
aws sqs get-queue-attributes \
  --queue-url $(terraform output -raw sqs_queue_url) \
  --attribute-names QueueArn ApproximateNumberOfMessages \
  --region us-east-1
```

**Success criteria:** command returns queue ARN and `ApproximateNumberOfMessages` (expected `0` on a fresh deployment).

### Observability

```bash
aws logs describe-log-groups \
  --log-group-name-prefix /ecs \
  --region us-east-1 \
  --query 'logGroups[*].logGroupName'
```

**Success criteria:** output includes both:

```json
["/ecs/claims-service", "/ecs/verification-service"]
```

Then confirm the CloudWatch dashboard exists:

```bash
terraform output cloudwatch_dashboard_name
```

Navigate to CloudWatch → Dashboards in the AWS console and confirm `lottery-platform-operations` is populated with metrics.

---

## Deployment Success Checklist

Use this checklist to confirm operational readiness before considering deployment complete.

- [ ] All 15 Terraform outputs are present (`terraform output`)
- [ ] Both ECR repositories contain a `latest` image
- [ ] `verification-service` ECS tasks: `runningCount` = `desiredCount`
- [ ] `claims-service` ECS tasks: `runningCount` = `desiredCount`
- [ ] `/health` returns `{"status":"ok","db":"reachable","redis":"reachable"}`
- [ ] `/claims/health` returns `{"status":"ok","db":"reachable"}`
- [ ] Login page accessible at `https://<alb>/login`
- [ ] Ticket verification returns expected outcome for `TKT-001-WIN`
- [ ] SQS queue exists and is reachable
- [ ] CloudWatch log groups `/ecs/verification-service` and `/ecs/claims-service` exist
- [ ] CloudWatch dashboard `lottery-platform-operations` is populated
- [ ] SNS subscription confirmation email received and confirmed

---

## Enable Log Metric Filters

This is a **two-step process** by design. Log metric filters require the ECS log groups to exist first.

**Step 1** (first `terraform apply` — already done): `enable_app_log_metric_filters = false`

**Step 2** — after ECS tasks are running and log groups exist:

```hcl
# terraform.tfvars
enable_app_log_metric_filters = true
```

```bash
terraform plan
terraform apply
```

This creates CloudWatch metric filters for `LOGIN_FAIL`, `CLAIM_REGISTERED`, and `DUPLICATE_CLAIM_ATTEMPT` log patterns and enables the Application Events dashboard panel.

---

## Application Test Data

### Login

```text
Username: agent1
Password: Agent@123
```

### Ticket Verification

| Scenario | Ticket Number | Date |
|---|---|---|
| Winning — not yet registered | `TKT-001-WIN` | March 15, 2026 |
| Winning — already registered | `TKT-002-WIN` | March 15, 2026 |
| Losing ticket | `TKT-004-LOSE` | March 15, 2026 |
| Ticket not found | `TKT-005-LOSE` | March 15, 2026 |

### Claims Search

```text
Claimant name:  Alice Johnson
Ticket Number:  TKT-002-WIN
Claim ID:       CLM-2026-000001
```

### Register an Unclaimed Winning Ticket

1. Verify `TKT-001-WIN` on `March 15, 2026`
2. Click **Register**
3. Complete claimant details and confirm

---

## Destroy / Cleanup

> [!WARNING]
> NAT Gateway, ALB, RDS, ElastiCache, and Fargate accrue charges continuously while running. Destroy the stack immediately after use.

From the `terraform` directory:

```bash
terraform destroy
```

Enter the database password and `yes` when prompted.

**If ECR blocks destroy** (repositories contain images):

```bash
aws ecr batch-delete-image \
  --repository-name verification-service \
  --image-ids imageTag=latest \
  --region us-east-1

aws ecr batch-delete-image \
  --repository-name claims-service \
  --image-ids imageTag=latest \
  --region us-east-1
```

**If S3 buckets block destroy** (buckets contain log objects):

```bash
aws s3 rm s3://<cloudtrail-bucket-name> --recursive
aws s3 rm s3://<alb-access-logs-bucket-name> --recursive
```

Then rerun:

```bash
terraform destroy
```

### Post-Destroy Verification

Manually confirm the following resources are deleted in the AWS console:

| Resource | Where to check |
|---|---|
| ECS services and cluster | ECS → Clusters |
| ALB and target groups | EC2 → Load Balancers / Target Groups |
| NAT Gateway | VPC → NAT Gateways |
| RDS instance | RDS → Databases |
| ElastiCache Redis cluster | ElastiCache → Redis clusters |
| SQS queue and DLQ | SQS → Queues |
| VPC | VPC → Your VPCs |
| ECR repositories | ECR → Repositories |
| CloudWatch log groups | CloudWatch → Log groups |
| CloudTrail trail | CloudTrail → Trails |
| S3 log buckets | S3 → Buckets |
| SNS topic | SNS → Topics |
| Secrets Manager secret | Secrets Manager → Secrets |
