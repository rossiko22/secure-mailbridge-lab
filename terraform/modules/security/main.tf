# Implements the Tier 1 rows of ARCHITECTURE.md §4. Rules are separate resources
# so groups can reference each other without a dependency cycle.

locals {
  # Hosts behind fw-ips, which share the same baseline egress.
  private_groups = {
    proxy = aws_security_group.proxy.id
    app   = aws_security_group.app.id
    db    = aws_security_group.db.id
    siem  = aws_security_group.siem.id
  }

  # siem is excluded because its agent talks to the manager on the same host.
  agent_groups = { for name, id in local.private_groups : name => id if name != "siem" }

  agent_ports = [1514, 1515]

  agent_egress = merge([
    for name, id in local.agent_groups : {
      for port in local.agent_ports : "${name}-${port}" => { group_id = id, port = port }
    }
  ]...)
}

resource "aws_security_group" "fw" {
  name        = "${var.name}-fw"
  description = "fw-ips: OpenVPN entry point and router for private subnets"
  vpc_id      = var.vpc_id
}

resource "aws_security_group" "proxy" {
  name        = "${var.name}-proxy"
  description = "proxy: Nginx and ModSecurity, reachable from VPN pools"
  vpc_id      = var.vpc_id
}

resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "app: Mailbridge, reachable from proxy only"
  vpc_id      = var.vpc_id
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "db: PostgreSQL, reachable from app only"
  vpc_id      = var.vpc_id
}

resource "aws_security_group" "siem" {
  name        = "${var.name}-siem"
  description = "siem: Wazuh agents from the VPC, dashboard from admin pool"
  vpc_id      = var.vpc_id
}

resource "aws_network_interface_sg_attachment" "fw" {
  security_group_id    = aws_security_group.fw.id
  network_interface_id = var.fw_eni_id
}

# --- Ingress ---

resource "aws_vpc_security_group_ingress_rule" "fw_openvpn" {
  security_group_id = aws_security_group.fw.id
  description       = "OpenVPN"
  cidr_ipv4         = var.vpn_source_cidr
  ip_protocol       = "udp"
  from_port         = 1194
  to_port           = 1194
}

resource "aws_vpc_security_group_ingress_rule" "fw_from_vpc" {
  security_group_id = aws_security_group.fw.id
  description       = "Traffic from the VPC to be routed or NATed"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "fw_https_test_window" {
  count = var.open_https_test_window ? 1 : 0

  security_group_id = aws_security_group.fw.id
  description       = "HTTPS, outside-attack test windows only"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "proxy_https" {
  security_group_id = aws_security_group.proxy.id
  description       = "HTTPS from VPN pools"
  cidr_ipv4         = var.vpn_pools_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "app_from_proxy" {
  security_group_id            = aws_security_group.app.id
  description                  = "Mailbridge from proxy"
  referenced_security_group_id = aws_security_group.proxy.id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from app"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "siem_agents" {
  for_each = toset([for port in local.agent_ports : tostring(port)])

  security_group_id = aws_security_group.siem.id
  description       = "Wazuh agents"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
}

resource "aws_vpc_security_group_ingress_rule" "siem_dashboard" {
  security_group_id = aws_security_group.siem.id
  description       = "Wazuh dashboard from admin pool"
  cidr_ipv4         = var.admin_pool_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# --- Egress ---

resource "aws_vpc_security_group_egress_rule" "fw_all" {
  #checkov:skip=CKV_AWS_382:fw-ips forwards traffic for the whole VPC; nftables filters it.
  security_group_id = aws_security_group.fw.id
  description       = "Forwarded traffic, filtered by nftables"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "private_https" {
  for_each = local.private_groups

  security_group_id = each.value
  description       = "HTTPS to the internet through fw-ips"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "private_dns_udp" {
  for_each = local.private_groups

  security_group_id = each.value
  description       = "DNS to Unbound"
  cidr_ipv4         = "${var.fw_private_ip}/32"
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
}

resource "aws_vpc_security_group_egress_rule" "private_dns_tcp" {
  for_each = local.private_groups

  security_group_id = each.value
  description       = "DNS to Unbound"
  cidr_ipv4         = "${var.fw_private_ip}/32"
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
}

resource "aws_vpc_security_group_egress_rule" "private_ntp" {
  for_each = local.private_groups

  security_group_id = each.value
  description       = "NTP through fw-ips"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 123
  to_port           = 123
}

resource "aws_vpc_security_group_egress_rule" "wazuh_agents" {
  for_each = local.agent_egress

  security_group_id            = each.value.group_id
  description                  = "Wazuh agent to manager"
  referenced_security_group_id = aws_security_group.siem.id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}

resource "aws_vpc_security_group_egress_rule" "proxy_to_app" {
  security_group_id            = aws_security_group.proxy.id
  description                  = "Mailbridge upstream"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL"
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
