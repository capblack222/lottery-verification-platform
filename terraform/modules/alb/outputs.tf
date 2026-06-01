output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "verification_tg_arn" {
  value = aws_lb_target_group.verification.arn
}

output "claims_tg_arn" {
  value = aws_lb_target_group.claims.arn
}

#---adding alb outputs for monitoring module---

output "alb_arn_suffix" {
  value = aws_lb.main.arn_suffix
}

output "verification_tg_arn_suffix" {
  value = aws_lb_target_group.verification.arn_suffix
}

output "claims_tg_arn_suffix" {
  value = aws_lb_target_group.claims.arn_suffix
}