---
name: project_redis
description: ElastiCache Redis caching layer added to verification service - cache-aside pattern, IAM at root level, CloudWatch metrics, benchmark script
metadata:
  type: project
---

Redis caching layer (ElastiCache) added to the verification service.

**Why:** Repeated ticket lookups (same ticket+date) were hitting RDS on every request. Redis cache-aside reduces warm-path latency from ~100 ms (RDS) to ~2–5 ms.

**Design choices:**
  - Single-node replication group (num_cache_clusters = 1) keeps costs minimal
    while using the aws_elasticache_replication_group resource, which lets you
    add replicas later without destroying the cluster.
  - Encryption at rest enabled; in-transit TLS is left off to keep the Python
    client config simple - add transit_encryption_enabled = true + auth_token
    if your compliance posture requires it.
  - Redis sits in private subnets with a dedicated security group. Only the ECS
    task security group can reach port 6379.

**Terraform module:** `terraform/modules/redis/` - replication group, subnet group, security group (port 6379 from ECS SG only), IAM policy for `cloudwatch:PutMetricData`.

**IAM attachment pattern:** Same as SQS - the CloudWatch metrics policy is attached at root `main.tf` level to avoid circular module dependencies. 

**Cache key:** `verify:{ticket_number}:{draw_date}` with 1-hour TTL.

**WINNER not cached:** WINNER/UNCLAIMED status is volatile (→ CLAIMED soon). All other outcomes (NOT_FOUND, NOT_WINNER, ALREADY_CLAIMED) are cached for the full TTL.

**CloudWatch metrics namespace:** `LotteryPlatform/VerificationService` - CacheHit, CacheMiss, CacheHitRate, VerificationLatency. Alarms: `cache-hit-rate-low` (<0.5) and `verification-latency-high` (p90 >500ms).

**Benchmark:** `lottery-app/verification-service/benchmark.py` - measures cold vs warm latency, prints p50/p95/p99 and speedup ratio.

**Graceful degradation:** If `REDIS_URL` is empty or Redis unreachable (2s timeout), service falls back to direct RDS queries. `/health` reports `redis` field.

<!-- **How to apply:** When touching verification service performance or caching, refer to [[project_architecture]] for service context. -->
