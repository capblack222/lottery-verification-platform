output "verification_repository_url" {
  value = aws_ecr_repository.verification.repository_url
}

output "claims_repository_url" {
  value = aws_ecr_repository.claims.repository_url
}