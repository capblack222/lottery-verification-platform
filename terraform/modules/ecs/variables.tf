variable "project_name" {}
variable "private_subnet_ids" {}
variable "ecs_sg_id" {}
variable "verification_tg_arn" {}
variable "claims_tg_arn" {}
variable "verification_image" {}
variable "claims_image" {}
variable "alb_dns_name" {}
variable "db_host" {
  description = "RDS instance endpoint"
  type        = string
}

variable "sqs_queue_url" {
  description = "URL of the SQS verification-claims queue injected as SQS_QUEUE_URL into both services"
  type        = string
  default     = ""
}

variable "redis_url" {
  description = "Redis URL (redis://host:port/0) injected as REDIS_URL into the verification service"
  type        = string
  default     = ""
}