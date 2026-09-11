output "function_name" {
  value = aws_lambda_function.sync.function_name
}

output "schedule_name" {
  value = aws_scheduler_schedule.nightly.name
}
