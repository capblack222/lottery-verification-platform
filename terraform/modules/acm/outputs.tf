output "certificate_arn" {
  value = aws_acm_certificate.self_signed.arn
}