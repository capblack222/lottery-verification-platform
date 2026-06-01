resource "aws_ecr_repository" "verification" {
  name = "verification-service"

  image_scanning_configuration {
    scan_on_push = true
  }

  force_delete = true
}

resource "aws_ecr_repository" "claims" {
  name = "claims-service"

  image_scanning_configuration {
    scan_on_push = true
  }

  force_delete = true
}