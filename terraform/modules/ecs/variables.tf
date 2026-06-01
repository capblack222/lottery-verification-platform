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