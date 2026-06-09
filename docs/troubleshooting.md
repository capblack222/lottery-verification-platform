# Troubleshooting Guide

> Diagnose and resolve failures in the Lottery Verification Platform.

| Document | Purpose |
|---|---|
| [Deployment Guide](./deployment_guide.md) | Prerequisites, deployment steps, validation, cleanup |
| [Operations Guide](./operations_guide.md) | CloudWatch, alarms, monitoring, load testing |
| **Troubleshooting Guide** ← you are here | Failure diagnosis, resolution, useful commands |

---

## How to Use This Guide

Each scenario is structured as:

1. **Symptoms** — what you observe
2. **Root causes** — likely explanations
3. **Diagnosis** — commands to confirm the cause
4. **Resolution** — steps to fix it

Start from what you observe, not from what you assume is wrong.

---

## Scenarios

### ECS Tasks Stuck in PENDING

**Symptoms**

- `terraform apply` completes successfully
- `bash deploy.sh` completes with `✅ Both images pushed to ECR`
- ECS console shows tasks in `PENDING` state for more than 5 minutes
- ALB health checks fail — no healthy targets

**Root causes**

- Images were not pushed to ECR before ECS launched tasks (most common on first deploy)
- Security group rules block ECS task from pulling images from ECR
- ECS task execution role lacks ECR pull permission
- Incorrect image URI in the ECS task definition

**Diagnosis**

```bash
# Check ECS service events for the reason tasks are stuck
aws ecs describe-services \
  --cluster lottery-platform-cluster \
  --services verification-service \
  --region us-east-1 \
  --query 'services[0].events[:5]'

# Verify images exist in ECR
aws ecr list-images --repository-name verification-service --region us-east-1
aws ecr list-images --repository-name claims-service --region us-east-1

# Check task stopped reason (if tasks are stopping and restarting)
aws ecs list-tasks \
  --cluster lottery-platform-cluster \
  --service-name verification-service \
  --desired-status STOPPED \
  --region us-east-1

# Then describe a stopped task to get the stopCode and stoppedReason
aws ecs describe-tasks \
  --cluster lottery-platform-cluster \
  --tasks <task-id> \
  --region us-east-1 \
  --query 'tasks[0].{stopCode:stopCode,reason:stoppedReason,containers:containers[*].{name:name,reason:reason,exit:exitCode}}'
```

**Resolution**

If images are missing from ECR:

```bash
cd lottery-app
bash deploy.sh
```

ECS retries automatically after images appear. Tasks should transition to `RUNNING` within 2–3 minutes.

