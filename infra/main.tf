# Everything hello-world needs in AWS, in one file.
#
#   cd infra
#   terraform init
#   terraform apply        # creates it all, prints the 2 GitHub variables
#   terraform destroy      # removes it all
#
# Split of ownership: Terraform owns the SHAPE of the service (network, ALB, cluster, roles).
# The GitHub pipeline owns WHICH IMAGE runs (it registers new task definitions), so Terraform
# ignores changes to the service's task definition and desired count.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  # Real team: remote state in S3 (with locking) instead of a local file.
}

provider "aws" {
  region = var.region
}

variable "region" {
  default = "eu-west-2"
}

variable "github_repo" {
  default = "amir-haskel/hello-world"
}

variable "prefix" {
  description = "Shared account: every resource name starts with this"
  default     = "amir"
}

locals {
  name     = "${var.prefix}-hello-world" # ECR repo, task family, log group
  cluster  = "${var.prefix}-hello"
  service  = "hello-world" # ECS service + container name
  boundary = "arn:aws:iam::${data.aws_caller_identity.me.account_id}:policy/candidate-exam-boundary"
}

data "aws_caller_identity" "me" {}

# ------------------------------------------------------------------ ECR (image registry)
resource "aws_ecr_repository" "app" {
  name                 = local.name
  image_tag_mutability = "IMMUTABLE" # a version tag can never be overwritten
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 30 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 30 }
      action       = { type = "expire" }
    }]
  })
}

# ------------------------------------------------------------------ IAM
# GitHub's OIDC provider is account-wide (shared with other candidates), so we only look it up.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# Role ECS uses to pull the image and write logs.
resource "aws_iam_role" "exec" {
  name                 = "exam-${var.prefix}-hello-exec"
  permissions_boundary = local.boundary
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "exec" {
  role       = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Role GitHub Actions assumes (no stored AWS keys). Only main / the production environment.
resource "aws_iam_role" "github" {
  name                 = "exam-${var.prefix}-hello-gha"
  permissions_boundary = local.boundary
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike = { "token.actions.githubusercontent.com:sub" = [
          "repo:${var.github_repo}:ref:refs/heads/main",
          "repo:${var.github_repo}:environment:production",
        ] }
      }
    }]
  })
}

# Least privilege: push to OUR repo, update OUR service, pass OUR exec role.
resource "aws_iam_role_policy" "github" {
  name = "deploy"
  role = aws_iam_role.github.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages", "ecr:DescribeRepositories",
        ]
        Resource = aws_ecr_repository.app.arn
      },
      { Effect = "Allow", Action = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"], Resource = "*" },
      { Effect = "Allow", Action = ["ecs:UpdateService", "ecs:DescribeServices"], Resource = aws_ecs_service.app.id },
      {
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = aws_iam_role.exec.arn
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
    ]
  })
}

# ------------------------------------------------------------------ Logs
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}"
  retention_in_days = 14
}

# ------------------------------------------------------------------ Network (default VPC to keep it simple)
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

resource "aws_security_group" "alb" {
  name        = "${var.prefix}-hello-alb-sg"
  description = "HTTP from the internet to the hello-world ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "task" {
  name        = "${var.prefix}-hello-task-sg"
  description = "Only the ALB may reach hello-world tasks"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress { # tasks must reach ECR + CloudWatch to start
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ------------------------------------------------------------------ Load balancer (stable public URL)
resource "aws_lb" "app" {
  name               = "${var.prefix}-hello-alb"
  load_balancer_type = "application"
  subnets            = data.aws_subnets.default.ids
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "app" {
  name                 = "${var.prefix}-hello-tg"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip" # Fargate tasks register by IP
  vpc_id               = data.aws_vpc.default.id
  deregistration_delay = 30 # default 300s makes every deploy wait 5 minutes

  health_check {
    path                = "/health"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ------------------------------------------------------------------ ECS
resource "aws_ecs_cluster" "app" {
  name = local.cluster
}

# Placeholder revision so the service can exist before the first image is built.
# The pipeline registers the real revisions (from ecs/task-definition.json).
resource "aws_ecs_task_definition" "bootstrap" {
  family                   = local.name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.exec.arn
  container_definitions = jsonencode([{
    name         = local.service
    image        = "${aws_ecr_repository.app.repository_url}:bootstrap"
    essential    = true
    portMappings = [{ containerPort = 8080, protocol = "tcp" }]
  }])
}

resource "aws_ecs_service" "app" {
  name                              = local.service
  cluster                           = aws_ecs_cluster.app.id
  task_definition                   = aws_ecs_task_definition.bootstrap.arn
  desired_count                     = 0 # first pipeline deploy scales it to 1
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 30

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true # default VPC has no NAT; needed to pull from ECR
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = local.service
    container_port   = 8080
  }

  # Automatic rollback if new tasks never get healthy.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http]

  lifecycle {
    ignore_changes = [task_definition, desired_count] # owned by the pipeline
  }
}

# ------------------------------------------------------------------ Outputs = the GitHub variables
output "AWS_ROLE_ARN" {
  value = aws_iam_role.github.arn
}

output "SERVICE_URL" {
  value = "http://${aws_lb.app.dns_name}"
}
