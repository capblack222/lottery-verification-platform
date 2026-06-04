module "networking" {
  source = "./modules/networking"

  project_name       = var.project_name
  vpc_cidr           = var.vpc_cidr
  public_subnets     = var.public_subnets
  private_subnets    = var.private_subnets
  availability_zones = var.availability_zones
}

module "acm" {
  source = "./modules/acm"
}

module "security" {
  source = "./modules/security"

  vpc_id = module.networking.vpc_id
}

module "alb" {
  source = "./modules/alb"

  project_name      = var.project_name
  vpc_id            = module.networking.vpc_id
  public_subnet_ids = module.networking.public_subnet_ids
  alb_sg_id         = module.security.alb_sg_id
  certificate_arn   = module.acm.certificate_arn
}

module "ecr" {
  source = "./modules/ecr"
}

# The IAM policy attachment is kept here (not inside the sqs module) to avoid a
# circular dependency: sqs would need the task role name from ecs, but ecs already
# depends on sqs for the queue URL.
module "sqs" {
  source = "./modules/sqs"

  project_name = var.project_name
}

# Attach the SQS IAM policy to the shared ECS task role at the root level.
# This runs after both modules are applied; no circular dependency.
resource "aws_iam_role_policy_attachment" "ecs_sqs_access" {
  role       = module.ecs.ecs_task_role_name
  policy_arn = module.sqs.sqs_iam_policy_arn
}

module "ecs" {
  source = "./modules/ecs"

  project_name        = var.project_name
  private_subnet_ids  = module.networking.private_subnet_ids
  ecs_sg_id           = module.security.ecs_sg_id
  verification_tg_arn = module.alb.verification_tg_arn
  claims_tg_arn       = module.alb.claims_tg_arn
  alb_dns_name        = module.alb.alb_dns_name
  verification_image  = "${module.ecr.verification_repository_url}:latest"
  claims_image        = "${module.ecr.claims_repository_url}:latest"
  db_host             = module.db_security.db_host
  sqs_queue_url       = module.sqs.queue_url
}

module "db_security" {
  source = "./modules/db_security"

  project_name                 = var.project_name
  vpc_id                       = module.networking.vpc_id
  private_subnet_ids           = module.networking.private_subnet_ids
  ecs_sg_id                    = module.security.ecs_sg_id
  db_password                  = var.db_password
  ecs_task_role_name           = module.ecs.ecs_task_role_name
  ecs_task_execution_role_name = module.ecs.ecs_task_execution_role
}

module "monitoring" {
  source = "./modules/monitoring"

  project_name = var.project_name
  aws_region   = var.aws_region
  vpc_id       = module.networking.vpc_id

  alb_arn_suffix             = module.alb.alb_arn_suffix
  verification_tg_arn_suffix = module.alb.verification_tg_arn_suffix
  claims_tg_arn_suffix       = module.alb.claims_tg_arn_suffix

  ecs_cluster_name          = module.ecs.ecs_cluster_name
  verification_service_name = module.ecs.verification_service_name
  claims_service_name       = module.ecs.claims_service_name

  rds_identifier                = module.db_security.rds_identifier
  alarm_email                   = var.alarm_email
  enable_app_log_metric_filters = var.enable_app_log_metric_filters
  claims_dlq_name               = module.sqs.dlq_name

  depends_on = [
    module.ecs,
    module.db_security
  ]
}