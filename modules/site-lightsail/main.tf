locals {
  user_data = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    domain_name          = var.domain_name
    origin_hostname      = var.origin_hostname
    origin_tls           = var.origin_tls
    letsencrypt_email    = coalesce(var.letsencrypt_email, "admin@${var.domain_name}")
    origin_verify_secret = var.origin_verify_secret
    wp_admin_user        = var.wp_admin_user
    wp_admin_email       = var.wp_admin_email
    wp_admin_password    = var.wp_admin_password
    business_name        = replace(var.business_name, "/[\"$`\\\\]/", "")
    inject_chat_widget   = var.inject_chat_widget
  })
}

resource "aws_lightsail_instance" "wp" {
  name              = "${var.name}-wordpress"
  availability_zone = var.availability_zone
  blueprint_id      = var.blueprint_id
  bundle_id         = var.bundle_id
  ip_address_type   = "ipv4"
  user_data         = local.user_data

  add_on {
    type          = "AutoSnapshot"
    snapshot_time = var.snapshot_time
    status        = "Enabled"
  }

  lifecycle {
    # The bootstrap script only runs at first boot; changing it must not
    # recreate a live site. Re-run it by hand over SSH if needed.
    ignore_changes = [user_data]
  }
}

resource "aws_lightsail_static_ip" "this" {
  name = "${var.name}-wordpress-ip"
}

resource "aws_lightsail_static_ip_attachment" "this" {
  static_ip_name = aws_lightsail_static_ip.this.name
  instance_name  = aws_lightsail_instance.wp.name
}

# Lightsail firewall. Only the ports listed here are open.
#  80/443: reached by CloudFront (and by Let's Encrypt on 80). Apache refuses
#          anything without the origin-verify header, so this is not a bypass.
#  22:     admin CIDRs plus the Lightsail browser-based SSH console.
resource "aws_lightsail_instance_public_ports" "wp" {
  instance_name = aws_lightsail_instance.wp.name

  port_info {
    protocol  = "tcp"
    from_port = 80
    to_port   = 80
  }

  dynamic "port_info" {
    for_each = var.origin_tls ? [1] : []
    content {
      protocol  = "tcp"
      from_port = 443
      to_port   = 443
    }
  }

  port_info {
    protocol          = "tcp"
    from_port         = 22
    to_port           = 22
    cidrs             = var.admin_cidrs
    cidr_list_aliases = ["lightsail-connect"]
  }

  depends_on = [aws_lightsail_static_ip_attachment.this]
}
