# china-proxy Lightsail infra.
#
# SSH KEY: aws_lightsail_key_pair.main generates the key server-side and
# exposes the private half as output.ssh_private_key_pem (sensitive, also
# stored in state). After first apply, save it ONCE and never commit:
#   tofu output -raw ssh_private_key_pem > ~/.ssh/china-proxy.pem
#   chmod 600 ~/.ssh/china-proxy.pem
#
# SECRETS IN STATE: user_data embeds secrets via templatefile, so
# tofu.tfstate* contains secret values. Accepted for a single-user travel
# proxy: keep state local, chmod 600, never commit (see .gitignore).
#
# UPDATES: Lightsail user_data runs ONLY on first boot. Config changes after
# creation go through scripts/redeploy.sh over SSH, never by editing files on
# the VPS or by expecting `tofu apply` to re-run user_data.

locals {
  # Single source of truth: docker/* templates rendered here, baked into
  # user_data. Nothing is cloned or templated on the VPS itself.
  compose_yaml = templatefile("${path.module}/../docker/compose.yml", {
    xray_image = var.xray_image
    hy2_image  = var.hy2_image
  })

  xray_config = templatefile("${path.module}/../docker/xray/config.json.tmpl", {
    xray_uuid           = var.xray_uuid
    reality_private_key = var.reality_private_key
    reality_short_id    = var.reality_short_id
    reality_dest        = var.reality_dest
    reality_server_name = var.reality_server_name
  })

  hysteria_config = templatefile("${path.module}/../docker/hysteria/config.yaml.tmpl", {
    domain_name  = var.domain_name
    acme_email   = var.acme_email
    hy2_password = var.hy2_password
  })
}

resource "aws_lightsail_key_pair" "main" {
  name = "${var.instance_name}-key"
}

resource "aws_lightsail_instance" "proxy" {
  name              = var.instance_name
  availability_zone = var.az
  blueprint_id      = var.blueprint_id
  bundle_id         = var.bundle_id
  key_pair_name     = aws_lightsail_key_pair.main.name
  user_data = templatefile("${path.module}/user_data.tmpl.sh", {
    compose_yaml    = local.compose_yaml
    xray_config     = local.xray_config
    hysteria_config = local.hysteria_config
  })
}

resource "aws_lightsail_static_ip" "proxy" {
  name = "${var.instance_name}-ip"
}

resource "aws_lightsail_static_ip_attachment" "proxy" {
  static_ip_name = aws_lightsail_static_ip.proxy.name
  instance_name  = aws_lightsail_instance.proxy.name
}

resource "aws_lightsail_instance_public_ports" "proxy" {
  instance_name = aws_lightsail_instance.proxy.name

  # SSH. Tighten var.ssh_allowed_cidr to your IP once known.
  port_info {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"
    cidrs     = [var.ssh_allowed_cidr]
  }

  # Hysteria2 ACME http-01 only. TCP 443 belongs to Xray, so tls-alpn-01 is impossible.
  port_info {
    from_port = 80
    to_port   = 80
    protocol  = "tcp"
    cidrs     = ["0.0.0.0/0"]
  }

  # Xray VLESS-REALITY.
  port_info {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"
    cidrs     = ["0.0.0.0/0"]
  }

  # Hysteria2 (QUIC/UDP). TCP/UDP 443 split by protocol, no port conflict.
  port_info {
    from_port = 443
    to_port   = 443
    protocol  = "udp"
    cidrs     = ["0.0.0.0/0"]
  }
}
