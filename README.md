# Lottery Verification Platform — AWS Cloud Architecture

> A production-style, event-driven microservices platform for lottery ticket verification and claims registration, deployed on AWS using Terraform IaC.

![AWS](https://img.shields.io/badge/AWS-Cloud-FF9900?logo=amazonaws&logoColor=white&style=flat-square)
![Terraform](https://img.shields.io/badge/Terraform-IaC-7B42BC?logo=terraform&logoColor=white&style=flat-square)
![Python](https://img.shields.io/badge/Python-Flask-3776AB?logo=python&logoColor=white&style=flat-square)
![Docker](https://img.shields.io/badge/Docker-ECS%20Fargate-2496ED?logo=docker&logoColor=white&style=flat-square)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-RDS-4169E1?logo=postgresql&logoColor=white&style=flat-square)
![Redis](https://img.shields.io/badge/Redis-ElastiCache-DC382D?logo=redis&logoColor=white&style=flat-square)

---

## Executive Summary

This platform enables authorized customer service agents to verify lottery tickets, check winning status, and register prize claims — preventing duplicates and generating QR-confirmed receipts. It is built as two independent Flask microservices deployed on Amazon ECS Fargate, communicating asynchronously through Amazon SQS, and backed by Amazon RDS PostgreSQL with an ElastiCache Redis caching layer that reduces verification latency by 20–50×.

The project demonstrates production-level cloud engineering: layered network security, end-to-end observability, graceful service degradation, event-driven decoupling, and an entire AWS infrastructure stack defined and reproducible through 10 composable Terraform modules.

---

## Key Achievements

| Achievement | Detail |
|---|---|
| **20–50× verification latency improvement** | Redis cache-aside reduces warm-path response from ~100 ms (RDS) to ~2–5 ms |
| **Event-driven service decoupling** | SQS async queue eliminates tight coupling; a claims outage cannot impact the verification response |
| **Fault-tolerant messaging** | Dead Letter Queue captures failed events after 3 delivery attempts; 14-day retention for forensic review |
| **Zero-plaintext credentials** | All database credentials fetched from AWS Secrets Manager at ECS task startup; nothing stored in code or environment variables |
| **Defense-in-depth networking** | App and DB tiers in private subnets; port-scoped security groups per service; no public RDS or Redis endpoints |
| **Full observability stack** | Structured JSON logs, 10+ CloudWatch alarms, custom cache and latency metrics, CloudTrail, VPC Flow Logs, ALB access logs |
| **Infrastructure as Code** | 10 Terraform modules; entire stack provisioned and torn down with a single `terraform apply` / `destroy` |
| **Multi-AZ resilience** | ALB and ECS tasks span two Availability Zones; RDS in isolated private DB subnets |

---

## Table of Contents

- [Architecture](#architecture)
- [Architecture Decisions](#architecture-decisions)
- [Technical Implementation](#technical-implementation)
  - [Redis Caching Layer](#redis-caching-layer)
  - [SQS Async Messaging](#sqs-async-messaging)
  - [Database Schema](#database-schema)
  - [Security Design](#security-design)
- [Performance](#performance)
- [Observability](#observability)
- [Cloud Engineering Skills Demonstrated](#cloud-engineering-skills-demonstrated)
- [Repository Structure](#repository-structure)
- [Infrastructure](#infrastructure)
- [Cost Optimization](#cost-optimization)
- [Known Issues and Limitations](#known-issues-and-limitations)
- [Deployment Guide](#deployment-guide)

---

## Architecture

![Lottery Claim Verification Platform AWS Architecture](./docs/architecture-diagram.png)

The platform follows a **layered, private-subnet architecture** with traffic flowing from the public-facing ALB down through ECS Fargate services in private app subnets to RDS in isolated private DB subnets. Redis and SQS serve as the performance and decoupling layers respectively.

```text
Customer Service Agent
        |
        | HTTPS (ALB — public subnets, 2 AZs)
        v
Application Load Balancer
        |
        +─────────────────────────+
        v                         v
verification-service          claims-service
(ECS Fargate — private)       (ECS Fargate — private)
   |         |                    |        ^
   |    ElastiCache           Amazon RDS   |
   |     Redis                PostgreSQL   |
   |   (cache-aside,        (private DB    |
   |    1-hour TTL)          subnets)      |
   |                                       |
   +──── WINNER event ──► SQS Queue ───────+
                               |
                        (after 3 failures)
                               v
                            SQS DLQ
                      (14-day retention)
```

**Supporting services:**

```text
Amazon ECR              → private Docker image registry for both services
AWS Secrets Manager     → DB credentials retrieved at ECS task startup — never in code
ElastiCache Redis       → cache-aside verification results (1-hour TTL; WINNER excluded)
Amazon SQS              → async WINNER event handoff from verification to claims service
Amazon SQS DLQ          → failed messages retained 14 days after 3 delivery attempts
CloudWatch Logs         → structured JSON application logs and VPC Flow Logs
CloudWatch Dashboard    → ECS, ALB, RDS, Redis cache, and application event metrics
CloudWatch Alarms       → 10+ alarms: CPU, memory, 5XX, latency, cache hit rate, unhealthy targets
Amazon SNS              → alarm email notifications
AWS CloudTrail          → AWS API activity audit trail
Amazon S3               → CloudTrail logs and ALB access logs (encrypted)
VPC Flow Logs           → network traffic metadata
```

---

## Architecture Decisions

Every major design choice involved a deliberate tradeoff. The table below surfaces the reasoning behind each decision.

| Decision | Chosen | Alternative | Reasoning |
|---|---|---|---|
| **Compute** | ECS Fargate | EC2 + Auto Scaling Groups | Eliminates server management, AMI patching, and capacity planning. Native integration with ALB, CloudWatch, IAM, and ECR. |
| **Caching** | ElastiCache Redis (cache-aside) | Query RDS on every request | Two RDS queries are required per verification. Redis reduces warm-path latency by 20–50× and significantly lowers RDS CPU during peak load. |
| **Service communication** | SQS async queue | Synchronous HTTP call | A claims service outage cannot block the verification response. SQS provides natural retry semantics, backpressure, and DLQ handling without custom retry logic. |
| **WINNER cache exclusion** | Not cached | Cache all outcomes | WINNER status transitions to CLAIMED rapidly after verification. A stale cached WINNER result would mislead a second agent into thinking the ticket is still unclaimed. |
| **Secret management** | AWS Secrets Manager | Env variable injection | Secrets are rotatable without redeployment. Each access is logged for audit. No credentials stored in task definitions, images, or config files. |
| **IAM policy attachment** | Root `main.tf` | Within each child module | Attaching the Redis and SQS IAM policies at the root level avoids a circular Terraform dependency between the `redis`/`sqs` modules and the `ecs` module that holds the task role. |
| **Infrastructure** | Terraform modules | Manual console / CloudFormation | Modular, reviewable, diffable. The entire stack provisions and tears down with a single command. Each module has clear input/output boundaries. |
| **TLS termination** | ALB with ACM certificate | Per-service TLS | TLS is offloaded to the load balancer. Services communicate over private networking without the overhead of certificate management per container. |

---

## Technical Implementation

### Redis Caching Layer

#### The Problem

Every ticket verification requires two PostgreSQL queries: one to resolve the draw by date, and one to look up the ticket by number and draw ID. In a lottery event window, the same winning-ticket numbers are frequently re-verified — agents double-checking, supervisors auditing. Without caching, each lookup adds 50–200 ms of RDS round-trip latency and contributes unnecessary CPU load to the database instance.

#### The Solution

Amazon ElastiCache Redis sits in the same private subnet as the ECS tasks, providing a sub-millisecond in-memory lookup. Warm-path latency drops from ~100 ms to ~2–5 ms — a 20–50× improvement — and RDS CPU utilization drops substantially during peak verification windows.

#### Infrastructure (`terraform/modules/redis/`)

| Resource | Purpose |
|---|---|
| `aws_elasticache_replication_group` | Single-node Redis 7.1 cluster (`cache.t3.micro`). `num_cache_clusters=1` keeps cost minimal; increase + set `automatic_failover_enabled=true` for Multi-AZ HA. |
| `aws_elasticache_subnet_group` | Places Redis in the same private subnets as ECS tasks. |
| `aws_security_group` (redis-sg) | Allows inbound TCP 6379 **only from the ECS task security group** — no public access. |
| `aws_iam_policy` (cw-metrics) | Scoped `cloudwatch:PutMetricData` to the `LotteryPlatform/VerificationService` namespace. Attached at root `main.tf` to avoid a circular module dependency. |

Encryption at rest is enabled using the AWS-managed key. In-transit TLS is off by default to keep the Python client simple; enable `transit_encryption_enabled = true` with an `auth_token` if your compliance posture requires it.

#### Cache-aside Pattern (`app.py`)

```text
POST /verify
  │
  ├─ Build cache key: "verify:{TICKET_NUMBER}:{DRAW_DATE}"
  │
  ├─ Redis GET(key)
  │      │
  │      ├─ HIT  → deserialise → return result  ─────────────────┐
  │      │                                                        │
  │      └─ MISS → query RDS (draw + ticket lookups)             │
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

**Alarms:**

| Alarm | Threshold | Action |
|---|---|---|
| `cache-hit-rate-low` | Average `CacheHitRate` < 0.5 over 2 × 5 min | SNS topic |
| `verification-latency-high` | p90 `VerificationLatency` > 500 ms over 2 × 5 min | SNS topic |

---

### SQS Async Messaging

#### The Problem

When the verification service confirms a winning ticket, the claims service needs to prepare the claim workflow. A synchronous HTTP call between services creates tight coupling — if the claims service is down or slow, the verification response stalls. Any retry logic would need to be hand-rolled.

#### The Solution

Amazon SQS decouples the two services entirely. The verification service publishes a WINNER event and returns immediately. The claims service consumes independently. SQS provides managed retry, backpressure, and a Dead Letter Queue — no custom retry infrastructure required.

#### Infrastructure (`terraform/modules/sqs/`)

| Resource | Purpose |
|---|---|
| `aws_sqs_queue` (main) | Standard SQS queue (`{project_name}-verification-claims-queue`). Receives WINNER events from verification and delivers to claims. |
| `aws_sqs_queue` (DLQ) | Dead letter queue (`{project_name}-claims-dlq`). Captures messages that fail 3+ times. 14-day retention for forensic review. |
| `aws_iam_policy` (sqs-access) | Grants `SendMessage` (verification) and `ReceiveMessage` + `DeleteMessage` + `GetQueueAttributes` (claims) on both queues. Attached at root `main.tf` — same pattern as the Redis IAM policy. |

Both queues use AWS-managed SSE (`sqs_managed_sse_enabled = true`) for encryption at rest.

#### Queue Configuration

| Parameter | Value | Purpose |
|---|---|---|
| `visibility_timeout_seconds` | 120 s | Consumer processing window before message re-appears |
| `message_retention_seconds` | 86400 s (1 day) | Survives short claims-service outages |
| `receive_wait_time_seconds` | 20 s | Long polling — reduces empty receives and API cost |
| `maxReceiveCount` | 3 | Failed messages route to DLQ after 3 attempts |
| DLQ retention | 1209600 s (14 days) | Failed messages retained for forensic inspection |

#### Message Flow

```text
POST /verify
  │
  └─ outcome = WINNER AND result is not from cache
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

**Why only fresh RDS results trigger SQS:** a cached WINNER result means the event was already published during the first verification. Re-publishing from cache would cause the claims service to process a duplicate event. The `_from_cache` flag on the result dict gates the publish call.

**Graceful degradation:** SQS publish errors are caught, logged as `SQS_PUBLISH_FAILED`, and never re-raised. A SQS outage cannot break the verification response or audit trail — the agent sees the correct outcome regardless.

---

### Database Schema

The platform uses **Amazon RDS PostgreSQL** as its relational backend, deployed in private DB subnets with credentials managed exclusively through AWS Secrets Manager.

The schema covers: draw management, ticket verification and status tracking, claimant registration, claim reference and QR confirmation generation, claim search, user authentication, and duplicate claim prevention.

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

#### Future Schema Enhancements

- Dedicated audit table for all user actions
- Claim approval and review workflow
- Fraud detection tracking
- Multi-region draw replication
- Role-based access control with granular permissions
- Claim status history table

---

### Security Design

Security is applied at every layer rather than as a perimeter-only concern.

| Layer | Control |
|---|---|
| **Network** | App and DB services in private subnets; no public RDS or Redis endpoints |
| **Compute** | ECS task security group restricts outbound; port-scoped inbound per service |
| **Database** | RDS security group allows port 5432 from ECS task SG only; encryption at rest enabled |
| **Cache** | Redis security group allows port 6379 from ECS task SG only; encryption at rest enabled |
| **Messaging** | SQS queues use AWS-managed SSE; IAM policy scoped to minimum required actions |
| **Secrets** | All DB credentials in AWS Secrets Manager; ECS tasks fetch at startup; no secrets in code, images, or task definitions |
| **Credentials** | User passwords stored as hashes, not plaintext |
| **Transport** | HTTPS/TLS terminated at the ALB via ACM-imported certificate |
| **DDoS** | Amazon Shield Standard protects the ALB by default |
| **Audit** | CloudTrail captures all AWS API calls; per-request audit inserts in the application DB; VPC Flow Logs record network traffic |

---

## Performance

Verification performance was benchmarked using `lottery-app/verification-service/benchmark.py`, which measures cold vs. warm latency across 100 requests and reports p50/p95/p99 and overall speedup.

| Scenario | Cold request | Warm requests | RDS impact |
|---|---|---|---|
| **Without Redis** | 80–150 ms | 80–150 ms | Every request hits RDS |
| **With Redis** | 80–150 ms (cache miss) | 2–10 ms (cache hit) | Only the first request per ticket+date hits RDS |
| **Improvement** | — | **20–50× faster** | Significant reduction in `DBConnections` and `ReadIOPS` |

```bash
# Run the benchmark — baseline (no cache)
python lottery-app/verification-service/benchmark.py \
  --base-url https://<alb-dns> \
  --ticket-number TKT-001-WIN \
  --draw-date 2024-01-15 \
  --username agent1 --password <pw> \
  --requests 100

# Run the benchmark — with Redis enabled (REDIS_URL set)
python lottery-app/verification-service/benchmark.py \
  --base-url https://<alb-dns> \
  --ticket-number TKT-001-WIN \
  --draw-date 2024-01-15 \
  --username agent1 --password <pw> \
  --requests 100
# Request 1 (cold): ~80–150 ms  |  Requests 2–100 (warm): ~2–10 ms
```

**RDS query volume:** CloudWatch metrics `DBConnections` and `ReadIOPS` should drop significantly once caching is active, as repeated ticket+date lookups are served entirely from Redis.

---

## Observability

Observability is implemented as a first-class concern rather than an afterthought.

The monitoring module (`terraform/modules/monitoring/`) provisions the full stack:

**Logs:**

```text
/ecs/verification-service     — structured JSON application logs
/ecs/claims-service           — structured JSON application logs
/aws/vpc/lottery-platform-flow-logs — VPC network traffic metadata
```

Application logs use a consistent JSON structure (`time`, `level`, `msg`) and emit named event strings (`LOGIN_FAIL`, `VERIFY_WINNER`, `WINNER_QUEUED`, `CACHE_HIT`, `CLAIM_REGISTERED`) that CloudWatch metric filters can target.

**CloudWatch Alarms (10+):**

| Alarm | Threshold |
|---|---|
| Verification service CPU high | > threshold |
| Claims service CPU high | > threshold |
| Verification service memory high | > threshold |
| Claims service memory high | > threshold |
| ALB 5XX errors high | > threshold |
| Verification unhealthy targets | ≥ 1 |
| Claims unhealthy targets | ≥ 1 |
| RDS CPU high | > threshold |
| Redis cache hit rate low | Average `CacheHitRate` < 0.5 over 2 × 5 min |
| Verification latency high | p90 `VerificationLatency` > 500 ms over 2 × 5 min |
| Login fail spike | Enabled via `enable_app_log_metric_filters` |

All alarms publish to an SNS topic with optional email subscription.

**Custom Metrics** are emitted per verification request to the `LotteryPlatform/VerificationService` namespace:

| Metric | Description |
|---|---|
| `CacheHit` / `CacheMiss` | Count per request |
| `CacheHitRate` | Per-request binary (0.0 or 1.0); window average = hit-rate fraction |
| `VerificationLatency` | End-to-end handler latency in milliseconds |

**Audit trail:** every verification attempt writes an audit record to the database regardless of cache hit or miss. CloudTrail captures all AWS API calls. ALB access logs are delivered to S3.

> **Note on metric filters:** set `enable_app_log_metric_filters = false` on first deploy. Enable it only after `/ecs/verification-service` and `/ecs/claims-service` log groups exist, then reapply Terraform.

---

## Cloud Engineering Skills Demonstrated

| Skill Area | Implementation in this project |
|---|---|
| **Container orchestration** | Two Flask microservices containerized with Docker (`linux/amd64` multi-platform builds), pushed to ECR, deployed on ECS Fargate with health checks and target group integration |
| **Infrastructure as Code** | 10 composable Terraform modules with clear input/output boundaries; full stack provisioned and destroyed with a single command |
| **Distributed systems design** | Microservice decomposition with independent scaling, separate data access patterns, and asynchronous inter-service communication |
| **Event-driven architecture** | SQS producer/consumer pattern; idempotency via `_from_cache` guard; configurable retry with DLQ; long polling to minimize API cost |
| **Performance engineering** | Redis cache-aside with 2-second timeout and graceful fallback; benchmark tooling measuring p50/p95/p99 and speedup ratio |
| **Observability engineering** | Structured JSON logs; custom CloudWatch metric namespace; 10+ alarms with SNS routing; CloudTrail; VPC Flow Logs; ALB access logs |
| **Secure cloud networking** | Multi-AZ VPC with public/private/DB subnet tiers; port-scoped security groups per service; zero public endpoints for data services |
| **Secret management** | AWS Secrets Manager for DB credentials; ECS tasks fetch at runtime; no secrets in code, environment variables, or Docker images |
| **Fault tolerance** | SQS DLQ with 3-attempt retry; Redis graceful fallback to RDS; SQS publish errors logged but never surface to the user |
| **AWS platform integration** | 12+ integrated AWS services: ECS, ECR, ALB, RDS, ElastiCache, SQS, Secrets Manager, CloudWatch, CloudTrail, SNS, S3, ACM, VPC |

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
│   ├── app.py            # Flask app — Redis cache-aside + SQS producer logic
│   ├── config.py         # REDIS_URL, CACHE_TTL_SECONDS, SQS_QUEUE_URL
│   ├── benchmark.py      # Latency benchmark: before vs after Redis
│   ├── models.py
│   ├── requirements.txt  # includes redis==5.0.8, boto3
│   └── Dockerfile
└── deploy.sh

terraform/
├── provider.tf
├── variables.tf
├── main.tf               # Root module — wires all modules, attaches IAM policies
├── outputs.tf
├── terraform.tfvars
├── certs/
│   ├── private.key
│   └── certificate.crt
└── modules/
    ├── acm/              # Self-signed certificate import into ACM
    ├── alb/              # Application Load Balancer + HTTPS listener
    ├── db_security/      # RDS security group
    ├── ecr/              # ECR repositories for both services
    ├── ecs/              # ECS cluster, task definitions, Fargate services
    ├── monitoring/       # CloudWatch logs, dashboard, alarms, CloudTrail, SNS
    ├── networking/       # VPC, subnets, NAT gateway, route tables
    ├── redis/            # ElastiCache Redis cluster, security group, IAM policy
    ├── security/         # ECS task IAM role and shared security group
    └── sqs/              # SQS queue, DLQ, and IAM policy
```

---

## Infrastructure

### Why ECS Fargate

ECS Fargate was chosen over EC2 + Auto Scaling Groups to eliminate the operational overhead that doesn't contribute to the application's goals.

| Concern | EC2 + ASG | ECS Fargate |
|---|---|---|
| Server management | Manual patching and AMI updates | None — AWS manages the underlying infrastructure |
| Capacity planning | Required upfront | Tasks scale without pre-provisioning |
| Deployment | AMI bake or SSM bootstrapping | Push new image to ECR; ECS pulls and restarts |
| Workload isolation | Per-instance | Per-task; no noisy-neighbour risk |
| AWS integration | Requires additional configuration | Native with ALB, CloudWatch, IAM, ECR |

### Key Infrastructure Choices

- **Multi-AZ VPC** — ALB and ECS tasks span two Availability Zones. RDS is in dedicated private DB subnets.
- **NAT Gateway** — allows ECS tasks in private subnets to pull images from ECR and reach AWS APIs without public IP addresses.
- **ACM certificate** — a self-signed certificate is imported into ACM for HTTPS on the ALB. In production this would be replaced with a domain-validated public certificate.
- **Terraform root `main.tf`** — IAM policy attachments for both the Redis CloudWatch metrics policy and the SQS access policy are wired here rather than inside child modules, preventing circular dependency errors between the `ecs`, `redis`, and `sqs` modules.

---

## Cost Optimization

Approximate costs for `us-east-1` if the stack is left running continuously:

| Resource | Billing model | Approximate monthly cost |
|---|---:|---|
| ElastiCache Redis (`cache.t3.micro`) | Per hour | ~$12.24/month |
| NAT Gateway | Per hour + per GB | ~$32.40/month + $0.045/GB |
| Application Load Balancer | Per ALB-hour + LCU | ~$16.20/month + LCU usage |
| ECS Fargate (2 × 0.25 vCPU / 0.5 GB) | Per vCPU-second + GB-second | ~$18/month |
| RDS PostgreSQL | Per instance hour + storage | ~$12–13/month + storage |
| Amazon SQS | Per API request | Free tier covers demo scale |
| CloudWatch Logs | Per GB ingested and stored | ~$0.50/GB ingested |
| CloudWatch Alarms | Per alarm | ~$0.10/alarm/month |
| Secrets Manager | Per secret + API calls | ~$0.40/secret/month |
| ECR | Per GB stored | ~$0.10/GB-month |
| S3 log buckets | Per GB + requests | Low at demo scale |
| CloudTrail | Management events free; S3 storage billed | Minimal |

**Cost-control decisions applied in this project:**

- Fargate task sizes matched to demo workload (0.25 vCPU / 0.5 GB).
- CloudWatch log retention configured rather than unlimited.
- Single NAT Gateway for demo simplicity; destroy immediately after use.
- `enable_app_log_metric_filters = false` until log groups exist.
- ECR repositories cleaned up after demo.

> [!WARNING]
> NAT Gateway, ALB, RDS, ElastiCache, and Fargate accrue charges continuously while running. Destroy the stack immediately after use with `terraform destroy`.

---

## Known Issues and Limitations

### 1. Self-signed certificate browser warning

The ALB uses a self-signed certificate imported into ACM for demo HTTPS. Browsers will show a security warning. In production, replace with a public ACM certificate validated against a real domain.

### 2. Application event metrics may show no data

The Application Events CloudWatch dashboard panels depend on exact log pattern matching:

```text
LOGIN_FAIL
CLAIM_REGISTERED
DUPLICATE_CLAIM_ATTEMPT
```

If the application does not emit these strings during the selected time window, the widgets show no data.

### 3. Enable metric filters after log groups exist

CloudWatch metric filter creation fails if the target log groups do not yet exist. Keep the following `false` on first deployment:

```hcl
enable_app_log_metric_filters = false
```

After ECS tasks are running and log groups are created, set to `true` and reapply.

### 4. ALB and CloudTrail log delivery is delayed

ALB access logs and CloudTrail S3 files typically take 5–15 minutes to appear after traffic is generated.

### 5. RDS backup retention on free-tier accounts

Some AWS Academy or free-tier accounts reject backup retention settings above zero. If this occurs, set:

```hcl
backup_retention_period = 0
```

### 6. Secrets Manager recovery window

If a secret is deleted and recreated with the same name while the original is pending deletion, Terraform will error. Restore or force-delete the old secret first:

```bash
# Restore
aws secretsmanager restore-secret --secret-id lottery-platform-db-secret --region us-east-1

# Or force-delete
aws secretsmanager delete-secret \
  --secret-id lottery-platform-db-secret \
  --force-delete-without-recovery \
  --region us-east-1
```

---

## Documentation

| Guide | Contents |
|---|---|
| [Deployment Guide](./docs/deployment_guide.md) | Prerequisites, Quick Start, Terraform + Docker deployment steps, post-deployment validation, success checklist, enable log metric filters, test data, destroy/cleanup |
| [Operations Guide](./docs/operations_guide.md) | CloudWatch Logs, dashboard panels, custom Redis metrics, alarms reference, SNS, CloudTrail, VPC Flow Logs, load testing scripts, operational procedures |
| [Troubleshooting Guide](./docs/troubleshooting.md) | ECS tasks stuck in PENDING, health check failures, Redis unreachable, metric filter timing, ECR/S3 destroy blockers, DLQ messages, alarm emails, high latency — plus full useful commands reference |
