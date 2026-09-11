output "static_ip" {
  value = aws_lightsail_static_ip.this.ip_address
}

output "instance_name" {
  value = aws_lightsail_instance.wp.name
}

output "instance_arn" {
  value = aws_lightsail_instance.wp.arn
}
