variable "name" {
  type = string
}

variable "business_name" {
  type = string
}

variable "knowledge_base_id" {
  type = string
}

variable "knowledge_base_arn" {
  type = string
}

variable "model_primary" {
  type = string
}

variable "model_fallback" {
  type    = string
  default = null
}

variable "system_prompt" {
  type = string
}

variable "max_tokens" {
  type = number
}

variable "temperature" {
  type = number
}

variable "retrieval_results" {
  type = number
}

variable "max_history_turns" {
  type = number
}

variable "enable_guardrail" {
  type = bool
}

variable "enable_chat_logs" {
  type = bool
}

variable "origin_verify_secret" {
  type      = string
  sensitive = true
}

variable "lambda_memory_mb" {
  type    = number
  default = 512
}

variable "lambda_timeout_seconds" {
  type    = number
  default = 60
}

variable "api_throttle_rate" {
  description = "Steady-state requests per second allowed by the API stage."
  type        = number
  default     = 10
}

variable "api_throttle_burst" {
  type    = number
  default = 20
}
