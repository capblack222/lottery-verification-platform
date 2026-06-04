# Async queue between verification-service (producer) and claims-service (consumer).
#
# Flow:
#   verification-service  →  [verification-claims-queue]  →  claims-service
#                                        ↓ (after maxReceiveCount=3 failures)
#                                   [claims-dlq]  →  CloudWatch alarm → SNS

# =========================================================
# DEAD LETTER QUEUE
# =========================================================

resource "aws_sqs_queue" "claims_dlq" {
  name = "${var.project_name}-claims-dlq"

  # 14-day retention so failed messages are inspectable for forensics
  message_retention_seconds = 1209600

  # AWS-managed SQS encryption - no extra KMS cost, satisfies encryption-at-rest
  sqs_managed_sse_enabled = true

  tags = {
    Name    = "${var.project_name}-claims-dlq"
    Purpose = "Dead letter queue for failed claim processing"
  }
}

# =========================================================
# MAIN QUEUE  (verification → claims)
# =========================================================

resource "aws_sqs_queue" "verification_claims" {
  name = "${var.project_name}-verification-claims-queue"

  # How long a consumer has to process a message before SQS makes it visible again.
  visibility_timeout_seconds = 120

  # Keep messages for 1 day - long enough to survive a claims-service outage
  message_retention_seconds = 86400

  # Long polling: consumer waits up to 20 s for a message before returning empty.
  receive_wait_time_seconds = 20

  sqs_managed_sse_enabled = true

  # After 3 failed processing attempts, route message to the DLQ
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.claims_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Name    = "${var.project_name}-verification-claims-queue"
    Purpose = "Async handoff of verified winning tickets to claims-service"
  }
}

# =========================================================
# IAM POLICY  (grants send + receive permissions)
# =========================================================
#
# Both services share the same ecs_task_role today. The policy deliberately
# grants both SendMessage (verification) and ReceiveMessage/DeleteMessage
# (claims) so either service can do either operation.

resource "aws_iam_policy" "sqs_access" {
  name        = "${var.project_name}-sqs-access"
  description = "Allows ECS tasks to produce/consume the verification-claims SQS queue"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "QueueAccess"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = [
          aws_sqs_queue.verification_claims.arn,
          aws_sqs_queue.claims_dlq.arn
        ]
      }
    ]
  })
}
