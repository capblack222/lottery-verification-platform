output "alb_dns_name" {
  value = module.alb.alb_dns_name
}

output "verification_ecr_url" {
  value = module.ecr.verification_repository_url
}

output "claims_ecr_url" {
  value = module.ecr.claims_repository_url
}

output "rds_endpoint" {
  value = module.db_security.rds_endpoint
}

output "db_secret_arn" {
  value = module.db_security.db_secret_arn
}

output "sns_alarm_topic_arn" {
  value = module.monitoring.sns_alarm_topic_arn
}

output "cloudtrail_arn" {
  value = module.monitoring.cloudtrail_arn
}

output "cloudtrail_bucket_name" {
  value = module.monitoring.cloudtrail_bucket_name
}

output "vpc_flow_log_id" {
  value = module.monitoring.vpc_flow_log_id
}

output "vpc_flow_log_group_name" {
  value = module.monitoring.vpc_flow_log_group_name
}

output "cloudwatch_dashboard_name" {
  value = module.monitoring.cloudwatch_dashboard_name
}

output "sqs_queue_url" {
  description = "URL of the verification-claims SQS queue"
  value       = module.sqs.queue_url
}

output "sqs_dlq_arn" {
  description = "ARN of the claims dead letter queue"
  value       = module.sqs.dlq_arn
}

output "redis_endpoint" {
  description = "ElastiCache Redis primary endpoint hostname"
  value       = module.redis.redis_endpoint
}

output "redis_url" {
  description = "Full Redis URL injected into the verification service (redis://host:port/0)"
  value       = module.redis.redis_url
}