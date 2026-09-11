terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  all_names  = concat([var.domain_name], var.alternate_names)
  zone_id    = var.route53_zone_id == null ? aws_route53_zone.this[0].zone_id : var.route53_zone_id

  # AWS managed CloudFront policies (IDs verified 2026-09-11).
  cache_disabled         = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
  orp_all_viewer         = "216adef6-5c7f-47e4-b989-5492eafa07d3"
  orp_all_viewer_no_host = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
  orp_cors_s3            = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf"
  rhp_security_headers   = "67f7725c-6f97-4210-82d7-5512b31e9d03"
  page_cache_policy_id   = var.page_cache_default_ttl > 0 ? aws_cloudfront_cache_policy.wp_pages[0].id : local.cache_disabled
  wp_dynamic_paths       = ["/wp-admin/*", "/wp-login.php", "/wp-json/*", "/wp-cron.php", "/xmlrpc.php", "/wp-comments-post.php"]
  wp_static_paths        = ["/wp-content/*", "/wp-includes/*"]
  all_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
  read_methods           = ["GET", "HEAD", "OPTIONS"]
}

########################################
# DNS
########################################

resource "aws_route53_zone" "this" {
  count   = var.route53_zone_id == null ? 1 : 0
  name    = var.domain_name
  comment = "Managed by terraform (${var.name})"
}

# CloudFront custom origins must be DNS names, so the Lightsail IP always gets one.
resource "aws_route53_record" "origin" {
  zone_id = local.zone_id
  name    = var.origin_hostname
  type    = "A"
  ttl     = 300
  records = [var.origin_static_ip]
}

resource "aws_route53_record" "site_a" {
  for_each = toset(local.all_names)

  zone_id = local.zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "site_aaaa" {
  for_each = toset(local.all_names)

  zone_id = local.zone_id
  name    = each.value
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}

########################################
# Certificate (us-east-1 for CloudFront)
########################################

resource "aws_acm_certificate" "site" {
  provider = aws.us_east_1

  domain_name               = var.domain_name
  subject_alternative_names = var.alternate_names
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.site.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = local.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "site" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

########################################
# Widget assets (private S3 behind CloudFront)
########################################

resource "aws_s3_bucket" "assets" {
  bucket        = "${var.name}-site-assets-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "assets" {
  name                              = "${var.name}-assets"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "assets" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.assets.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "assets" {
  bucket = aws_s3_bucket.assets.id
  policy = data.aws_iam_policy_document.assets.json
}

resource "aws_s3_object" "widget_js" {
  bucket       = aws_s3_bucket.assets.id
  key          = "chat-widget/widget.js"
  content_type = "application/javascript; charset=utf-8"
  content = templatefile("${path.module}/widget/widget.js.tftpl", {
    api_path      = "/api/chat"
    title         = var.widget.title
    greeting      = var.widget.greeting
    primary_color = var.widget.primary_color
    position      = var.widget.position
    business_name = var.business_name
  })
  cache_control = "public, max-age=300"
  etag = md5(templatefile("${path.module}/widget/widget.js.tftpl", {
    api_path      = "/api/chat"
    title         = var.widget.title
    greeting      = var.widget.greeting
    primary_color = var.widget.primary_color
    position      = var.widget.position
    business_name = var.business_name
  }))
}

########################################
# Cache policies
########################################

# Anonymous page HTML cached briefly. All cookies are part of the cache key:
# WordPress auth cookies carry a hash suffix (wordpress_logged_in_<hash>) and
# cache policies cannot wildcard names, so "all" is the only setting that
# guarantees a logged-in user never receives, or seeds, an anonymous page.
# Visitors with no cookies share cached pages; everyone else goes to origin.
resource "aws_cloudfront_cache_policy" "wp_pages" {
  count = var.page_cache_default_ttl > 0 ? 1 : 0

  name        = "${var.name}-wp-pages"
  comment     = "WordPress pages: short TTL, all cookies in key"
  default_ttl = var.page_cache_default_ttl
  min_ttl     = 0
  max_ttl     = 86400

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    cookies_config {
      cookie_behavior = "all"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "all"
    }
  }
}

resource "aws_cloudfront_cache_policy" "wp_static" {
  name        = "${var.name}-wp-static"
  comment     = "WordPress static assets: long TTL, query string (?ver=) in key"
  default_ttl = 86400
  min_ttl     = 0
  max_ttl     = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "all"
    }
  }
}

