variable "project_name" {
  description = "Project name prefix used for resource naming"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the Redis cluster is deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the ElastiCache subnet group"
  type        = list(string)
}

variable "ecs_sg_id" {
  description = "ECS task security group ID - granted inbound access on port 6379"
  type        = string
}

variable "node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}

variable "engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.1"
}

variable "parameter_group_name" {
  description = "ElastiCache parameter group name (must match engine_version family)"
  type        = string
  default     = "default.redis7"
}
