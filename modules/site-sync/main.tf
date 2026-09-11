data "aws_partition" "current" {}

locals {
  partition = data.aws_partition.current.partition
}

data "archive_file" "sync" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.build/site-sync.zip"
  excludes    = ["__pycache__"]
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sync" {
  name               = "${var.name}-site-sync"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "sync_logs" {
  role       = aws_iam_role.sync.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "sync" {
  statement {
    sid       = "ListSitePrefix"
    actions   = ["s3:ListBucket"]
    resources = [var.docs_bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["site/*"]
    }
  }

  statement {
    sid       = "MirrorSitePrefix"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.docs_bucket_arn}/site/*"]
  }

  statement {
    sid       = "Ingestion"
    actions   = ["bedrock:StartIngestionJob", "bedrock:ListIngestionJobs"]
    resources = [var.knowledge_base_arn]
  }
}

resource "aws_iam_role_policy" "sync" {
  name   = "site-sync"
  role   = aws_iam_role.sync.id
  policy = data.aws_iam_policy_document.sync.json
}

resource "aws_cloudwatch_log_group" "sync" {
  name              = "/aws/lambda/${var.name}-site-sync"
  retention_in_days = 14
}

resource "aws_lambda_function" "sync" {
  function_name    = "${var.name}-site-sync"
  description      = "Mirror published WordPress pages/posts into the knowledge base"
  role             = aws_iam_role.sync.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  timeout          = 600
  memory_size      = 256
  filename         = data.archive_file.sync.output_path
  source_code_hash = data.archive_file.sync.output_base64sha256

  environment {
    variables = {
      SITE_BASE_URL     = var.site_base_url
      SITE_PUBLIC_URL   = var.site_public_url
      DOCS_BUCKET       = var.docs_bucket
      SITE_PREFIX       = "site/"
      POST_TYPES        = join(",", var.post_types)
      KNOWLEDGE_BASE_ID = var.knowledge_base_id
      DATA_SOURCE_ID    = var.data_source_id
    }
  }

  logging_config {
    log_format = "JSON"
  }

  depends_on = [aws_cloudwatch_log_group.sync, aws_iam_role_policy_attachment.sync_logs]
}

########################################
# Daily schedule (EventBridge Scheduler)
########################################

data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.name}-site-sync-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.sync.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "invoke-site-sync"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "nightly" {
  name                         = "${var.name}-site-sync"
  description                  = "Daily sync of WordPress content into the knowledge base"
  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 30
  }

  target {
    arn      = aws_lambda_function.sync.arn
    role_arn = aws_iam_role.scheduler.arn

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }
}
