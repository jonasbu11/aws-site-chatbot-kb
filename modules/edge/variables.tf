variable "name" {
  type = string
}

variable "domain_name" {
  type = string
}

variable "alternate_names" {
  type = list(string)
}

variable "route53_zone_id" {
  type    = string
  default = null
}

variable "origin_tls" {
  type = bool
}

variable "origin_hostname" {
  description = "DNS name created for the origin when origin_tls is true."
  type        = string
}

variable "origin_static_ip" {
  type = string
}

variable "origin_verify_secret" {
  type      = string
  sensitive = true
}

variable "api_domain" {
  type = string
}

variable "page_cache_default_ttl" {
  type = number
}

variable "enable_waf" {
  type = bool
}

variable "waf_rate_limit_site" {
  type = number
}

variable "waf_rate_limit_api" {
  type = number
}

variable "admin_cidrs" {
  type = list(string)
}

variable "price_class" {
  type = string
}

variable "business_name" {
  type = string
}

variable "widget" {
  type = object({
    title         = optional(string, "Ask us anything")
    greeting      = optional(string, "Hi! Ask me a question about our business.")
    primary_color = optional(string, "#1f4e79")
    position      = optional(string, "right")
  })
}
