# Deployment & Troubleshooting Guide

## Repository Structure

```text
lottery-app/
├── claims-service/
├── verification-service/
└── deploy.sh

terraform/
├── provider.tf
├── variables.tf
├── main.tf
├── outputs.tf
├── terraform.tfvars              
├── certs/                       
│   ├── private.key
│   └── certificate.crt
└── modules/
    ├── acm/
    ├── alb/
    ├── db_security/
    ├── ecr/
    ├── ecs/
    ├── monitoring/
    ├── networking/
    └── security/
```

## Prerequisites

### 1. Install:

- Terraform
- AWS CLI
- Docker Desktop
- Docker Buildx
- Git or GitHub Desktop
- OpenSSL

### 2. Verify:

```bash
terraform version
aws --version
docker --version
docker buildx version
```

### 3. Configure AWS:

```bash
aws configure
```
Provide:

- AWS Access Key
- AWS Secret Access Key
- Default region (`us-east-1`)
- Output format (`json`)
 
### 4. Confirm identity:

```bash
aws sts get-caller-identity
```

Required AWS permissions include:

- VPC, subnets, routes, security groups
- ECS and ECR
- ALB and target groups
- IAM roles and policies
- RDS
- Secrets Manager
- ACM
- CloudWatch Logs, dashboards, and alarms
- CloudTrail
- S3
- SNS

### 5. Enable Docker Buildx

The deployment uses multi-platform Docker builds for ECS Fargate compatibility (`linux/amd64`).

Verify:

```bash
docker buildx version
```

---

### 6. Certificate Setup for HTTPS

The ALB HTTPS listener uses a self-signed certificate imported into ACM through Terraform.

From the `terraform` directory:

```bash
cd terraform

mkdir certs

openssl req -x509 -nodes -days 365 \
-newkey rsa:2048 \
-keyout certs/private.key \
-out certs/certificate.crt
```

Expected local files:

```text
terraform/certs/private.key
terraform/certs/certificate.crt
```

Browser warnings are expected because this is a self-signed demo certificate. In production, we replace this with a public ACM certificate validated against a real domain.

### 7. Update terraform.tfvars

Update the following variables:

```hcl
alarm_email = "your-email@example.com"

enable_app_log_metric_filters = true
```
#### alarm_email:

Used for SNS notifications from CloudWatch alarms.
After deployment, AWS SNS sends a confirmation email which must be accepted to activate notifications.

#### enable_app_log_metric_filters:

Controls whether CloudWatch log metric filters are created.

- `true` → metric filters enabled
- `false` → metric filters skipped

### 8. Ensure Docker Is Running

Docker Desktop must be running before executing:

```bash
./deploy.sh
```


### 9. Make deploy.sh Executable

```bash
chmod +x deploy.sh
```


### 10. Confirm SNS Email Subscription

After deployment:

1. Check email inbox
2. Open AWS SNS confirmation email
3. Click **Confirm Subscription**

Without confirmation, CloudWatch alarms will not send notifications.


---

## Terraform Deployment Flow

Run Terraform commands from the `terraform` directory.

### 1. Format, initialize, and validate

```bash
terraform fmt -recursive
terraform init 
terraform validate
```

### 2. Deploy full infrastructure

Return to Terraform:

```bash
cd ../terraform
terraform plan
terraform apply
```

Type:
```text
<DB password here>
```

And, then type:

```text
yes
```

when prompted.

*NOTE: RDS provisioning may take 10–15 minutes. So, please wait patiently until you see the output mentioned under Post-Deployment Validations.*

### 3. Docker Build + Push Process

IMPORTANT:
Terraform creates the ECR repositories, but Docker images must still be built and pushed before ECS services can run successfully.

### 4. Run deploy.sh

NOTE: Update `AWS Account ID` in the placeholder in deploy.sh file inside the lottery-app folder.

Then in lottery-app directory run:

```bash
bash deploy.sh
```

Expected output:

```text
✅ Both images pushed to ECR
```

### 5. ECR repositories

Terraform automatically creates the following Amazon ECR repositories:

- verification-service
- claims-service

These repositories are used by ECS to pull Docker container images.

To verify:

