variable "name" {
  type = string
}

variable "domain_name" {
  type = string
}

variable "blueprint_id" {
  type = string
}

variable "bundle_id" {
  type = string
}

variable "availability_zone" {
  type = string
}

variable "snapshot_time" {
  type = string
}

variable "admin_cidrs" {
  type = list(string)
}

variable "origin_tls" {
  type = bool
}

variable "origin_hostname" {
  description = "Hostname CloudFront uses to reach the origin when origin_tls is true (e.g. origin.example.com)."
  type        = string
}

variable "letsencrypt_email" {
  type    = string
  default = null
}

variable "origin_verify_secret" {
  type      = string
  sensitive = true
}
