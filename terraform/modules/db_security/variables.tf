variable "project_name" {}
variable "vpc_id" {}
variable "private_subnet_ids" {}
variable "ecs_sg_id" {}

variable "db_name" {
  default = "lotterydb"
}

variable "db_username" {
  default = "lotteryadmin"
}

variable "db_password" {
  sensitive = true
}

variable "ecs_task_role_name" {}

variable "ecs_task_execution_role_name" {
  description = "ECS task execution role name"
  type        = string
}