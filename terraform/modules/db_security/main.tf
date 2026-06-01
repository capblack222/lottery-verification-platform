resource "aws_kms_key" "rds_kms" {
  description         = "RDS encryption"
  enable_key_rotation = true
}

resource "aws_secretsmanager_secret" "db_secret" {
  name       = "${var.project_name}-db-secret"
  kms_key_id = aws_kms_key.rds_kms.arn
}

resource "aws_secretsmanager_secret_version" "db_secret_val" {
  secret_id = aws_secretsmanager_secret.db_secret.id

  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    dbname   = var.db_name
    engine   = "postgres"
    port     = 5432
    host     = aws_db_instance.rds.address
  })
}

resource "aws_security_group" "rds_sg" {
  name        = "${var.project_name}-rds-sg"
  description = "Allow PostgreSQL access only from ECS Fargate service"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from ECS/Fargate service only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.ecs_sg_id]
  }

  egress {
    description = "Allow outbound responses"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_subnet_group" "rds_subnet" {
  name       = "${var.project_name}-rds-subnet-group"
  subnet_ids = var.private_subnet_ids
}

resource "aws_db_instance" "rds" {
  identifier = "${var.project_name}-db"

  engine         = "postgres"
  engine_version = "15.7"
  instance_class = "db.t3.micro"

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  allocated_storage = 20
  storage_type      = "gp3"

  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds_kms.arn

  db_subnet_group_name   = aws_db_subnet_group.rds_subnet.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  publicly_accessible = false
  multi_az            = true

  backup_retention_period = 7
  skip_final_snapshot     = true
  deletion_protection     = false

  auto_minor_version_upgrade = true
}

resource "aws_iam_policy" "ecs_db_policy" {
  name        = "${var.project_name}-ecs-db-policy"
  description = "Allow ECS task role to read database secret and decrypt KMS key"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_secretsmanager_secret.db_secret.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = aws_kms_key.rds_kms.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_db_policy_attach" {
  role       = var.ecs_task_role_name
  policy_arn = aws_iam_policy.ecs_db_policy.arn
}

# Add this — attach the same policy to the EXECUTION role too
resource "aws_iam_role_policy_attachment" "ecs_db_exec_policy_attach" {
  role       = var.ecs_task_execution_role_name
  policy_arn = aws_iam_policy.ecs_db_policy.arn
}