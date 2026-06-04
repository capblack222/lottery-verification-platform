output "queue_url" {
  description = "URL of the verification-claims queue (set as SQS_QUEUE_URL env var in ECS tasks)"
  value       = aws_sqs_queue.verification_claims.url
}

output "queue_arn" {
  description = "ARN of the verification-claims queue"
  value       = aws_sqs_queue.verification_claims.arn
}

output "dlq_arn" {
  description = "ARN of the dead letter queue"
  value       = aws_sqs_queue.claims_dlq.arn
}

output "dlq_name" {
  description = "Name of the DLQ - used by the monitoring module to create a CloudWatch alarm"
  value       = aws_sqs_queue.claims_dlq.name
}

output "sqs_iam_policy_arn" {
  description = "IAM policy ARN granting SQS access - attach to the ECS task role in the root module"
  value       = aws_iam_policy.sqs_access.arn
}
