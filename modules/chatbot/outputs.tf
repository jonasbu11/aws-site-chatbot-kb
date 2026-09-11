output "api_domain" {
  description = "Hostname of the HTTP API (no scheme, no path). Used as a CloudFront origin."
  value       = replace(aws_apigatewayv2_api.this.api_endpoint, "https://", "")
}

output "api_endpoint" {
  value = aws_apigatewayv2_api.this.api_endpoint
}

output "lambda_function_name" {
  value = aws_lambda_function.chat.function_name
}

output "guardrail_id" {
  value = var.enable_guardrail ? aws_bedrock_guardrail.this[0].guardrail_id : null
}

output "chat_log_table" {
  value = var.enable_chat_logs ? aws_dynamodb_table.chat_log[0].name : null
}
