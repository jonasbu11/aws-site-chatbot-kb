variable "name" {
  type = string
}

variable "site_base_url" {
  description = "Base URL the sync reads the WordPress REST API from (no trailing slash)."
  type        = string
}

variable "site_public_url" {
  description = "The site's public address, used for the page-list document."
  type        = string
}

variable "docs_bucket" {
  type = string
}

variable "docs_bucket_arn" {
  type = string
}

variable "knowledge_base_id" {
  type = string
}

variable "knowledge_base_arn" {
  type = string
}

variable "data_source_id" {
  type = string
}

variable "post_types" {
  description = "WordPress REST collections to mirror, e.g. [\"pages\", \"posts\"] or add \"product\" for WooCommerce."
  type        = list(string)
}

variable "schedule_expression" {
  description = "EventBridge Scheduler expression, e.g. cron(0 3 * * ? *)."
  type        = string
}

variable "schedule_timezone" {
  type = string
}
