locals {
  tags = merge(
    {
      Project   = var.name
      ManagedBy = "terraform"
      Template  = "aws-site-chatbot-kb"
    },
    var.tags,
  )

  alternate_names = var.alternate_names == null ? ["www.${var.domain_name}"] : var.alternate_names
  origin_hostname = "origin.${var.domain_name}"
}

# Shared secret that CloudFront adds to every origin request. The WordPress
# origin (Apache) and the chat API (Lambda) both refuse requests without it,
# so neither can be reached around CloudFront and WAF.
resource "random_password" "origin_verify" {
  length  = 40
  special = false
}

########################################
# Knowledge base: S3 docs -> Bedrock KB on S3 Vectors
########################################

module "kb" {
  source = "./modules/kb"

  name                     = var.name
  embedding_model_id       = var.embedding_model_id
  embedding_dimensions     = var.embedding_dimensions
  chunk_max_tokens         = var.chunk_max_tokens
  chunk_overlap_percentage = var.chunk_overlap_percentage
}

########################################
# Chatbot: Lambda (retrieve + converse) behind an HTTP API
########################################

module "chatbot" {
  source = "./modules/chatbot"

  name                 = var.name
  business_name        = var.business_name
  knowledge_base_id    = module.kb.knowledge_base_id
  knowledge_base_arn   = module.kb.knowledge_base_arn
  model_primary        = var.chat_model_primary
  model_fallback       = var.chat_model_fallback
  system_prompt        = var.chat_system_prompt
  max_tokens           = var.chat_max_tokens
  temperature          = var.chat_temperature
  retrieval_results    = var.chat_retrieval_results
  max_history_turns    = var.chat_max_history_turns
  enable_guardrail     = var.enable_guardrail
  enable_chat_logs     = var.enable_chat_logs
  origin_verify_secret = random_password.origin_verify.result
}

########################################
# WordPress on Lightsail
########################################

module "site" {
  source = "./modules/site-lightsail"

  name                 = var.name
  domain_name          = var.domain_name
  blueprint_id         = var.lightsail_blueprint_id
  bundle_id            = var.lightsail_bundle_id
  availability_zone    = coalesce(var.lightsail_availability_zone, "${var.region}a")
  snapshot_time        = var.lightsail_snapshot_time
  admin_cidrs          = var.admin_cidrs
  origin_tls           = var.origin_tls
  origin_hostname      = local.origin_hostname
  letsencrypt_email    = var.letsencrypt_email
  origin_verify_secret = random_password.origin_verify.result
}

########################################
# Edge: Route 53, ACM, CloudFront, WAF, widget assets
########################################

module "edge" {
  source = "./modules/edge"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name                   = var.name
  domain_name            = var.domain_name
  alternate_names        = local.alternate_names
  route53_zone_id        = var.route53_zone_id
  origin_tls             = var.origin_tls
  origin_hostname        = local.origin_hostname
  origin_static_ip       = module.site.static_ip
  origin_verify_secret   = random_password.origin_verify.result
  api_domain             = module.chatbot.api_domain
  page_cache_default_ttl = var.page_cache_default_ttl
  enable_waf             = var.enable_waf
  waf_rate_limit_site    = var.waf_rate_limit_site
  waf_rate_limit_api     = var.waf_rate_limit_api
  admin_cidrs            = var.admin_cidrs
  price_class            = var.cloudfront_price_class
  business_name          = var.business_name
  widget                 = var.widget
}

########################################
# Cost guardrail
########################################

resource "aws_budgets_budget" "monthly" {
  count = var.budget_monthly_usd == null ? 0 : 1

  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_monthly_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }

  lifecycle {
    precondition {
      condition     = var.budget_email != null
      error_message = "budget_email is required when budget_monthly_usd is set."
    }
  }
}