resource "aws_cloudfront_cache_policy" "widget" {
  name        = "${var.name}-widget"
  default_ttl = 300
  min_ttl     = 0
  max_ttl     = 3600

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

########################################
# WAF (CLOUDFRONT scope lives in us-east-1)
########################################

resource "aws_wafv2_ip_set" "admin" {
  count    = var.enable_waf && length(var.admin_cidrs) > 0 ? 1 : 0
  provider = aws.us_east_1

  name               = "${var.name}-admin-ips"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = var.admin_cidrs
}

resource "aws_wafv2_web_acl" "this" {
  count    = var.enable_waf ? 1 : 0
  provider = aws.us_east_1

  name  = "${var.name}-site"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "aws-ip-reputation"
    priority = 0
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-common"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        # WordPress editors post large HTML bodies; these three false-positive constantly.
        dynamic "rule_action_override" {
          for_each = toset(["SizeRestrictions_BODY", "GenericRFI_BODY", "CrossSiteScripting_BODY"])
          content {
            name = rule_action_override.value
            action_to_use {
              count {}
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-wordpress"
    priority = 3
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesWordPressRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "wordpress"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "block-xmlrpc"
    priority = 4
    action {
      block {}
    }
    statement {
      byte_match_statement {
        search_string         = "/xmlrpc.php"
        positional_constraint = "STARTS_WITH"
        field_to_match {
          uri_path {}
        }
        text_transformation {
          priority = 0
          type     = "LOWERCASE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "block-xmlrpc"
      sampled_requests_enabled   = true
    }
  }

  # wp-admin / wp-login only from admin_cidrs (admin-ajax.php stays open; front-end plugins use it).
  dynamic "rule" {
    for_each = length(var.admin_cidrs) > 0 ? [1] : []
    content {
      name     = "admin-allowlist"
      priority = 5
      action {
        block {}
      }
      statement {
        and_statement {
          statement {
            or_statement {
              statement {
                byte_match_statement {
                  search_string         = "/wp-login.php"
                  positional_constraint = "STARTS_WITH"
                  field_to_match {
                    uri_path {}
                  }
                  text_transformation {
                    priority = 0
                    type     = "LOWERCASE"
                  }
                }
              }
              statement {
                byte_match_statement {
                  search_string         = "/wp-admin/"
                  positional_constraint = "STARTS_WITH"
                  field_to_match {
                    uri_path {}
                  }
                  text_transformation {
                    priority = 0
                    type     = "LOWERCASE"
                  }
                }
              }
            }
          }
          statement {
            not_statement {
              statement {
                byte_match_statement {
                  search_string         = "/wp-admin/admin-ajax.php"
                  positional_constraint = "STARTS_WITH"
                  field_to_match {
                    uri_path {}
                  }
                  text_transformation {
                    priority = 0
                    type     = "LOWERCASE"
                  }
                }
              }
            }
          }
          statement {
            not_statement {
              statement {
                ip_set_reference_statement {
                  arn = aws_wafv2_ip_set.admin[0].arn
                }
              }
            }
          }
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "admin-allowlist"
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "rate-limit-api"
    priority = 6
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit                 = var.waf_rate_limit_api
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-api"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "rate-limit-site"
    priority = 7
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit                 = var.waf_rate_limit_site
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-site"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-site"
    sampled_requests_enabled   = true
  }
}

########################################
# CloudFront
########################################

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  comment             = "${var.name}: WordPress + chat API + widget"
  aliases             = local.all_names
  price_class         = var.price_class
  http_version        = "http2and3"
  is_ipv6_enabled     = true
  web_acl_id          = var.enable_waf ? aws_wafv2_web_acl.this[0].arn : null
  wait_for_deployment = false

  # WordPress origin (Lightsail)
  origin {
    origin_id   = "wordpress"
    domain_name = var.origin_hostname

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = var.origin_tls ? "https-only" : "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 60
      origin_keepalive_timeout = 5
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = var.origin_verify_secret
    }
  }

  # Chat API origin (API Gateway HTTP API)
  origin {
    origin_id   = "chat-api"
    domain_name = var.api_domain

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      origin_read_timeout    = 60
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = var.origin_verify_secret
    }
  }

  # Widget assets (S3 via OAC)
  origin {
    origin_id                = "assets"
    domain_name              = aws_s3_bucket.assets.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.assets.id
  }

  # /api/* -> Lambda
  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "chat-api"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = local.all_methods
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = local.cache_disabled
    origin_request_policy_id = local.orp_all_viewer_no_host
  }

  # /chat-widget/* -> S3
  ordered_cache_behavior {
    path_pattern               = "/chat-widget/*"
    target_origin_id           = "assets"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = local.read_methods
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.widget.id
    origin_request_policy_id   = local.orp_cors_s3
    response_headers_policy_id = local.rhp_security_headers
  }

  # WordPress dynamic paths: never cached, everything forwarded
  dynamic "ordered_cache_behavior" {
    for_each = local.wp_dynamic_paths
    content {
      path_pattern               = ordered_cache_behavior.value
      target_origin_id           = "wordpress"
      viewer_protocol_policy     = "redirect-to-https"
      allowed_methods            = local.all_methods
      cached_methods             = ["GET", "HEAD"]
      compress                   = true
      cache_policy_id            = local.cache_disabled
      origin_request_policy_id   = local.orp_all_viewer
      response_headers_policy_id = local.rhp_security_headers
    }
  }

  # WordPress static assets: cached long
  dynamic "ordered_cache_behavior" {
    for_each = local.wp_static_paths
    content {
      path_pattern               = ordered_cache_behavior.value
      target_origin_id           = "wordpress"
      viewer_protocol_policy     = "redirect-to-https"
      allowed_methods            = local.read_methods
      cached_methods             = ["GET", "HEAD"]
      compress                   = true
      cache_policy_id            = aws_cloudfront_cache_policy.wp_static.id
      origin_request_policy_id   = local.orp_all_viewer
      response_headers_policy_id = local.rhp_security_headers
    }
  }

  # Everything else: WordPress pages
  default_cache_behavior {
    target_origin_id           = "wordpress"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = local.all_methods
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = local.page_cache_policy_id
    origin_request_policy_id   = local.orp_all_viewer
    response_headers_policy_id = local.rhp_security_headers
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}