1. Open AWS Console
2. Navigate to Amazon ECR
3. Verify above two repositories have been created

### 6. ECS Auto Deployment

After images are pushed successfully:

- ECS automatically retries failed task launches
- Tasks transition from:

```text
PENDING → RUNNING
```

- Target groups become healthy
- ALB becomes reachable
 

---

## Post-Deployment Validation

Expected outputs:

| Output | Description |
|---|---|
| `alb_dns_name` | Public DNS endpoint of the ALB |
| `claims_ecr_url` | Claims service ECR repository URL |
| `verification_ecr_url` | Verification service ECR repository URL |
| `db_secret_arn` | Secrets Manager secret ARN |
| `rds_endpoint` | RDS PostgreSQL endpoint |
| `cloudwatch_dashboard_name` | CloudWatch dashboard name |
| `cloudtrail_arn` | CloudTrail ARN |
| `cloudtrail_bucket_name` | S3 bucket storing CloudTrail logs |
| `sns_alarm_topic_arn` | SNS topic ARN |
| `vpc_flow_log_group_name` | VPC Flow Logs log group |
| `vpc_flow_log_id` | VPC Flow Logs resource ID |

## Access the application

```text
https://<alb_dns_name>/login
```

Health checks:

```text
https://<alb_dns_name>/health
https://<alb_dns_name>/claims/health
```

Expected response:

```json
{
  "db": "reachable",
  "status": "ok"
}
```

---

## Application Test Data

### Login

```text
Username: agent1
Password: Agent@123
```

### Ticket verification

Winning ticket, unregistered:

```text
Ticket Number: TKT-001-WIN
Date: March 15, 2026
```

Winning ticket, already registered:

```text
Ticket Number: TKT-002-WIN
Date: March 15, 2026
```

Losing ticket:

```text
Ticket Number: TKT-004-LOSE
Date: March 15, 2026
```

Ticket not found:

```text
Ticket Number: TKT-005-LOSE
Date: March 15, 2026
```

### Claims search

```text
Claimant name: Alice Johnson
Ticket Number: TKT-002-WIN
Claim ID: CLM-2026-000001
```

### Register unclaimed tickets

- Verify Winning ticket (unregistered)

```text
Ticket Number: TKT-001-WIN
Date: March 15, 2026
```
- Click Register
- Update details and confirm registration
  
---

## Database and Security Implementation

The platform uses **Amazon RDS PostgreSQL** as the backend relational database for lottery ticket verification, claimant registration, claim status tracking, QR confirmation records, and audit history.

---

## Logging and Monitoring

The monitoring implementation is located in:

```text
terraform/modules/monitoring/
├── main.tf
├── variables.tf
└── outputs.tf
```

The platform includes:

- ECS application logs in CloudWatch Logs
- CloudWatch dashboard
- CloudWatch alarms
- SNS alarm topic and optional email subscription
- CloudTrail activity logging
- VPC Flow Logs
- ALB access logs stored in S3

### CloudWatch Logs

Expected log groups:

```text
/ecs/verification-service
/ecs/claims-service
/aws/vpc/lottery-platform-flow-logs
```

### CloudWatch Dashboard

Expected dashboard:

```text
lottery-platform-operations
```

Dashboard widgets:

- ECS CPU utilization
- ECS memory utilization
- ALB 5XX errors
- Unhealthy target count
- RDS CPU utilization
- Application event metrics

### CloudWatch Alarms

Configured alarms include:

- Verification service CPU high
- Claims service CPU high
- Verification service memory high
- Claims service memory high
- ALB 5XX high
- Verification unhealthy targets
- Claims unhealthy targets
- RDS CPU high
- Login fail spike, if application metric filters are enabled

### Application Log Metric Filters

Metric filters are controlled by:

```hcl
enable_app_log_metric_filters = false
```

Keep it `false` during first deployment. After the ECS log groups exist, set:

```hcl
enable_app_log_metric_filters = true
```

Then run:

```bash
terraform plan
terraform apply
```

*NOTE: The Application Events dashboard only shows data when the app emits logs matching those exact patterns.*

### SNS Email Alerts

Set locally:

```hcl
alarm_email = "your-email@example.com"
```

