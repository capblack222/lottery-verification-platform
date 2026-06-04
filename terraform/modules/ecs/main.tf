# modules/ecs/main.tf

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"
}

# =========================================================
# IAM ROLE FOR ECS TASK EXECUTION
# =========================================================

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.project_name}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role" "ecs_task_role" {
  name = "${var.project_name}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# =========================================================
# CLOUDWATCH LOG GROUPS
# =========================================================

resource "aws_cloudwatch_log_group" "verification_logs" {
  name              = "/ecs/verification-service"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "claims_logs" {
  name              = "/ecs/claims-service"
  retention_in_days = 7
}

# =========================================================
# VERIFICATION TASK DEFINITION
# =========================================================

resource "aws_ecs_task_definition" "verification_task" {
  family                   = "verification-service"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  cpu    = "256"
  memory = "512"

  execution_role_arn = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn      = aws_iam_role.ecs_task_role.arn #monitoring

  container_definitions = jsonencode([
    {
      name      = "verification-service"
      image     = var.verification_image
      essential = true

      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = aws_cloudwatch_log_group.verification_logs.name
          awslogs-region        = "us-east-1"
          awslogs-stream-prefix = "ecs"
        }
      }

      environment = [
        {
          name  = "AWS_REGION"
          value = "us-east-1"
        },
        {
          name  = "DB_SECRET_NAME"
          value = "${var.project_name}-db-secret"
        },
        {
          name  = "SECRET_KEY"
          value = "replace-this"
        },
        {
          name  = "BASE_URL"
          value = "https://${var.alb_dns_name}"
        },
        {
          name  = "DB_HOST"
          value = var.db_host # ← add this
        },
        {
          name  = "DB_SECRET_NAME"
          value = "${var.project_name}-db-secret"
        },
        {
          name  = "CLAIMS_SERVICE_URL"
          value = "https://${var.alb_dns_name}"
        },
        {
          name  = "SQS_QUEUE_URL"
          value = var.sqs_queue_url
        }
      ]
    }
  ])
}

# =========================================================
# CLAIMS TASK DEFINITION
# =========================================================

resource "aws_ecs_task_definition" "claims_task" {
  family                   = "claims-service"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  cpu    = "256"
  memory = "512"

  execution_role_arn = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn      = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "claims-service"
      image     = var.claims_image
      essential = true

      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = aws_cloudwatch_log_group.claims_logs.name
          awslogs-region        = "us-east-1"
          awslogs-stream-prefix = "ecs"
        }
      }

      environment = [
        {
          name  = "AWS_REGION"
          value = "us-east-1"
        },
        {
          name  = "DB_SECRET_NAME"
          value = "${var.project_name}-db-secret"
        },
        {
          name  = "SECRET_KEY"
          value = "replace-this"
        },
        {
          name  = "DB_HOST"
          value = var.db_host # ← add this
        },
        {
          name  = "DB_SECRET_NAME"
          value = "${var.project_name}-db-secret"
        },
        {
          name  = "VERIFY_SERVICE_URL"
          value = "https://${var.alb_dns_name}"
        },
        {
          name  = "SQS_QUEUE_URL"
          value = var.sqs_queue_url
        }
      ]
    }
  ])
}

# =========================================================
# VERIFICATION ECS SERVICE
# =========================================================

resource "aws_ecs_service" "verification_service" {
  name            = "verification-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.verification_task.arn

  launch_type   = "FARGATE"
  desired_count = 1

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.verification_tg_arn
    container_name   = "verification-service"
    container_port   = 8000
  }

  depends_on = [
    aws_iam_role_policy_attachment.ecs_task_execution_role_policy
  ]
}

# =========================================================
# CLAIMS ECS SERVICE
# =========================================================

resource "aws_ecs_service" "claims_service" {
  name            = "claims-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.claims_task.arn

  launch_type   = "FARGATE"
  desired_count = 1

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.claims_tg_arn
    container_name   = "claims-service"
    container_port   = 8000
  }

  depends_on = [
    aws_iam_role_policy_attachment.ecs_task_execution_role_policy
  ]
}

# =========================================================
# AUTOSCALING FOR VERIFICATION SERVICE
# =========================================================

resource "aws_appautoscaling_target" "verification_scaling_target" {
  max_capacity = 4
  min_capacity = 1

  resource_id = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.verification_service.name}"

  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "verification_cpu_policy" {
  name        = "verification-cpu-scaling"
  policy_type = "TargetTrackingScaling"

  resource_id = aws_appautoscaling_target.verification_scaling_target.resource_id

  scalable_dimension = aws_appautoscaling_target.verification_scaling_target.scalable_dimension

  service_namespace = aws_appautoscaling_target.verification_scaling_target.service_namespace

  target_tracking_scaling_policy_configuration {

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value = 70
  }
}

# =========================================================
# AUTOSCALING FOR CLAIMS SERVICE
# =========================================================

resource "aws_appautoscaling_target" "claims_scaling_target" {
  max_capacity = 4
  min_capacity = 1

  resource_id = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.claims_service.name}"

  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "claims_cpu_policy" {
  name        = "claims-cpu-scaling"
  policy_type = "TargetTrackingScaling"

  resource_id = aws_appautoscaling_target.claims_scaling_target.resource_id

  scalable_dimension = aws_appautoscaling_target.claims_scaling_target.scalable_dimension

  service_namespace = aws_appautoscaling_target.claims_scaling_target.service_namespace

  target_tracking_scaling_policy_configuration {

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value = 70
  }
}