data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition
}

########################################
# Guardrail (optional)
########################################

resource "aws_bedrock_guardrail" "this" {
  count = var.enable_guardrail ? 1 : 0

  name                      = "${var.name}-chat"
  description               = "Website assistant guardrail for ${var.name}"
  blocked_input_messaging   = "I can't help with that request. Please ask something about ${var.business_name}."
  blocked_outputs_messaging = "I can't provide that response. Please contact ${var.business_name} directly."

  content_policy_config {
    dynamic "filters_config" {
      for_each = toset(["HATE", "INSULTS", "SEXUAL", "VIOLENCE", "MISCONDUCT"])
      content {
        type            = filters_config.value
        input_strength  = "MEDIUM"
        output_strength = "MEDIUM"
      }
    }
    # Prompt-attack filtering is input-only; output strength must be NONE.
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "HIGH"
      output_strength = "NONE"
    }
  }

  sensitive_information_policy_config {
    pii_entities_config {
      type   = "US_SOCIAL_SECURITY_NUMBER"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_NUMBER"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "US_BANK_ACCOUNT_NUMBER"
      action = "BLOCK"
    }
  }

  word_policy_config {
    managed_word_lists_config {
      type = "PROFANITY"
    }
  }
}

resource "aws_bedrock_guardrail_version" "this" {
  count = var.enable_guardrail ? 1 : 0

  guardrail_arn = aws_bedrock_guardrail.this[0].guardrail_arn
  description   = "managed by terraform"
  skip_destroy  = false
}

########################################
# Optional chat log
########################################

resource "aws_dynamodb_table" "chat_log" {
  count = var.enable_chat_logs ? 1 : 0

  name         = "${var.name}-chat-log"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "session_id"
  range_key    = "ts"

  attribute {
    name = "session_id"
    type = "S"
  }
  attribute {
    name = "ts"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false
  }
}

########################################
# Lambda
########################################

data "archive_file" "chat" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.build/chat.zip"
  excludes    = ["tests", "__pycache__", "tests/__pycache__"]
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

resource "aws_iam_role" "chat" {
  name               = "${var.name}-chat"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "chat_logs" {
  role       = aws_iam_role.chat.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "chat" {
  statement {
    sid       = "Retrieve"
    actions   = ["bedrock:Retrieve"]
    resources = [var.knowledge_base_arn]
  }

  # Cross-region inference profiles (global./us.) resolve to foundation models
  # in several regions, so both the profile and the model ARNs are needed.
  statement {
    sid = "Converse"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = [
      "arn:${local.partition}:bedrock:*::foundation-model/*",
      "arn:${local.partition}:bedrock:*:${local.account_id}:inference-profile/*",
    ]
  }

  dynamic "statement" {
    for_each = var.enable_guardrail ? [1] : []
    content {
      sid       = "Guardrail"
      actions   = ["bedrock:ApplyGuardrail"]
      resources = [aws_bedrock_guardrail.this[0].guardrail_arn]
    }
  }

  dynamic "statement" {
    for_each = var.enable_chat_logs ? [1] : []
    content {
      sid       = "ChatLog"
      actions   = ["dynamodb:PutItem"]
      resources = [aws_dynamodb_table.chat_log[0].arn]
    }
  }
}

resource "aws_iam_role_policy" "chat" {
  name   = "chat-access"
  role   = aws_iam_role.chat.id
  policy = data.aws_iam_policy_document.chat.json
}

resource "aws_cloudwatch_log_group" "chat" {
  name              = "/aws/lambda/${var.name}-chat"
  retention_in_days = 14
}

resource "aws_lambda_function" "chat" {
  function_name    = "${var.name}-chat"
  role             = aws_iam_role.chat.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  timeout          = var.lambda_timeout_seconds
  memory_size      = var.lambda_memory_mb
  filename         = data.archive_file.chat.output_path
  source_code_hash = data.archive_file.chat.output_base64sha256

  environment {
    variables = {
      KNOWLEDGE_BASE_ID    = var.knowledge_base_id
      MODEL_PRIMARY        = var.model_primary
      MODEL_FALLBACK       = coalesce(var.model_fallback, "")
      SYSTEM_PROMPT        = replace(var.system_prompt, "{business_name}", var.business_name)
      MAX_TOKENS           = tostring(var.max_tokens)
      TEMPERATURE          = tostring(var.temperature)
      RETRIEVAL_RESULTS    = tostring(var.retrieval_results)
      MAX_HISTORY_TURNS    = tostring(var.max_history_turns)
      GUARDRAIL_ID         = var.enable_guardrail ? aws_bedrock_guardrail.this[0].guardrail_id : ""
      GUARDRAIL_VERSION    = var.enable_guardrail ? aws_bedrock_guardrail_version.this[0].version : ""
      CHAT_LOG_TABLE       = var.enable_chat_logs ? aws_dynamodb_table.chat_log[0].name : ""
      ORIGIN_VERIFY_SECRET = var.origin_verify_secret
    }
  }

  logging_config {
    log_format = "JSON"
  }

  depends_on = [aws_cloudwatch_log_group.chat, aws_iam_role_policy_attachment.chat_logs]
}

########################################
# HTTP API
########################################

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name}-chat"
  protocol_type = "HTTP"
  description   = "Chat API for ${var.name}; reachable only through CloudFront"
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${var.name}-chat"
  retention_in_days = 14
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.api_throttle_rate
    throttling_burst_limit = var.api_throttle_burst
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId = "$context.requestId"
      ip        = "$context.identity.sourceIp"
      time      = "$context.requestTime"
      method    = "$context.httpMethod"
      path      = "$context.path"
      status    = "$context.status"
      latency   = "$context.responseLatency"
      error     = "$context.error.message"
    })
  }
}

resource "aws_apigatewayv2_integration" "chat" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.chat.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

resource "aws_apigatewayv2_route" "chat" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /api/chat"
  target    = "integrations/${aws_apigatewayv2_integration.chat.id}"
}

resource "aws_apigatewayv2_route" "health" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /api/health"
  target    = "integrations/${aws_apigatewayv2_integration.chat.id}"
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
