output "redis_endpoint" {
  description = "Primary endpoint hostname for the Redis cluster"
  value       = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "redis_port" {
  description = "Redis port (always 6379)"
  value       = aws_elasticache_replication_group.main.port
}

output "redis_url" {
  description = "Full Redis URL in redis://host:port/0 format - injected as REDIS_URL into ECS tasks"
  value       = "redis://${aws_elasticache_replication_group.main.primary_endpoint_address}:${aws_elasticache_replication_group.main.port}/0"
}

output "redis_sg_id" {
  description = "Security group ID of the Redis cluster"
  value       = aws_security_group.redis.id
}

output "cloudwatch_metrics_policy_arn" {
  description = "IAM policy ARN for CloudWatch PutMetricData - attach to the ECS task role at root level"
  value       = aws_iam_policy.cloudwatch_metrics.arn
}
