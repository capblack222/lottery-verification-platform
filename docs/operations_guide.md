# Operations Guide

> Monitoring, observability, and operational procedures for the Lottery Verification Platform.

| Document | Purpose |
|---|---|
| [Deployment Guide](./deployment_guide.md) | Prerequisites, deployment steps, validation, cleanup |
| **Operations Guide** ← you are here | CloudWatch, alarms, monitoring, load testing |
| [Troubleshooting Guide](./troubleshooting.md) | Failure diagnosis, resolution, useful commands |

---

## Observability Architecture

The platform emits signals at four layers:

```text
Application layer     → structured JSON logs, custom CloudWatch metrics
Infrastructure layer  → ECS service metrics, ALB access logs, RDS metrics
Network layer         → VPC Flow Logs (30-day retention)
Audit layer           → CloudTrail (all API events, S3-backed, 90-day retention)
```

All signals converge in the `lottery-platform-operations` CloudWatch dashboard.

---

## CloudWatch Logs

### Log Groups

| Log group | Source | Retention |
|---|---|---|
| `/ecs/verification-service` | Verification service container | Configured in ECS task definition |
| `/ecs/claims-service` | Claims service container | Configured in ECS task definition |
| `<vpc_flow_log_group_name>` | VPC Flow Logs | 30 days |

Get the VPC Flow Log group name:

```bash
cd terraform
terraform output vpc_flow_log_group_name
```

### Structured Log Format

Both services emit structured JSON logs. Example verification log entry:

```json
{
  "event": "verification_complete",
  "ticket_number": "TKT-001-WIN",
  "draw_date": "2026-03-15",
  "outcome": "WINNER",
  "_from_cache": false,
  "latency_ms": 87,
  "timestamp": "2026-06-08T14:23:01Z"
}
```

### Querying Logs with CloudWatch Insights

Open CloudWatch → Log Insights and select `/ecs/verification-service`.

**All recent verifications:**

```text
fields @timestamp, ticket_number, outcome, _from_cache, latency_ms
| sort @timestamp desc
| limit 50
```

**Cache hit rate over time:**

```text
stats
  sum(fromFields(_from_cache, 1, 0)) as cache_hits,
  count(*) as total
| project cache_hits, total, cache_hits/total*100 as hit_rate_pct
```

**Login failures (requires metric filters enabled):**

```text
filter @message like /LOGIN_FAIL/
| fields @timestamp, @message
| sort @timestamp desc
| limit 100
```

**Claim registration events:**

```text
filter @message like /CLAIM_REGISTERED/
| fields @timestamp, @message
| sort @timestamp desc
```

---

## CloudWatch Dashboard

Dashboard name: `lottery-platform-operations`

Get the exact name:

```bash
cd terraform && terraform output cloudwatch_dashboard_name
```

Navigate to CloudWatch → Dashboards in the AWS console.

### Dashboard Panels

| Panel | Metrics shown |
|---|---|
| ECS CPU Utilization | `verification-service` and `claims-service` CPU % |
| ECS Memory Utilization | Both services memory % |
| ALB Request Count | Requests per minute across all targets |
| ALB HTTP 5xx Errors | Server error count |
| ALB Target Response Time | p50/p99 response latency |
| RDS CPU Utilization | Database CPU % |
| RDS DB Connections | Active connection count |
| Cache Hit Rate | Custom `CacheHitRate` metric — % of verifications served from Redis |
| Cache Operations | `CacheHit` and `CacheMiss` counts per minute |
| Verification Latency | `VerificationLatency` — p50/p99 end-to-end verification time |
| Redis Engine CPU | ElastiCache `EngineCPUUtilization` % |
| Redis Connections | ElastiCache `CurrConnections` count |
| Application Events | `LoginFail`, `ClaimRegistered`, `DuplicateClaimAttempt` counts (requires metric filters enabled) |

### Custom Redis Metrics

The verification service emits these custom metrics to CloudWatch under the namespace `LotteryPlatform/VerificationService`:

| Metric | Unit | Description |
|---|---|---|
| `CacheHit` | Count | Verifications served from Redis cache |
| `CacheMiss` | Count | Verifications that required a database query |
| `CacheHitRate` | Percent | `CacheHit / (CacheHit + CacheMiss) × 100` |
| `VerificationLatency` | Milliseconds | End-to-end time from request to response |

**Expected performance:**

| Condition | Expected `VerificationLatency` |
|---|---|
| Cache miss (cold) | 80–150 ms |
| Cache hit (warm) | 2–10 ms |

The 20–50× latency improvement on warm cache requests is visible in the `VerificationLatency` dashboard panel.

