output "rds_endpoint" {
  value = aws_db_instance.rds.endpoint
}

output "db_secret_arn" {
  value = aws_secretsmanager_secret.db_secret.arn
}

output "db_host" {
  value = aws_db_instance.rds.address
}

#---adding monitoring outputs---

output "rds_identifier" {
  value = aws_db_instance.rds.identifier
}