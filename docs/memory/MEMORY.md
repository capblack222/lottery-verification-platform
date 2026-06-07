# Memory Index

- [Project Architecture](project_architecture.md) - Lottery verification platform: two Flask ECS services (verification + claims), RDS PostgreSQL, ALB, no existing async queue before SQS work
- [SQS Module](project_sqs.md) - SQS async queue module added: verification → claims queue with DLQ, IAM attachment at root level to avoid circular dependency
- [Redis Cache Layer](project_redis.md) - ElastiCache Redis caching layer added to verification service: cache-aside pattern, CloudWatch metrics, benchmark script
