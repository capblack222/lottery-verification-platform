# modules/ecs/outputs.tf

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_cluster_id" {
  value = aws_ecs_cluster.main.id
}

output "verification_task_definition_arn" {
  value = aws_ecs_task_definition.verification_task.arn
}

output "claims_task_definition_arn" {
  value = aws_ecs_task_definition.claims_task.arn
}

output "ecs_task_role_name" {
  value = aws_iam_role.ecs_task_role.name
}

output "ecs_task_execution_role" {
  value = aws_iam_role.ecs_task_execution_role.name
}


#---adding monitoring outputs---
output "verification_service_name" {
  value = aws_ecs_service.verification_service.name
}

output "claims_service_name" {
  value = aws_ecs_service.claims_service.name
}