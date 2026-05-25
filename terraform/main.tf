terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

data "aws_caller_identity" "current" {}

# ─── Network ────────────────────────────────────────────────────────

resource "aws_vpc" "monitor_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "marukyu-monitor-vpc"
  }
}

resource "aws_internet_gateway" "monitor_igw" {
  vpc_id = aws_vpc.monitor_vpc.id

  tags = {
    Name = "marukyu-monitor-igw"
  }
}

resource "aws_subnet" "monitor_subnet" {
  vpc_id                  = aws_vpc.monitor_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "marukyu-monitor-subnet"
  }
}

resource "aws_route_table" "monitor_rt" {
  vpc_id = aws_vpc.monitor_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.monitor_igw.id
  }

  tags = {
    Name = "marukyu-monitor-rt"
  }
}

resource "aws_route_table_association" "monitor_rta" {
  subnet_id      = aws_subnet.monitor_subnet.id
  route_table_id = aws_route_table.monitor_rt.id
}

resource "aws_security_group" "monitor_sg" {
  name        = "marukyu-monitor-sg"
  description = "Security group for matcha stock monitor"
  vpc_id      = aws_vpc.monitor_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "marukyu-monitor-sg"
  }
}

# ─── CloudWatch Logs ────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "monitor" {
  name              = "/marukyu-monitor/logs"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "scheduler_lambda" {
  name              = "/aws/lambda/marukyu-monitor-scheduler"
  retention_in_days = 7
}

# ─── EC2 Instance IAM Role ──────────────────────────────────────────

resource "aws_iam_role" "ec2_instance" {
  name = "marukyu-monitor-ec2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ec2_cw_logs" {
  name = "cloudwatch-logs"
  role = aws_iam_role.ec2_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.monitor.arn}:*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_core" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ─── Telegram Secrets (SSM Parameter Store) ─────────────────────────

resource "aws_ssm_parameter" "telegram_bot_token" {
  count = var.telegram_bot_token != "" ? 1 : 0
  name  = "/marukyu-monitor/telegram/bot-token"
  type  = "SecureString"
  value = var.telegram_bot_token
}

resource "aws_ssm_parameter" "telegram_chat_id" {
  count = var.telegram_chat_id != "" ? 1 : 0
  name  = "/marukyu-monitor/telegram/chat-id"
  type  = "SecureString"
  value = var.telegram_chat_id
}

locals {
  telegram_ssm_arns = concat(
    var.telegram_bot_token != "" ? [aws_ssm_parameter.telegram_bot_token[0].arn] : [],
    var.telegram_chat_id != "" ? [aws_ssm_parameter.telegram_chat_id[0].arn] : [],
  )
}

resource "aws_iam_role_policy" "ec2_ssm_secrets" {
  count = length(local.telegram_ssm_arns) > 0 ? 1 : 0
  name  = "ssm-telegram-secrets"
  role  = aws_iam_role.ec2_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = local.telegram_ssm_arns
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "marukyu-monitor-ec2-profile"
  role = aws_iam_role.ec2_instance.name
}

# ─── EC2 Instance ───────────────────────────────────────────────────

resource "aws_instance" "monitor" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.monitor_subnet.id
  vpc_security_group_ids = [aws_security_group.monitor_sg.id]

  iam_instance_profile = aws_iam_instance_profile.ec2.name

  user_data_base64 = base64gzip(templatefile("${path.module}/user_data.sh.tftpl", {
    monitor_script      = file("${path.module}/../monitor_light.py")
    poll_interval       = var.poll_interval
    log_group_name      = aws_cloudwatch_log_group.monitor.name
    region              = var.region
    ssm_bot_token_param = var.telegram_bot_token != "" ? aws_ssm_parameter.telegram_bot_token[0].name : ""
    ssm_chat_id_param   = var.telegram_chat_id != "" ? aws_ssm_parameter.telegram_chat_id[0].name : ""
  }))

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  tags = {
    Name = "marukyu-matcha-monitor"
  }
}

# ─── Lambda: Instance Scheduler ─────────────────────────────────────

data "archive_file" "scheduler_lambda" {
  type        = "zip"
  output_path = "${path.module}/lambda/scheduler.zip"
  source_file = "${path.module}/lambda/scheduler.py"
}

resource "aws_iam_role" "scheduler_lambda" {
  name = "marukyu-monitor-scheduler-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_ec2" {
  name = "ec2-start-stop"
  role = aws_iam_role.scheduler_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:StartInstances",
        "ec2:StopInstances",
      ]
      Resource = aws_instance.monitor.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "scheduler_basic" {
  role       = aws_iam_role.scheduler_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "scheduler" {
  filename         = data.archive_file.scheduler_lambda.output_path
  source_code_hash = data.archive_file.scheduler_lambda.output_base64sha256
  function_name    = "marukyu-monitor-scheduler"
  role             = aws_iam_role.scheduler_lambda.arn
  handler          = "scheduler.handler"
  runtime          = "python3.10"
  timeout          = 30

  environment {
    variables = {
      REGION = var.region
    }
  }
}

# ─── EventBridge: Start Schedule (9:30 AM JST = 00:30 UTC) ──────────

resource "aws_cloudwatch_event_rule" "start" {
  name                = "marukyu-monitor-start"
  schedule_expression = "cron(30 0 ? * MON-FRI *)"
  description         = "Start monitor instance at 9:30 AM JST (weekdays)"
}

resource "aws_cloudwatch_event_target" "start" {
  rule      = aws_cloudwatch_event_rule.start.name
  target_id = "StartInstance"
  arn       = aws_lambda_function.scheduler.arn

  input = jsonencode({
    action       = "start"
    instance_ids = [aws_instance.monitor.id]
  })
}

resource "aws_lambda_permission" "allow_start" {
  statement_id  = "AllowStartFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scheduler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.start.arn
}

# ─── EventBridge: Stop Schedule (5:30 PM JST = 08:30 UTC) ───────────

resource "aws_cloudwatch_event_rule" "stop" {
  name                = "marukyu-monitor-stop"
  schedule_expression = "cron(30 8 ? * MON-FRI *)"
  description         = "Stop monitor instance at 5:30 PM JST (weekdays)"
}

resource "aws_cloudwatch_event_target" "stop" {
  rule      = aws_cloudwatch_event_rule.stop.name
  target_id = "StopInstance"
  arn       = aws_lambda_function.scheduler.arn

  input = jsonencode({
    action       = "stop"
    instance_ids = [aws_instance.monitor.id]
  })
}

resource "aws_lambda_permission" "allow_stop" {
  statement_id  = "AllowStopFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scheduler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.stop.arn
}

# ─── CloudWatch Alarm: Lambda Scheduler Errors ──────────────────────

resource "aws_cloudwatch_metric_alarm" "scheduler_errors" {
  alarm_name          = "marukyu-scheduler-lambda-errors"
  alarm_description   = "Scheduler Lambda failed to start/stop the EC2 instance"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.scheduler.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
}

# ─── Outputs ────────────────────────────────────────────────────────

output "instance_public_ip" {
  value = aws_instance.monitor.public_ip
}

output "instance_id" {
  value = aws_instance.monitor.id
}

output "ssm_session_command" {
  value = "aws ssm start-session --target ${aws_instance.monitor.id} --region ${var.region} --profile ${var.aws_profile}"
}

output "log_group" {
  value = aws_cloudwatch_log_group.monitor.name
}

output "lambda_function" {
  value = aws_lambda_function.scheduler.function_name
}