If tasks are stopping due to health check failures, see [Health Checks Failing](#health-checks-failing).

---

### Health Checks Failing

**Symptoms**

- ECS tasks reach `RUNNING` but immediately stop
- ALB shows `0` healthy targets in the target group
- `curl -k https://<alb>/health` times out or returns `502 Bad Gateway`
- ECS service events mention `Task failed ELB health checks`

**Root causes**

- Application is crashing on startup (usually a missing secret or DB connection failure)
- Security group blocks ALB → ECS traffic on port 5000
- Database is not reachable (private subnet routing issue)
- Secrets Manager secret is malformed or inaccessible

**Diagnosis**

```bash
# Check application logs — crash reason is almost always here
aws logs tail /ecs/verification-service --follow --region us-east-1

# Check ECS task stopped reason
aws ecs describe-tasks \
  --cluster lottery-platform-cluster \
  --tasks <task-id> \
  --region us-east-1 \
  --query 'tasks[0].{stopCode:stopCode,reason:stoppedReason}'

# Verify DB secret is accessible
aws secretsmanager get-secret-value \
  --secret-id $(cd terraform && terraform output -raw db_secret_arn) \
  --region us-east-1 \
  --query 'SecretString'

# Verify RDS endpoint is present
cd terraform && terraform output rds_endpoint
```

**Resolution**

If logs show `SecretNotFoundException` or `AccessDeniedException`:

- Verify the IAM task execution role has `secretsmanager:GetSecretValue` permission on the correct ARN
- Confirm the secret ARN matches what `terraform output db_secret_arn` returns

If logs show database connection errors:

- Confirm the RDS security group allows inbound traffic from the ECS task security group on port 5432
- These security groups are managed by Terraform — re-running `terraform apply` will reconcile any drift

---

### Redis Unreachable

**Symptoms**

- `/health` returns `{"status":"ok","db":"reachable","redis":"unreachable"}` or `"redis":"disabled"`
- Verification requests succeed but latency is consistently high (80–150ms instead of 2–10ms for repeated tickets)
- CloudWatch `CacheHit` metric is 0; `CacheMiss` is climbing
- Redis CPU or connection alarms may be firing

**Root causes**

- `REDIS_URL` environment variable is missing or incorrect in the ECS task definition
- Security group blocks ECS → ElastiCache traffic on port 6379
- ElastiCache cluster is in a different VPC or subnet than expected
- Redis endpoint changed (unlikely but possible after a `terraform destroy` + `apply` cycle)

**Diagnosis**

```bash
# Check Redis endpoint from Terraform
cd terraform
terraform output redis_endpoint
terraform output redis_url

# Check health endpoint — redis field tells you current state
curl -k https://$(terraform output -raw alb_dns_name)/health

# Check application logs for Redis connection errors
aws logs filter-log-events \
  --log-group-name /ecs/verification-service \
  --filter-pattern "redis" \
  --region us-east-1 \
  --query 'events[*].message'

# Check ElastiCache cluster status
aws elasticache describe-cache-clusters \
  --region us-east-1 \
  --query 'CacheClusters[*].{Id:CacheClusterId,Status:CacheClusterStatus,Engine:Engine}'
```

**Resolution**

Redis failures are caught and logged; they never surface as errors to the user. The application degrades gracefully — all verifications still succeed, just without caching.

To restore Redis connectivity:

1. Confirm `redis_url` from `terraform output redis_url` is non-empty
2. Confirm ElastiCache cluster status is `available`
3. Force a service redeployment to pick up the correct endpoint:

```bash
aws ecs update-service \
  --cluster lottery-platform-cluster \
  --service verification-service \
  --force-new-deployment \
  --region us-east-1
```

If the ElastiCache cluster is not `available`, check the AWS console under ElastiCache → Redis clusters.

---

### `terraform apply` Fails on Metric Filters

**Symptoms**

- `terraform apply` errors partway through with something like:
  `Error: creating CloudWatch Log Metric Filter: ResourceNotFoundException: The specified log group does not exist`
- Happens on a first deployment or after `terraform destroy` + `apply`

**Root cause**

`enable_app_log_metric_filters = true` in `terraform.tfvars` on a first deploy. ECS log groups (`/ecs/verification-service`, `/ecs/claims-service`) don't exist until ECS tasks start and emit their first logs. Terraform tries to create metric filters against log groups that don't exist yet.

**Diagnosis**

```bash
# Check whether the log groups exist
aws logs describe-log-groups \
  --log-group-name-prefix /ecs \
  --region us-east-1 \
  --query 'logGroups[*].logGroupName'
```

If the output is empty or missing `/ecs/verification-service`, the log groups don't exist yet.

**Resolution**

Set `enable_app_log_metric_filters = false` in `terraform.tfvars`, then rerun:

```bash
terraform apply
```

After ECS tasks are `RUNNING` and log groups exist, enable filters:

```hcl
# terraform.tfvars
enable_app_log_metric_filters = true
```

```bash
terraform apply
```

---

### `terraform destroy` Blocked by ECR Images

**Symptoms**

- `terraform destroy` fails with:
  `RepositoryNotEmptyException: The repository with name 'verification-service' in registry ... cannot be deleted because it contains images`

**Root cause**

Terraform's ECR resource does not automatically delete images before deleting the repository. Images must be deleted first.

**Resolution**

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

Then rerun:

```bash
terraform destroy
```

---

### `terraform destroy` Blocked by Non-Empty S3 Buckets

**Symptoms**

- `terraform destroy` fails with:
  `BucketNotEmpty: The bucket you tried to delete is not empty`

**Root cause**

CloudTrail and ALB access logs have been written to S3. S3 buckets must be empty before Terraform can delete them.

**Resolution**

```bash
# Get bucket names
cd terraform
terraform output cloudtrail_bucket_name

# Empty the buckets (replace with actual names)
aws s3 rm s3://<cloudtrail-bucket-name> --recursive
aws s3 rm s3://<alb-access-logs-bucket-name> --recursive
```

Then rerun:

```bash
terraform destroy
```

---

### DLQ Has Messages

**Symptoms**

- `ApproximateNumberOfMessages` > 0 on the DLQ (`lottery-claims-dlq`)
- CloudWatch logs show repeated SQS message failures for WINNER verifications
- WINNER outcomes are processing correctly (verification works) but SQS delivery is failing

**Root causes**

- Claims service is not running and cannot process SQS messages (most common)
- SQS IAM policy does not grant the ECS task role `ReceiveMessage`/`DeleteMessage`
- Message visibility timeout (120s) is being exceeded by claims processing time
- Claims service is crashing during message processing, causing repeated redelivery until `maxReceiveCount=3` is exhausted

**Diagnosis**

```bash
# Check DLQ message count
aws sqs get-queue-attributes \
  --queue-url $(aws sqs get-queue-url \
    --queue-name lottery-claims-dlq \
    --region us-east-1 \
    --query 'QueueUrl' --output text) \
  --attribute-names ApproximateNumberOfMessages \
  --region us-east-1

# Check claims service ECS status
aws ecs describe-services \
  --cluster lottery-platform-cluster \
  --services claims-service \
  --region us-east-1 \
  --query 'services[0].{desired:desiredCount,running:runningCount,status:status}'

# Check claims service logs for processing errors
aws logs tail /ecs/claims-service --follow --region us-east-1
```

**Resolution**

If the claims service is not running, restart it:

```bash
aws ecs update-service \
  --cluster lottery-platform-cluster \
  --service claims-service \
  --force-new-deployment \
  --region us-east-1
```

DLQ messages are retained for 14 days. Once the claims service is stable, messages can be redriven from DLQ to the main queue for reprocessing via the AWS console: SQS → `lottery-claims-dlq` → Start DLQ Redrive.

---

### Alarm Emails Not Arriving

**Symptoms**

- CloudWatch alarms are in `ALARM` state (visible in console)
- No email notifications received

**Root causes**

- SNS subscription has not been confirmed (most common)
- Email landed in spam folder
- `alarm_email` in `terraform.tfvars` is incorrect

**Diagnosis**

```bash
# Check subscription status — should be "Confirmed"
aws sns list-subscriptions-by-topic \
  --topic-arn $(cd terraform && terraform output -raw sns_alarm_topic_arn) \
  --region us-east-1 \
  --query 'Subscriptions[*].{Protocol:Protocol,Endpoint:Endpoint,Status:SubscriptionArn}'
```

If `SubscriptionArn` shows `PendingConfirmation` instead of an ARN, the subscription email was not confirmed.

**Resolution**

Check your inbox and spam folder for an email from `AWS Notifications` with subject `AWS Notification - Subscription Confirmation`. Click **Confirm Subscription**.

If the email is not found, resubscribe manually:

```bash
aws sns subscribe \
  --topic-arn $(cd terraform && terraform output -raw sns_alarm_topic_arn) \
  --protocol email \
  --notification-endpoint your-email@example.com \
  --region us-east-1
```

---

### High Verification Latency

**Symptoms**

- `VerificationLatency` on the CloudWatch dashboard shows consistently high p99 (>200ms)
- No improvement after repeated requests for the same ticket (expected cache hits)
- `/health` shows `"redis":"unreachable"` or `"redis":"disabled"`

**Root causes**

- Redis is unreachable — all verifications are going to the database
- Cache TTL has expired and the cache is cold
- WINNER tickets — these intentionally bypass the cache on every request

**Diagnosis**

```bash
# Check health endpoint redis status
curl -k https://$(cd terraform && terraform output -raw alb_dns_name)/health

# Check CacheHit vs CacheMiss counts
aws cloudwatch get-metric-statistics \
  --namespace LotteryPlatform/VerificationService \
  --metric-name CacheHit \
  --start-time $(date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ') \
  --end-time $(date -u '+%Y-%m-%dT%H:%M:%SZ') \
  --period 300 \
  --statistics Sum \
  --region us-east-1
```

**Resolution**

If Redis is unreachable: see [Redis Unreachable](#redis-unreachable).

If the cache is cold: latency will return to 2–10ms after the first verification of each ticket warms the cache. The cache TTL is 1 hour.

If all requests are WINNER tickets: this is expected behavior. WINNER tickets bypass caching by design — the application always performs a fresh DB query and publishes to SQS to ensure claim registration integrity.

---

### Login Page Returns 502

**Symptoms**

- `https://<alb>/login` returns `502 Bad Gateway`
- `curl -k https://<alb>/health` also fails or returns 502

**Root causes**

- Both ECS tasks for `verification-service` are stopped
- ALB target group has no healthy targets
- Tasks are in `PENDING` or repeatedly crashing

**Diagnosis**

```bash
# Check running task count
aws ecs describe-services \
  --cluster lottery-platform-cluster \
  --services verification-service \
  --region us-east-1 \
  --query 'services[0].{desired:desiredCount,running:runningCount,status:status}'

# Check recent service events
aws ecs describe-services \
  --cluster lottery-platform-cluster \
  --services verification-service \
  --region us-east-1 \
  --query 'services[0].events[:5]'
```

**Resolution**

If `runningCount` is 0 and `desiredCount` > 0:

1. Check logs for crash reason: `aws logs tail /ecs/verification-service --region us-east-1`
2. Force redeployment: `aws ecs update-service --cluster lottery-platform-cluster --service verification-service --force-new-deployment --region us-east-1`
3. If ECR images are missing, rebuild and push: `cd lottery-app && bash deploy.sh`

---

## Useful Commands

### Infrastructure

```bash
# All Terraform outputs
cd terraform && terraform output

# Individual outputs
terraform output alb_dns_name
terraform output redis_endpoint
terraform output redis_url
terraform output sqs_queue_url
terraform output sqs_dlq_arn
terraform output cloudwatch_dashboard_name
terraform output sns_alarm_topic_arn
terraform output cloudtrail_bucket_name
terraform output vpc_flow_log_group_name

# Verify AWS identity
aws sts get-caller-identity
```

### ECS

```bash
# List running tasks
aws ecs list-tasks \
  --cluster lottery-platform-cluster \
  --service-name verification-service \
  --region us-east-1

# Service status (desired vs running)
aws ecs describe-services \
  --cluster lottery-platform-cluster \
  --services verification-service claims-service \
  --region us-east-1 \
  --query 'services[*].{name:serviceName,desired:desiredCount,running:runningCount}'

# Tail live logs
aws logs tail /ecs/verification-service --follow --region us-east-1
aws logs tail /ecs/claims-service --follow --region us-east-1

# Force redeployment
aws ecs update-service \
  --cluster lottery-platform-cluster \
  --service verification-service \
  --force-new-deployment \
  --region us-east-1
```

### ECR

```bash
# List images
aws ecr list-images --repository-name verification-service --region us-east-1
aws ecr list-images --repository-name claims-service --region us-east-1

# Delete images (before terraform destroy)
aws ecr batch-delete-image \
  --repository-name verification-service \
  --image-ids imageTag=latest \
  --region us-east-1
```

### SQS

```bash
# Main queue depth
aws sqs get-queue-attributes \
  --queue-url $(cd terraform && terraform output -raw sqs_queue_url) \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --region us-east-1

# DLQ depth
aws sqs get-queue-attributes \
  --queue-url $(aws sqs get-queue-url \
    --queue-name lottery-claims-dlq \
    --region us-east-1 \
    --query 'QueueUrl' --output text) \
  --attribute-names ApproximateNumberOfMessages \
  --region us-east-1
```

### Application Health

```bash
ALB=$(cd terraform && terraform output -raw alb_dns_name)

# Verification service health (includes Redis status)
curl -k https://$ALB/health

# Claims service health
curl -k https://$ALB/claims/health

# Quick response time check
time curl -sk https://$ALB/health
```

### CloudWatch

```bash
# List all alarm states
aws cloudwatch describe-alarms \
  --region us-east-1 \
  --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue}' \
  --output table

# Cache hit rate (last hour)
aws cloudwatch get-metric-statistics \
  --namespace LotteryPlatform/VerificationService \
  --metric-name CacheHitRate \
  --start-time $(date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ') \
  --end-time $(date -u '+%Y-%m-%dT%H:%M:%SZ') \
  --period 300 \
  --statistics Average \
  --region us-east-1

# Verification latency (last hour)
aws cloudwatch get-metric-statistics \
  --namespace LotteryPlatform/VerificationService \
  --metric-name VerificationLatency \
  --start-time $(date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ') \
  --end-time $(date -u '+%Y-%m-%dT%H:%M:%SZ') \
  --period 300 \
  --statistics p50 p99 \
  --region us-east-1
```

### ElastiCache

```bash
# List Redis clusters and status
aws elasticache describe-cache-clusters \
  --region us-east-1 \
  --query 'CacheClusters[*].{Id:CacheClusterId,Status:CacheClusterStatus,Node:CacheNodeType}'
```

### SNS

```bash
# Check subscription status
aws sns list-subscriptions-by-topic \
  --topic-arn $(cd terraform && terraform output -raw sns_alarm_topic_arn) \
  --region us-east-1
```
