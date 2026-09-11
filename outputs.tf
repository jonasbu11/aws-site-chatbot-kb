output "site_url" {
  value = "https://${var.domain_name}"
}

output "wp_admin_url" {
  value = "https://${var.domain_name}/wp-admin/"
}

output "wp_admin_user" {
  value = var.wp_admin_user
}

output "wp_admin_password" {
  description = "Set at first boot. Read with: terraform output -raw wp_admin_password"
  value       = random_password.wp_admin.result
  sensitive   = true
}

output "route53_name_servers" {
  description = "Point your registrar at these when the zone was created by this template."
  value       = module.edge.name_servers
}

output "cloudfront_domain_name" {
  value = module.edge.cloudfront_domain_name
}

output "lightsail_static_ip" {
  description = "Origin IP. SSH from admin_cidrs or the Lightsail browser console; first-boot log is /var/log/site-bootstrap.log."
  value       = module.site.static_ip
}

output "lightsail_instance_name" {
  value = module.site.instance_name
}

output "kb_docs_bucket" {
  description = "Upload knowledge-base documents here (PDF, DOCX, HTML, MD, TXT, CSV). Ingestion starts automatically."
  value       = module.kb.docs_bucket
}

output "knowledge_base_id" {
  value = module.kb.knowledge_base_id
}

output "kb_data_source_id" {
  value = module.kb.data_source_id
}

output "chat_api_url" {
  description = "Public chat endpoint (only reachable through CloudFront)."
  value       = "https://${var.domain_name}/api/chat"
}

output "widget_snippet" {
  description = "Installed automatically as a must-use plugin when inject_chat_widget = true. Only needed by hand for a site built with inject_chat_widget = false or hosted elsewhere."
  value       = "<script src=\"https://${var.domain_name}/chat-widget/widget.js\" defer></script>"
}

output "chat_model_primary" {
  value = var.chat_model_primary
}

output "guardrail_id" {
  value = module.chatbot.guardrail_id
}

output "region" {
  value = var.region
}

output "aws_profile" {
  value = var.aws_profile
}
