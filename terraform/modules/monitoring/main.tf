data "aws_caller_identity" "current" {}

# -----------------------------
# SNS Topic for Alarm Alerts
# -----------------------------

resource "aws_sns_topic" "alarms" {
  name = "${var.project_name}-alarm-topic"

  tags = {
    Name = "${var.project_name}-alarm-topic"
  }
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# -----------------------------
# CloudTrail S3 Bucket
# -----------------------------

resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket        = "${var.project_name}-cloudtrail-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  force_destroy = true

  tags = {
    Name    = "${var.project_name}-cloudtrail-logs"
    Purpose = "CloudTrail audit logging"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"

        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }

        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail_logs.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"

        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }

        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"

        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

# -----------------------------
# CloudTrail
# -----------------------------

resource "aws_cloudtrail" "main" {
  name                          = "${var.project_name}-cloudtrail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true

  depends_on = [
    aws_s3_bucket_policy.cloudtrail_logs
  ]

  tags = {
    Name = "${var.project_name}-cloudtrail"
  }
}

# -----------------------------
# VPC Flow Logs to CloudWatch
# -----------------------------

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/${var.project_name}-flow-logs"
  retention_in_days = 14

  tags = {
    Name = "${var.project_name}-vpc-flow-logs"
  }
}

resource "aws_iam_role" "vpc_flow_logs" {
  name = "${var.project_name}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  name = "${var.project_name}-vpc-flow-logs-policy"
  role = aws_iam_role.vpc_flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"

        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]

        Resource = "*"
      }
    ]
  })
}

resource "aws_flow_log" "main" {
  iam_role_arn    = aws_iam_role.vpc_flow_logs.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn
  traffic_type    = "ALL"
  vpc_id          = var.vpc_id

  tags = {
    Name = "${var.project_name}-vpc-flow-log"
  }
}

# -----------------------------
# ECS CloudWatch Alarms
# -----------------------------

resource "aws_cloudwatch_metric_alarm" "verification_cpu_high" {
  alarm_name          = "${var.project_name}-verification-cpu-high"
  alarm_description   = "Verification service CPU utilization is high."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  alarm_actions       = [aws_sns_topic.alarms.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.verification_service_name
  }
}

resource "aws_cloudwatch_metric_alarm" "claims_cpu_high" {
  alarm_name          = "${var.project_name}-claims-cpu-high"
  alarm_description   = "Claims service CPU utilization is high."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  alarm_actions       = [aws_sns_topic.alarms.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.claims_service_name
  }
}

resource "aws_cloudwatch_metric_alarm" "verification_memory_high" {
  alarm_name          = "${var.project_name}-verification-memory-high"
  alarm_description   = "Verification service memory utilization is high."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 75
  alarm_actions       = [aws_sns_topic.alarms.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.verification_service_name
  }
}

resource "aws_cloudwatch_metric_alarm" "claims_memory_high" {
  alarm_name          = "${var.project_name}-claims-memory-high"
  alarm_description   = "Claims service memory utilization is high."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 75
  alarm_actions       = [aws_sns_topic.alarms.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.claims_service_name
  }
}

# -----------------------------
# ALB CloudWatch Alarms
# -----------------------------

resource "aws_cloudwatch_metric_alarm" "alb_5xx_high" {
  alarm_name          = "${var.project_name}-alb-5xx-high"
  alarm_description   = "ALB is returning too many 5XX errors."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_actions       = [aws_sns_topic.alarms.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "verification_unhealthy_targets" {
  alarm_name          = "${var.project_name}-verification-unhealthy-targets"
  alarm_description   = "Verification target group has unhealthy targets."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 0
  alarm_actions       = [aws_sns_topic.alarms.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.verification_tg_arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "claims_unhealthy_targets" {
  alarm_name          = "${var.project_name}-claims-unhealthy-targets"
  alarm_description   = "Claims target group has unhealthy targets."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 0
  alarm_actions       = [aws_sns_topic.alarms.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.claims_tg_arn_suffix
  }
}

# -----------------------------
# RDS Alarm
# -----------------------------

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${var.project_name}-rds-cpu-high"
  alarm_description   = "RDS CPU utilization is high."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alarms.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_identifier
  }
}

# -----------------------------
# Optional Application Log Metric Filters
# Enable only after log groups exist.
# -----------------------------

resource "aws_cloudwatch_log_metric_filter" "login_fail" {
  count          = var.enable_app_log_metric_filters ? 1 : 0
  name           = "${var.project_name}-login-fail-filter"
  log_group_name = "/ecs/verification-service"
  pattern        = "LOGIN_FAIL"

  metric_transformation {
    name      = "LoginFailCount"
    namespace = "${var.project_name}/Application"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "claim_registered" {
  count          = var.enable_app_log_metric_filters ? 1 : 0
  name           = "${var.project_name}-claim-registered-filter"
  log_group_name = "/ecs/claims-service"
  pattern        = "CLAIM_REGISTERED"

  metric_transformation {
    name      = "ClaimRegisteredCount"
    namespace = "${var.project_name}/Application"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "duplicate_claim" {
  count          = var.enable_app_log_metric_filters ? 1 : 0
  name           = "${var.project_name}-duplicate-claim-filter"
  log_group_name = "/ecs/claims-service"
  pattern        = "DUPLICATE_CLAIM_ATTEMPT"

  metric_transformation {
    name      = "DuplicateClaimAttemptCount"
    namespace = "${var.project_name}/Application"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "login_fail_spike" {
  count               = var.enable_app_log_metric_filters ? 1 : 0
  alarm_name          = "${var.project_name}-login-fail-spike"
  alarm_description   = "Multiple failed login attempts detected."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "LoginFailCount"
  namespace           = "${var.project_name}/Application"
  period              = 300
  statistic           = "Sum"
  threshold           = 3
  alarm_actions       = [aws_sns_topic.alarms.arn]
  treat_missing_data  = "notBreaching"
}

# -----------------------------
# CloudWatch Dashboard
# -----------------------------

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-operations"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6

        properties = {
          title  = "ECS CPU Utilization"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Average"

          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.verification_service_name],
            [".", ".", ".", var.ecs_cluster_name, ".", var.claims_service_name]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6

        properties = {
          title  = "ECS Memory Utilization"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Average"

          metrics = [
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.verification_service_name],
            [".", ".", ".", var.ecs_cluster_name, ".", var.claims_service_name]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6

        properties = {
          title  = "ALB 5XX Errors"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"

          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6

        properties = {
          title  = "Unhealthy Target Count"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Average"

          metrics = [
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.verification_tg_arn_suffix],
            [".", ".", ".", var.alb_arn_suffix, ".", var.claims_tg_arn_suffix]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6

        properties = {
          title  = "RDS CPU Utilization"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Average"

          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.rds_identifier]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6

        properties = {
          title  = "Application Events"
          region = var.aws_region
          view   = "timeSeries"
          period = 300
          stat   = "Sum"

          metrics = [
            ["${var.project_name}/Application", "LoginFailCount"],
            [".", "ClaimRegisteredCount"],
            [".", "DuplicateClaimAttemptCount"]
          ]
        }
      }
    ]
  })
}