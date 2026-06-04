variable "project_name" {
  description = "Project name prefix"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for VPC Flow Logs"
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix for CloudWatch metrics"
  type        = string
}

variable "verification_tg_arn_suffix" {
  description = "Verification target group ARN suffix"
  type        = string
}

variable "claims_tg_arn_suffix" {
  description = "Claims target group ARN suffix"
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster name"
  type        = string
}

variable "verification_service_name" {
  description = "Verification ECS service name"
  type        = string
}

variable "claims_service_name" {
  description = "Claims ECS service name"
  type        = string
}

variable "rds_identifier" {
  description = "RDS DB instance identifier"
  type        = string
}

variable "alarm_email" {
  description = "Email address for SNS alarm notifications. Leave empty to skip email subscription."
  type        = string
  default     = ""
}

variable "enable_app_log_metric_filters" {
  description = "Set true only after ECS CloudWatch log groups exist."
  type        = bool
  default     = false
}

variable "claims_dlq_name" {
  description = "Name of the SQS claims dead letter queue. When set, a CloudWatch alarm fires if any message lands in the DLQ."
  type        = string
  default     = ""
}