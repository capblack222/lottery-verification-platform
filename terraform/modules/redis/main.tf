# IAM note: ElastiCache (unlike SQS/Secrets Manager) is network-access-controlled,
# not IAM-controlled. The IAM policy in this module covers CloudWatch PutMetricData
# so the verification-service can emit cache_hit / cache_miss / latency metrics.

# =========================================================
# SECURITY GROUP
# =========================================================

resource "aws_security_group" "redis" {
  name        = "${var.project_name}-redis-sg"
  description = "Allow Redis port 6379 inbound from ECS tasks only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from ECS Fargate"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.ecs_sg_id]
  }

  # No egress needed - Redis does not initiate outbound connections
  egress {
    description = "Deny all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-redis-sg"
    Purpose = "ElastiCache Redis access control"
  }
}

# =========================================================
# SUBNET GROUP
# =========================================================

resource "aws_elasticache_subnet_group" "main" {
  name        = "${var.project_name}-redis-subnet-group"
  description = "Private subnets for ElastiCache Redis"
  subnet_ids  = var.private_subnet_ids

  tags = {
    Name = "${var.project_name}-redis-subnet-group"
  }
}

# =========================================================
# REDIS REPLICATION GROUP
# =========================================================

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "${var.project_name}-redis"
  description          = "Verification-service ticket-lookup result cache"

  engine         = "redis"
  engine_version = var.engine_version
  node_type      = var.node_type
  port           = 6379

  # Single primary, no replicas. Increase num_cache_clusters and set
  # automatic_failover_enabled = true to enable Multi-AZ HA.
  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true

  parameter_group_name = var.parameter_group_name

  # Keep one daily snapshot for point-in-time recovery
  snapshot_retention_limit = 1

  # Apply changes within the maintenance window in production;
  # set true here so Terraform apply is not blocked waiting for a window.
  apply_immediately = true

  tags = {
    Name    = "${var.project_name}-redis"
    Purpose = "Verification-service cache"
  }
}

# =========================================================
# IAM POLICY - CloudWatch PutMetricData
# =========================================================
# Attach this to the ECS task role (done at root main.tf to avoid cycle).
# Allows the verification-service to publish custom metrics:
#     CacheHit, CacheMiss, VerificationLatency → LotteryPlatform/VerificationService

resource "aws_iam_policy" "cloudwatch_metrics" {
  name        = "${var.project_name}-cw-metrics"
  description = "Allows ECS tasks to publish custom CloudWatch metrics"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PutMetrics"
        Effect = "Allow"
        Action = ["cloudwatch:PutMetricData"]
        # Scoped to the application namespace - cannot write to AWS/* namespaces
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "LotteryPlatform/VerificationService"
          }
        }
        Resource = "*"
      }
    ]
  })
}
