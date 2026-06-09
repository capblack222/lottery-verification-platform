# Lottery Verification Platform on AWS

A production-style lottery ticket verification and claims registration platform deployed on AWS using **Terraform**, **ECS Fargate**, **Application Load Balancer**, **Amazon RDS PostgreSQL**, **ElastiCache Redis**, **Amazon SQS**, **AWS Secrets Manager**, **CloudWatch**, **CloudTrail**, **VPC Flow Logs**, **ALB access logs**, and **SNS**.

The platform allows an authorized customer service agent to:

- Verify lottery tickets by ticket number and draw date
- Check winning status and prize amount
- Register eligible winning tickets to claimants
- Prevent duplicate claim registration
- Generate claim confirmation with QR code
- Search registered claims by claimant name, ticket number, or claim ID

This project originated from a graduate cloud computing team project and has since been independently extended with additional cloud-native architecture, infrastructure, and operational enhancements.

---

## Table of Contents

- [Architecture](#architecture)
- [Repository Structure](#repository-structure)
- [Infrastructure](#infrastructure)
  - [Key Design Decisions](#key-design-decisions)
  - [Why ECS Fargate](#why-ecs-fargate-was-chosen)
  - [Redis Caching Layer](#redis-caching-layer)
  - [SQS Async Messaging](#sqs-async-messaging)
  - [Database Schema](#database-schema)
  - [Security](#security-considerations)
- [Logging and Monitoring](#logging-and-monitoring)
- [Cost Optimization](#cost-optimization-and-cost-involvement)
- [Known Issues and Limitations](#known-issues-and-limitations)
- [Deployment Guide](#deployment-guide)
- [Final Result](#final-result)

---

## Architecture

![Lottery Claim Verification Platform AWS Architecture](./docs/architecture-diagram.png)

**Architecture flow:**

```text
Customer Service Agent
        |
        | HTTPS
        v
Application Load Balancer
(public subnets across 2 Availability Zones)
        |
        +──────────────────────+
        v                      v
verification-service       claims-service
(ECS Fargate)              (ECS Fargate)
   |        |                  |     ^
   |        |                  |     |
   |   ElastiCache        Amazon RDS |
   |    Redis              PostgreSQL|
   |  (cache-aside)    (private DB   |
   |                    subnets)     |
   |                                 |
   +── WINNER event ──► SQS Queue ───+
                            |
                     (after 3 failures)
                            v
                         SQS DLQ
                   (14-day retention)
```

Supporting AWS services:

```text
Amazon ECR              → stores Docker images for both services
AWS Secrets Manager     → stores DB credentials retrieved at runtime by ECS tasks
ElastiCache Redis       → caches ticket verification results (cache-aside, 1-hour TTL)
Amazon SQS              → async handoff of WINNER events from verification to claims service
Amazon SQS DLQ          → retains failed messages after 3 delivery attempts (14-day retention)
CloudWatch Logs         → stores ECS application logs and VPC Flow Logs
CloudWatch Dashboard    → displays ECS, ALB, RDS, Redis cache, and app metrics
CloudWatch Alarms       → monitors CPU, memory, ALB 5XX, unhealthy targets, RDS CPU,
                          cache hit rate, verification latency, and SQS DLQ depth
Amazon SNS              → sends CloudWatch alarm notifications via email
AWS CloudTrail          → captures AWS API activity
Amazon S3               → stores CloudTrail and ALB access logs
VPC Flow Logs           → captures network traffic metadata
```

---

## Repository Structure

```text
lottery-app/
├── claims-service/
│   ├── app.py
│   ├── config.py
│   ├── models.py
│   ├── requirements.txt
│   ├── Dockerfile
│   └── templates/
├── verification-service/
│   ├── app.py            # Flask app with Redis cache-aside and SQS producer logic
│   ├── config.py         # REDIS_URL, CACHE_TTL_SECONDS, SQS_QUEUE_URL config
│   ├── benchmark.py      # Latency benchmark: before vs after Redis
│   ├── models.py
│   ├── requirements.txt  # includes redis==5.0.8, boto3
│   └── Dockerfile
└── deploy.sh

terraform/
├── provider.tf
├── variables.tf
├── main.tf               # Root module: wires up all modules, attaches IAM policies
├── outputs.tf
├── terraform.tfvars
├── certs/
│   ├── private.key
│   └── certificate.crt
└── modules/
    ├── acm/              # Self-signed certificate import
    ├── alb/              # Application Load Balancer + listeners
    ├── db_security/      # RDS security group
    ├── ecr/              # ECR repositories for both services
    ├── ecs/              # ECS cluster, task definitions, services
    ├── monitoring/       # CloudWatch logs, dashboard, alarms, CloudTrail, SNS
    ├── networking/       # VPC, subnets, NAT gateway, route tables
    ├── redis/            # ElastiCache Redis cluster, security group, IAM policy
    ├── security/         # ECS task IAM role and shared security group
    └── sqs/              # SQS queue, DLQ, and IAM policy
```

---

## Infrastructure

### Key Design Decisions

- ECS Fargate used instead of EC2 for serverless container orchestration
- Infrastructure provisioned entirely using Terraform modules
- Dockerized Flask microservices with multi-platform builds for `linux/amd64`
- Multi-AZ VPC with public and private subnet separation
- NAT Gateway for private subnet internet access
- Application Load Balancer with HTTPS/TLS termination
- ElastiCache Redis for sub-millisecond ticket verification caching
- Amazon SQS for decoupled async handoff of winning ticket events
- CloudWatch logging, dashboards, and alarms across all services
- ECR as private Docker image registry

---

### Why ECS Fargate Was Chosen

ECS Fargate was selected instead of traditional EC2 deployment for the following reasons:

#### Advantages of ECS Fargate

- No EC2 server management
- Fully managed container orchestration
- Simplified scaling
- Better workload isolation
- Faster deployments
- Lower operational overhead
- Native AWS integration with ALB, CloudWatch, IAM, and ECR

#### Why Not EC2 + Auto Scaling Groups?

Traditional EC2 deployments require server patching, capacity planning, AMI management, manual scaling management, and EC2 provisioning and maintenance. Fargate abstracts the infrastructure layer entirely and allows developers to focus only on containers and services.

---

### Redis Caching Layer

#### Rationale

Every ticket verification requires two PostgreSQL queries: one to resolve the draw by date, and one to look up the ticket by number and draw ID. In a lottery event window, the same winning-ticket numbers are frequently re-verified (agents double-checking, supervisors auditing). Without caching, each of those lookups adds 50–200 ms of RDS round-trip latency and contributes CPU load to the database instance.

Amazon ElastiCache Redis provides a sub-millisecond in-memory store in the same private subnet as the ECS tasks. The expected warm-path latency drops from ~100 ms (RDS) to ~2–5 ms (Redis), a reduction of 20–50×. This also meaningfully reduces RDS CPU utilization during peak verification load.

#### Infrastructure (`terraform/modules/redis/`)

| Resource | Purpose |
|---|---|
| `aws_elasticache_replication_group` | Single-node Redis 7.1 cluster (`cache.t3.micro`). `num_cache_clusters=1` keeps cost minimal; increase + set `automatic_failover_enabled=true` for Multi-AZ HA. |
| `aws_elasticache_subnet_group` | Places Redis in the same private subnets as ECS tasks. |
| `aws_security_group` (redis-sg) | Allows inbound TCP 6379 **only from the ECS task security group** — no public access. |
| `aws_iam_policy` (cw-metrics) | Scoped `cloudwatch:PutMetricData` to the `LotteryPlatform/VerificationService` namespace. Attached to the ECS task role at root `main.tf` to avoid a circular module dependency. |

Encryption at rest is enabled using the AWS-managed key. In-transit TLS is off by default to keep the Python client simple; enable `transit_encryption_enabled = true` with an `auth_token` if your compliance posture requires it.

#### Cache-aside Pattern (`app.py`)

```text
POST /verify
  │
  ├─ Build cache key: "verify:{TICKET_NUMBER}:{DRAW_DATE}"
  │
  ├─ Redis GET(key)
  │      │
  │      ├─ HIT  → deserialise → return result   ─────────────────┐
  │      │                                                        │
  │      └─ MISS → query RDS (draw + ticket lookups)              │
  │                 │                                             │
  │                 ├─ outcome != WINNER?                         │
  │                 │     └─ Redis SETEX(key, TTL, serialised)    │
  │                 │                                             │
  │                 └─ return result ───────────────────────────►─┤
  │                                                               │
  ├─ Emit CloudWatch metrics (CacheHit/Miss/Rate, Latency)        │
  │                                                               │
  ├─ Write audit log (DB insert — always, regardless of source) ◄─┘
  │
  └─ SQS event only when outcome=WINNER AND result is from RDS
```

**Why WINNER outcomes are not cached:** once an agent verifies a winning ticket, the claims service rapidly transitions it to `CLAIMED`. Serving a stale `WINNER` result from cache instead of `ALREADY_CLAIMED` would mislead a second agent. All other outcomes — `NOT_FOUND`, `NOT_WINNER`, `ALREADY_CLAIMED` — are immutable, so caching them for the full TTL is safe.

**Graceful degradation:** if `REDIS_URL` is unset or the cluster is temporarily unreachable (2-second connect/socket timeout), the service falls back to direct RDS queries with no change in behaviour. The health endpoint (`/health`) reports `"redis": "disabled"` or `"redis": "unreachable"` to aid diagnostics.

#### Cache Key and TTL

| Parameter | Value | Source |
|---|---|---|
| Key format | `verify:{ticket_number}:{draw_date}` | `app.py` |
| Default TTL | 3600 s (1 hour) | `CACHE_TTL_SECONDS` env var |
| Override | Set `CACHE_TTL_SECONDS` in ECS task definition | `terraform/modules/ecs/main.tf` |

#### CloudWatch Metrics

All metrics are emitted to the `LotteryPlatform/VerificationService` namespace on every POST to `/verify` when `REDIS_URL` is set.

| Metric | Unit | Stat to use | Description |
|---|---|---|---|
| `CacheHit` | Count | Sum | Incremented by 1 on each Redis hit |
| `CacheMiss` | Count | Sum | Incremented by 1 on each Redis miss |
| `CacheHitRate` | None (0.0–1.0) | Average | Per-request binary; Average over a window = hit-rate fraction |
| `VerificationLatency` | Milliseconds | p90 / p95 | End-to-end latency of the verify POST handler |

**Dashboard row:** the CloudWatch operations dashboard (`${project_name}-operations`) has a dedicated row with two panels — *Redis Cache Operations* (hit/miss counts per minute) and *Cache Hit Rate & Verification Latency p90*.

**Alarms:**

| Alarm | Threshold | Action |
|---|---|---|
| `cache-hit-rate-low` | Average `CacheHitRate` < 0.5 over 2 × 5 min | SNS topic |
| `verification-latency-high` | p90 `VerificationLatency` > 500 ms over 2 × 5 min | SNS topic |

#### Performance Benchmark

Run `benchmark.py` to measure the before-vs-after latency improvement:

```bash
# Step 1 - baseline (deploy WITHOUT Redis, or set REDIS_URL="" in the task definition)
python lottery-app/verification-service/benchmark.py \
  --base-url https://<alb-dns> \
  --ticket-number TKT-001-WIN \
  --draw-date 2024-01-15 \
  --username agent1 --password <pw> \
  --requests 100
# All 100 requests hit RDS → expect avg ~80–150 ms

# Step 2 - with Redis (REDIS_URL set, cache warmed after first request)
python lottery-app/verification-service/benchmark.py \
  --base-url https://<alb-dns> \
  --ticket-number TKT-001-WIN \
  --draw-date 2024-01-15 \
  --username agent1 --password <pw> \
  --requests 100
# Request 1 (cold): ~80–150 ms  |  Requests 2–100 (warm): ~2–10 ms
# Expected output: "Cache speedup: 20x–50x"
```

The script prints cold latency, warm avg, p50/p95/p99, and the overall speedup ratio.

**RDS query volume:** CloudWatch metrics `AWS/RDS DBConnections` and `ReadIOPS` should drop significantly after caching is active, since the same ticket+date lookups that used to hit the database are now served entirely from Redis.

---

### SQS Async Messaging

#### Rationale

When the verification service confirms a winning ticket, the claims service needs to be notified to prepare the claim workflow. A synchronous HTTP call between services would create tight coupling — a claims service outage would break the verification response. Amazon SQS decouples the two services: the verification service publishes a WINNER event and returns immediately, while the claims service consumes and processes it independently.

#### Infrastructure (`terraform/modules/sqs/`)

| Resource | Purpose |
|---|---|
| `aws_sqs_queue` (main queue) | Standard SQS queue (`{project_name}-verification-claims-queue`). Receives WINNER events from the verification service and delivers them to the claims service. |
| `aws_sqs_queue` (DLQ) | Dead letter queue (`{project_name}-claims-dlq`). Receives messages that fail processing 3 or more times. 14-day retention for forensic inspection. |
| `aws_iam_policy` (sqs-access) | Grants `SendMessage` (verification service) and `ReceiveMessage` + `DeleteMessage` + `GetQueueAttributes` (claims service) on both queues. Attached to the ECS task role at root `main.tf` to avoid a circular module dependency — same pattern as the Redis IAM policy. |

Both queues use AWS-managed SSE (`sqs_managed_sse_enabled = true`) for encryption at rest at no additional KMS cost.

#### Queue Configuration

| Parameter | Value | Purpose |
|---|---|---|
| `visibility_timeout_seconds` | 120 s | How long a consumer has to process a message before SQS makes it visible again |
| `message_retention_seconds` | 86400 s (1 day) | Long enough to survive a short claims-service outage |
| `receive_wait_time_seconds` | 20 s | Long polling — reduces empty receives and API cost |
| `maxReceiveCount` | 3 | Messages that fail 3 times are routed to the DLQ |
| DLQ retention | 1209600 s (14 days) | Failed messages remain inspectable for forensic review |

#### Message Flow

```text
POST /verify
  │
  └─ outcome = WINNER AND result not from cache
              │
              v
    SQS SendMessage
    {
      "ticket_id":     <id>,
      "ticket_number": "TKT-001-WIN",
      "draw_id":       <id>,
      "draw_date":     "2026-03-15",
      "prize_amount":  "10000.00",
      "verified_by":   <user_id>,
      "verified_at":   "<ISO 8601 UTC timestamp>"
    }
              │
              v
  verification-claims-queue
              │
         (consume)
              v
       claims-service
              │
    ┌─────────┴──────────┐
    │ success            │ failure (×3)
    v                    v
  DeleteMessage      claims-dlq
                  (14-day retention)
```

**Why only fresh RDS WINNER results trigger SQS:** a cached result means the event was already published on the first verification. Publishing again from cache would cause the claims service to process a duplicate. The `_from_cache` flag on the result dict prevents this.

**Graceful degradation:** SQS publish errors are caught and logged (`SQS_PUBLISH_FAILED`) but never re-raised. A SQS outage cannot break the verification response or the audit trail — the agent still sees the correct outcome.

---

### Database Schema

The Lottery Verification Platform uses **PostgreSQL** as the relational database backend. The schema supports lottery ticket verification, winning claim registration, claimant tracking, QR confirmation, and authenticated customer service access.

The database is deployed using **Amazon RDS PostgreSQL** in private subnets, and application credentials are stored securely in **AWS Secrets Manager**.

#### Schema Goals

The schema is designed to support:

- Lottery draw management
- Ticket verification and winning status tracking
- Claimant registration and claim reference generation
- QR confirmation generation
- Claim search and tracking
- User authentication and authorization
- Duplicate claim prevention

#### Entity Relationship Overview

```text
User
 └── registers ──► Claim
                       │
                       ▼
                   Claimant
                       │
                       ▼
                    Ticket
                       │
                       ▼
                     Draw
```

#### Future Enhancements

Potential schema improvements include:

- Dedicated audit logging table for all user actions
- Claim approval and review workflow
- Fraud detection tracking
- Multi-region draw replication
- Ticket purchase history
- Payment processing integration
- Role-based access control with more granular permissions
- Claim document upload tracking
- Claim status history table

---

### Security Considerations

The database and broader platform security design includes:

- Passwords are stored as hashes, not plaintext.
- Database credentials are managed using AWS Secrets Manager and retrieved by ECS tasks at runtime.
- RDS PostgreSQL is deployed in private subnets and is not publicly accessible.
- RDS encryption at rest is enabled.
- ECS services access RDS through security-group-restricted private networking.
- The RDS security group allows PostgreSQL traffic on port `5432` only from the ECS service security group.
- ElastiCache Redis is in private subnets with a dedicated security group allowing port `6379` only from the ECS task security group.
- SQS queues use AWS-managed SSE encryption at rest.
- HTTPS/TLS is implemented through the Application Load Balancer.
- Amazon Shield Standard provides default DDoS protection for the Application Load Balancer.

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
- CloudWatch dashboard with ECS, ALB, RDS, Redis, and app metric panels
- CloudWatch alarms for CPU, memory, ALB 5XX, unhealthy targets, RDS CPU, cache hit rate, and verification latency
- SNS alarm topic with optional email subscription
- CloudTrail API activity logging
- VPC Flow Logs
- ALB access logs stored in S3

### CloudWatch Log Groups

```text
/ecs/verification-service
/ecs/claims-service
/aws/vpc/lottery-platform-flow-logs
```

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
- Redis cache hit rate low (`CacheHitRate` < 0.5)
- Verification latency high (p90 > 500 ms)
- Login fail spike (when application metric filters are enabled)

### Application Log Metric Filters

Metric filters are controlled by:

```hcl
enable_app_log_metric_filters = false
```

Keep it `false` during first deployment. After the ECS log groups exist, set it to `true` and reapply:

```bash
terraform plan
terraform apply
```

> **Note:** The Application Events dashboard only shows data when the app emits logs matching the exact patterns `LOGIN_FAIL`, `CLAIM_REGISTERED`, and `DUPLICATE_CLAIM_ATTEMPT`.

---

## Cost Optimization and Cost Involvement

Approximate US East (N. Virginia / `us-east-1`) cost drivers:

| Resource | Cost involvement | Approximate impact if left running |
|---|---:|---|
| ElastiCache Redis (`cache.t3.micro`) | Charged hourly | About `$0.017/hour` = `$12.24/month`; destroy after demo |
| NAT Gateway | Charged hourly and per GB processed | About `$0.045/hour` = `$32.40/month` plus about `$0.045/GB` processed |
| Application Load Balancer | Charged per ALB-hour and LCU-hour | About `$0.0225/hour` = `$16.20/month`, plus LCU usage |
| ECS Fargate | Charged by vCPU-seconds and GB-seconds | For two small 0.25 vCPU / 0.5 GB tasks running 24/7: roughly `$18/month` |
| RDS PostgreSQL | Charged by DB instance hours, storage, and backups | Small demo instances are usually around `$12–13/month` plus storage/backups |
| Amazon SQS | Charged per API request | First 1M requests/month are free; negligible cost at demo scale |
| CloudWatch Logs | Charged by log ingestion and storage | Log ingestion can be around `$0.50/GB`; retention should be limited |
| CloudWatch Alarms | Charged per alarm metric | Standard alarms are about `$0.10/alarm/month`; 10 alarms ≈ `$1/month` |
| Secrets Manager | Charged per secret and API calls | About `$0.40/secret/month` plus API calls |
| ECR | Charged by image storage | About `$0.10/GB-month`; remove old images |
| S3 log buckets | Charged by storage and requests | Usually low for demo logs, but grows with CloudTrail/ALB log volume |
| CloudTrail | Management event history is free; trail logs use S3 storage | Keep one trail and avoid unnecessary extra event selectors |

Cost-control choices in this project:

- Use ECS Fargate task sizes appropriate for a demo workload.
- Keep desired task count low during demonstration.
- Use CloudWatch log retention instead of unlimited retention.
- Use one NAT Gateway only for demo simplicity, then destroy it after submission.
- Store only required Docker images in ECR.
- Use S3 buckets for CloudTrail and ALB logs only as long as needed for evidence.
- Keep `enable_app_log_metric_filters = false` until log groups exist.
- Destroy infrastructure immediately after screenshots and submission.

> **Important:** NAT Gateway, ALB, RDS, ElastiCache, and Fargate continue charging while running. Do not leave the stack deployed after the project is complete.

---

## Known Issues and Limitations

### 1. Self-signed certificate browser warning

The project uses a self-signed/imported certificate for demo HTTPS. Browsers will show a security warning. For production, use a public ACM certificate with domain validation.

### 2. Application event metrics may show no data

The Application Events dashboard depends on exact log patterns:

```text
LOGIN_FAIL
CLAIM_REGISTERED
DUPLICATE_CLAIM_ATTEMPT
```

If the app does not emit these strings during the selected time range, the widget may show no data.

### 3. Metric filters should not be enabled too early

If `/ecs/verification-service` and `/ecs/claims-service` do not exist yet, CloudWatch metric filter creation can fail. Keep this false first:

```hcl
enable_app_log_metric_filters = false
```

Enable it only after ECS log groups exist.

### 4. ALB access logs and CloudTrail logs are delayed

ALB access logs and CloudTrail S3 log files can take several minutes to appear. Generate traffic and wait 5–15 minutes before collecting screenshots.

### 5. RDS free-tier backup restriction

Some AWS Academy/free-tier accounts reject certain backup retention settings. For demo deployment, backup retention may need to be reduced:

```hcl
backup_retention_period = 0
```

### 6. Secrets Manager recovery window

If the secret is deleted and then recreated with the same name, AWS may block creation because the old secret is scheduled for deletion. Restore or force-delete the old secret before reapplying.

---

## Deployment Guide

For full deployment steps, post-deployment validation, application test data, troubleshooting, and teardown instructions, see the [Deployment & Troubleshooting Guide](./docs/deployment_guide.md).

---

## Final Result

The project demonstrates:

- Infrastructure as Code with Terraform across modular, reusable components
- Two containerized Flask microservices deployed on ECS Fargate
- Public/private subnet architecture across multiple Availability Zones
- Application Load Balancer with HTTPS/TLS via ACM-imported certificate
- ElastiCache Redis caching layer with cache-aside pattern and graceful fallback
- Amazon SQS async event queue with Dead Letter Queue and long polling
- PostgreSQL database on Amazon RDS with encryption at rest
- Secure credential handling through AWS Secrets Manager
- Centralized logging through CloudWatch Logs
- CloudWatch dashboard and alarms covering ECS, ALB, RDS, Redis, and app metrics
- CloudTrail audit logging and VPC Flow Logs
- ALB access logging to S3
- SNS alarm notification support
- Cost-aware resource sizing and cleanup practices
