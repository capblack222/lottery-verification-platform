variable "aws_region" {
  default = "us-east-1"
}

variable "project_name" {
  default = "lottery-platform"
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "public_subnets" {
  type = list(string)

  default = [
    "10.0.1.0/24",
    "10.0.2.0/24"
  ]
}

variable "private_subnets" {
  type = list(string)

  default = [
    "10.0.11.0/24",
    "10.0.12.0/24"
  ]
}

variable "availability_zones" {
  type = list(string)

  default = [
    "us-east-1a",
    "us-east-1b"
  ]
}

variable "db_password" {
  description = "Master password for RDS database; should be more than 8 characters"
  type        = string
  sensitive   = true
}

#----adding monitoring variables----

variable "alarm_email" {
  description = "Email address for CloudWatch alarm notifications. Leave empty to skip."
  type        = string
  default     = ""
}

variable "enable_app_log_metric_filters" {
  description = "Enable app log metric filters after ECS log groups exist."
  type        = bool
  default     = false
}