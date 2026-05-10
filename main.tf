provider "aws" {
  region  = "us-east-1"
  profile = "student00" # Or replace with your profile
}

data "aws_caller_identity" "current" {}

locals {
  account_id             = data.aws_caller_identity.current.account_id # replaced for best practices.
  repo_name              = "mod12-repository"       #very creative name I came up with
  github_owner           = "williamdfrank26-pixel"
  branch                 = "main"
  ecr_image_tag          = "latest"
  ecr_repo_name          = "myrepo-container"
  task_family            = "myrepo-task"
  app_name               = "myrepo-app"
  deployment_group       = "myrepo-dg"
  alb_name               = "myrepo-alb"
  cluster_name           = "myrepo-cluster"
  service_name           = "myrepo-service"
  codebuild_project_name = "myrepo-build"
  codepipeline_name      = "myrepo-pipeline"
}

resource "aws_iam_service_linked_role" "ecs" {
  aws_service_name = "ecs.amazonaws.com"
}


# S3 bucket for CodePipeline artifacts
resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket_prefix = "pipeline-artifacts-"
  force_destroy = true
}

# ECR repository
resource "aws_ecr_repository" "app" {
  name = local.ecr_repo_name
}

# Default VPC and Subnets
resource "aws_default_vpc" "default" {
  tags = {
    Name = "Default VPC"
  }

  force_destroy = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [aws_default_vpc.default.id]
  }
}

# Security Group
resource "aws_security_group" "ecs_sg" {
  name   = "ecs-sg"
  vpc_id = aws_default_vpc.default.id

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

# Load Balancer
resource "aws_lb" "app" {
  name               = local.alb_name
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ecs_sg.id]
  subnets            = data.aws_subnets.default.ids
}

# Target Groups (blue/green)
resource "aws_lb_target_group" "blue" {
  name        = "tg-blue"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_default_vpc.default.id
  target_type = "ip"
}

resource "aws_lb_target_group" "green" {
  name        = "tg-green"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_default_vpc.default.id
  target_type = "ip"
}

# Listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "app" {
  name = local.cluster_name
}

# Initial task definition (just for service creation)
resource "aws_ecs_task_definition" "app" {
  family                   = local.task_family
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = "arn:aws:iam::${local.account_id}:role/service-role/ecsTaskExecutionRole"
  task_role_arn            = "arn:aws:iam::${local.account_id}:role/service-role/appTaskRole"

  container_definitions = jsonencode([
    {
      name      = local.ecr_repo_name
      image     = "${local.account_id}.dkr.ecr.us-east-1.amazonaws.com/${local.ecr_repo_name}:${local.ecr_image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        }
      ]
    }
  ])
}

# ECS Service
resource "aws_ecs_service" "app" {
  name            = local.service_name
  cluster         = aws_ecs_cluster.app.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = local.ecr_repo_name
    container_port   = 80
  }
}

# CodeDeploy
resource "aws_codedeploy_app" "app" {
  name             = local.app_name
  compute_platform = "ECS"
}

resource "aws_codedeploy_deployment_group" "app" {
  app_name               = aws_codedeploy_app.app.name
  deployment_group_name  = local.deployment_group
  service_role_arn       = "arn:aws:iam::${local.account_id}:role/service-role/codedeployRole"
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"

  ecs_service {
    cluster_name = aws_ecs_cluster.app.name
    service_name = aws_ecs_service.app.name
  }

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  blue_green_deployment_config {
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 0
    }

    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
  }

  load_balancer_info {
    target_group_pair_info {
      target_group {
        name = aws_lb_target_group.blue.name
      }
      target_group {
        name = aws_lb_target_group.green.name
      }
      prod_traffic_route {
        listener_arns = [aws_lb_listener.http.arn]
      }
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
}

# CodeBuild
resource "aws_codebuild_project" "build" {
  name         = local.codebuild_project_name
  service_role = "arn:aws:iam::${local.account_id}:role/service-role/codebuildRole"

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:6.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true // For Docker builds

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = local.account_id
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml" // Make sure to create this file in your repo
  }
}

# CodeStar Connections 
# NOTE:Will be in a "Pending" state until you authorize the connection.
resource "aws_codestarconnections_connection" "github" {
  name          = "MyGitHubConnection"
  provider_type = "GitHub"
}

# CodePipeline
resource "aws_codepipeline" "pipeline" {
  name          = local.codepipeline_name
  pipeline_type = "V2"
  role_arn      = "arn:aws:iam::${local.account_id}:role/service-role/codepipelineRole"

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        BranchName       = local.branch
        ConnectionArn    = aws_codestarconnections_connection.github.arn
        FullRepositoryId = "${local.github_owner}/${local.repo_name}"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "BuildDockerImage"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "DeployToECS"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeployToECS"
      version         = "1"
      input_artifacts = ["build_output"]

      configuration = {
        ApplicationName     = aws_codedeploy_app.app.name
        DeploymentGroupName = aws_codedeploy_deployment_group.app.deployment_group_name

        TaskDefinitionTemplateArtifact = "build_output"
        TaskDefinitionTemplatePath     = "taskdef.json"
        AppSpecTemplateArtifact        = "build_output"
        AppSpecTemplatePath            = "appspec.yml"
        Image1ArtifactName             = local.ecr_repo_name
        Image1ContainerName            = "IMAGE1_NAME"
      }
    }
  }
}