After Terraform applies, confirm the email from AWS SNS. Alarm emails will not be delivered until the subscription is confirmed.

### Activity / Load Demonstration

Generate traffic:

```powershell
$ALB = "https://<alb-dns-name>"

for ($i=1; $i -le 100; $i++) {
  curl.exe -k -s -o NUL "$ALB/health"
}
```

More load:

```powershell
$ALB = "https://<alb-dns-name>"

$jobs = 1..10 | ForEach-Object {
  Start-Job -ScriptBlock {
    param($url)
    for ($i=1; $i -le 50; $i++) {
      curl.exe -k -s -o NUL "$url/health"
    }
  } -ArgumentList $ALB
}

Wait-Job $jobs
Receive-Job $jobs
Remove-Job $jobs
```

*NOTE: Wait 3–10 minutes, then refresh the CloudWatch dashboard using the `Last 1 hour` time range.*

---

## Troubleshooting

### ALB returns 503

Possible causes:

- ECS tasks are not running
- ECR repositories do not contain images
- Target group health checks are failing
- Container failed to start

Checks:

```bash
aws ecs describe-services --cluster lottery-platform-cluster --services verification-service claims-service --region us-east-1
```

Check target groups:

```text
EC2 → Target Groups
```

Check logs:

```text
CloudWatch → Logs → /ecs/verification-service
CloudWatch → Logs → /ecs/claims-service
```

---

### ALB returns 404

Possible causes:

- ALB listener rule path mismatch
- Application route missing
- Wrong service URL
- Duplicate `/claims` path

Recommended routes:

```text
/login
/verify
/claims/search
/claims/new/<ticket_id>
/health
/claims/health
```

---

### Certificate files missing

Error:

```text
Invalid value for path parameter: no file exists at certs/private.key
```

Fix:

```bash
cd terraform
mkdir -p certs
MSYS_NO_PATHCONV=1 openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/private.key \
  -out certs/certificate.crt \
  -subj "/CN=lottery-platform.local"
```

---

### Secret already scheduled for deletion

Error:

```text
You can't create this secret because a secret with this name is already scheduled for deletion
```

Restore:

```bash
aws secretsmanager restore-secret --secret-id lottery-platform-db-secret --region us-east-1
```

Or force-delete and recreate:

```bash
aws secretsmanager delete-secret \
  --secret-id lottery-platform-db-secret \
  --force-delete-without-recovery \
  --region us-east-1
```

---

### KMS key pending deletion

Error:

```text
Secrets Manager can't decrypt the secret value because the KMS key is pending deletion
```

Fix:

```bash
aws kms cancel-key-deletion --key-id <key-id> --region us-east-1
aws kms enable-key --key-id <key-id> --region us-east-1
```

---

## Destroy / Cleanup

Destroy the environment to avoid AWS charges.

From `terraform`:

```bash
terraform destroy
```

If ECR blocks destroy due to images:

```bash
aws ecr batch-delete-image --repository-name verification-service --image-ids imageTag=latest --region us-east-1
aws ecr batch-delete-image --repository-name claims-service --image-ids imageTag=latest --region us-east-1
```

If S3 buckets block destroy:

```bash
aws s3 rm s3://<cloudtrail-bucket-name> --recursive
aws s3 rm s3://<alb-access-logs-bucket-name> --recursive
```

Then rerun:

```bash
terraform destroy
```

After destroy, manually verify deletion of:

- ECS services and cluster
- ALB and target groups
- NAT Gateway
- RDS
- VPC
- ECR repositories/images
- CloudWatch log groups
- CloudTrail trail
- S3 log buckets
- SNS topic
- Secrets Manager secret

---

## Useful Commands

Check AWS identity:

```bash
aws sts get-caller-identity
```

Check ECR images:

```bash
aws ecr list-images --repository-name verification-service --region us-east-1
aws ecr list-images --repository-name claims-service --region us-east-1
```

Check ECS services:

```bash
aws ecs list-services --cluster lottery-platform-cluster --region us-east-1
```

Describe ECS services:

```bash
aws ecs describe-services --cluster lottery-platform-cluster --services verification-service claims-service --region us-east-1
```

Get ALB DNS:

```bash
terraform output alb_dns_name
```