> **Note:** WINNER outcomes are intentionally excluded from the Redis cache. Every WINNER verification triggers a fresh database query plus an SQS message regardless of cache state.

### Querying Custom Metrics via CLI

```bash
aws cloudwatch get-metric-statistics \
  --namespace LotteryPlatform/VerificationService \
  --metric-name CacheHitRate \
  --start-time $(date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ') \
  --end-time $(date -u '+%Y-%m-%dT%H:%M:%SZ') \
  --period 300 \
  --statistics Average \
  --region us-east-1
```

---

## CloudWatch Alarms

11 alarms are configured across infrastructure and application layers. All alarms publish to the SNS topic output by `terraform output sns_alarm_topic_arn`.

> [!IMPORTANT]
> Alarm email notifications require SNS subscription confirmation. See [Deployment Guide → Step 10](./deployment_guide.md#10-confirm-sns-email-subscription).

### Alarm Reference

| Alarm | Threshold | Severity signal |
|---|---|---|
| ECS verification-service CPU > 80% | 80% for 2 consecutive periods | Service under load |
| ECS claims-service CPU > 80% | 80% for 2 consecutive periods | Service under load |
| ALB HTTP 5xx errors > 10 | 10 errors in 5 min | Application errors |
| ALB target response time > 2s | p99 > 2s for 5 min | Latency regression |
| RDS CPU > 80% | 80% for 2 consecutive periods | Database under load |
| RDS DB connections > 80 | 80 connections | Connection pool pressure |
| Login failures > 10 | 10 events in 5 min | Possible brute-force attempt |
| Duplicate claim attempts > 5 | 5 events in 5 min | Data integrity anomaly |
| Claim registrations | Any | Operational signal |
| **Redis CPU > 75%** | 75% for 2 consecutive periods | Cache under load |
| **Redis connections > 100** | 100 connections | Cache connection pressure |

### Listing Alarm States

```bash
aws cloudwatch describe-alarms \
  --region us-east-1 \
  --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue,Reason:StateReason}' \
  --output table
```

---

## SNS Notifications

CloudWatch alarms publish to an SNS topic. Email notifications are sent to the address configured in `alarm_email`.

```bash
# Get SNS topic ARN
cd terraform && terraform output sns_alarm_topic_arn

# List subscriptions
aws sns list-subscriptions-by-topic \
  --topic-arn $(terraform output -raw sns_alarm_topic_arn) \
  --region us-east-1
```

If alarm emails are not arriving, check subscription status — it should be `Confirmed`. If `PendingConfirmation`, re-check the confirmation email and click the link.

---

## CloudTrail

CloudTrail is enabled for all AWS API events across the account. Logs are stored in S3.

```bash
# Get CloudTrail ARN and S3 bucket
cd terraform
terraform output cloudtrail_arn
terraform output cloudtrail_bucket_name
```

### Querying CloudTrail

CloudTrail logs are stored as JSON in S3 and can be queried via CloudWatch Log Insights if a CloudWatch Logs destination is configured, or directly via S3 + Athena.

To see recent events via the AWS console: CloudTrail → Event History.

**Example: List recent IAM events**

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventSource,AttributeValue=iam.amazonaws.com \
  --start-time $(date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ') \
  --region us-east-1 \
  --query 'Events[*].{Time:EventTime,Name:EventName,User:Username}' \
  --output table
```

---

## VPC Flow Logs

VPC Flow Logs capture all accepted and rejected network traffic at the ENI level. Retention: 30 days.

```bash
# Get the Flow Log group name
cd terraform && terraform output vpc_flow_log_group_name
```

### Querying Flow Logs

Open CloudWatch → Log Insights and select the VPC Flow Log group.

**Rejected traffic in the last hour:**

```text
fields @timestamp, srcAddr, dstAddr, dstPort, action
| filter action = "REJECT"
| sort @timestamp desc
| limit 100
```

**Traffic to/from the RDS port (5432):**

```text
fields @timestamp, srcAddr, dstAddr, dstPort, action
| filter dstPort = 5432
| sort @timestamp desc
| limit 50
```

---

## Load Testing

Use these scripts to generate realistic traffic and validate application behavior under load.

### Prerequisites

```bash
# Get the ALB DNS name
ALB=$(cd terraform && terraform output -raw alb_dns_name)
```

### PowerShell: Baseline Verification Load

Sends 100 verification requests and measures latency distribution.

```powershell
$alb = "your-alb-dns-name"
$results = @()

for ($i = 1; $i -le 100; $i++) {
    $start = Get-Date
    $r = Invoke-WebRequest -Uri "https://$alb/health" -SkipCertificateCheck
    $elapsed = (Get-Date) - $start
    $results += [PSCustomObject]@{
        Request = $i
        StatusCode = $r.StatusCode
        LatencyMs = [int]$elapsed.TotalMilliseconds
    }
}

$results | Measure-Object -Property LatencyMs -Minimum -Maximum -Average |
    Select-Object Minimum, Maximum, Average
```

### PowerShell: Cache Warm-Up Test

Verifies the same ticket 10 times to demonstrate cold → warm latency improvement.

```powershell
$alb = "your-alb-dns-name"
$ticket = "TKT-004-LOSE"
$date = "2026-03-15"

# Simulate 10 verification requests for the same ticket
for ($i = 1; $i -le 10; $i++) {
    $start = Get-Date
    $r = Invoke-WebRequest `
        -Uri "https://$alb/verify" `
        -Method POST `
        -Body "ticket_number=$ticket&draw_date=$date" `
        -SkipCertificateCheck
    $elapsed = (Get-Date) - $start
    Write-Host "Request $i - $($r.StatusCode) - $([int]$elapsed.TotalMilliseconds)ms"
}
```

**Expected pattern:**

```text
Request 1  - 200 - 112ms   ← cache miss, DB query
Request 2  - 200 - 4ms     ← cache hit
Request 3  - 200 - 3ms     ← cache hit
...
```

### PowerShell: Concurrent Load Test

Sends 20 concurrent requests to test under parallelism.

```powershell
$alb = "your-alb-dns-name"

$jobs = 1..20 | ForEach-Object {
    Start-Job {
        param($alb)
        $start = Get-Date
        $r = Invoke-WebRequest -Uri "https://$alb/health" -SkipCertificateCheck
        $elapsed = (Get-Date) - $start
        [int]$elapsed.TotalMilliseconds
    } -ArgumentList $alb
}

$latencies = $jobs | Wait-Job | Receive-Job
$latencies | Measure-Object -Minimum -Maximum -Average
```

### Bash: Quick Health Check Loop

```bash
ALB=$(cd terraform && terraform output -raw alb_dns_name)

for i in {1..20}; do
    time curl -sk https://$ALB/health
    echo ""
done
```

### Interpreting Load Test Results

After running load tests, check the CloudWatch dashboard:

- **Cache Hit Rate** should increase as the same tickets are verified repeatedly
- **Verification Latency** p99 should remain under 200ms for cache hits
- **ECS CPU** should remain below the 80% alarm threshold
- **ALB 5xx errors** should remain at 0

---

## Operational Procedures

### Force ECS Service Redeployment

Useful after pushing a new Docker image:

```bash
aws ecs update-service \
  --cluster lottery-platform-cluster \
  --service verification-service \
  --force-new-deployment \
  --region us-east-1

aws ecs update-service \
  --cluster lottery-platform-cluster \
  --service claims-service \
  --force-new-deployment \
  --region us-east-1
```

### Check ECS Task Logs

Get the task ID first:

```bash
aws ecs list-tasks \
  --cluster lottery-platform-cluster \
  --service-name verification-service \
  --region us-east-1
```

Then tail the logs:

```bash
aws logs tail /ecs/verification-service --follow --region us-east-1
aws logs tail /ecs/claims-service --follow --region us-east-1
```

### Check Secrets Manager

Verify the DB secret is accessible:

```bash
aws secretsmanager get-secret-value \
  --secret-id $(cd terraform && terraform output -raw db_secret_arn) \
  --region us-east-1 \
  --query 'SecretString'
```

### Check SQS Queue Depth

```bash
aws sqs get-queue-attributes \
  --queue-url $(cd terraform && terraform output -raw sqs_queue_url) \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --region us-east-1

# Also check the DLQ — messages here indicate repeated processing failures
aws sqs get-queue-attributes \
  --queue-url $(aws sqs get-queue-url \
    --queue-name lottery-claims-dlq \
    --region us-east-1 \
    --query 'QueueUrl' --output text) \
  --attribute-names ApproximateNumberOfMessages \
  --region us-east-1
```

If the DLQ has messages, see [Troubleshooting Guide → DLQ has messages](./troubleshooting.md#dlq-has-messages).

### Check Redis Connectivity

```bash
# Get Redis endpoint
cd terraform && terraform output redis_endpoint

# Verify Redis is responding from ECS task context
# (Redis is in private subnet — not directly accessible from your machine)
# The /health endpoint is the proxy for Redis reachability:
curl -k https://$(terraform output -raw alb_dns_name)/health
# "redis": "reachable" = Redis is connected and responding
```
