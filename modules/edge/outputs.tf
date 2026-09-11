output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.this.domain_name
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.this.id
}

output "name_servers" {
  value = var.route53_zone_id == null ? aws_route53_zone.this[0].name_servers : null
}

output "zone_id" {
  value = local.zone_id
}

output "assets_bucket" {
  value = aws_s3_bucket.assets.bucket
}

output "web_acl_arn" {
  value = var.enable_waf ? aws_wafv2_web_acl.this[0].arn : null
}
