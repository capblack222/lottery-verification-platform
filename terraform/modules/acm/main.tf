resource "aws_acm_certificate" "self_signed" {
  private_key = file("certs/private.key")

  certificate_body = file("certs/certificate.crt")
}