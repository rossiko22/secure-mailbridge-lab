# Second layer from ARCHITECTURE.md §4: one stateless ACL per subnet.
# NACLs have no connection tracking, so replies need their own rules, and the
# first matching rule number wins.

locals {
  any = "0.0.0.0/0"
  tcp = "6"
  udp = "17"

  ephemeral = { from = 1024, to = 65535 }

  # Replies from the internet can come from anywhere, so this range must be open.
  # It includes service ports, which is why app, data and mgmt deny them at 105.
  return_inbound = [
    { protocol = local.tcp, cidr = local.any, from = local.ephemeral.from, to = local.ephemeral.to },
    { protocol = local.udp, cidr = local.any, from = local.ephemeral.from, to = local.ephemeral.to },
  ]

  baseline_outbound = [
    { number = 110, protocol = local.tcp, cidr = local.any, from = 443, to = 443 },
    { number = 120, protocol = local.udp, cidr = local.any, from = 123, to = 123 },
    { number = 130, protocol = local.udp, cidr = "${var.fw_private_ip}/32", from = 53, to = 53 },
    { number = 140, protocol = local.tcp, cidr = "${var.fw_private_ip}/32", from = 53, to = 53 },
  ]

  agents_outbound = {
    number = 150, protocol = local.tcp, cidr = var.subnet_cidrs["mgmt"], from = 1514, to = 1515
  }

  nacl_inbound = {
    public = concat(
      [
        { number = 100, action = "allow", protocol = local.udp, cidr = var.vpn_source_cidr, from = 1194, to = 1194 },
        { number = 110, action = "allow", protocol = "-1", cidr = var.vpc_cidr, from = null, to = null },
        merge(local.return_inbound[0], { number = 120, action = "allow" }),
        merge(local.return_inbound[1], { number = 130, action = "allow" }),
      ],
      var.open_https_test_window ? [
        { number = 140, action = "allow", protocol = local.tcp, cidr = local.any, from = 443, to = 443 },
      ] : [],
    )
    dmz = [
      { number = 100, action = "allow", protocol = local.tcp, cidr = var.vpn_pools_cidr, from = 443, to = 443 },
      merge(local.return_inbound[0], { number = 110, action = "allow" }),
      merge(local.return_inbound[1], { number = 120, action = "allow" }),
    ]
    app = [
      { number = 100, action = "allow", protocol = local.tcp, cidr = var.subnet_cidrs["dmz"], from = 3000, to = 3000 },
      { number = 105, action = "deny", protocol = local.tcp, cidr = local.any, from = 3000, to = 3000 },
      merge(local.return_inbound[0], { number = 110, action = "allow" }),
      merge(local.return_inbound[1], { number = 120, action = "allow" }),
    ]
    data = [
      { number = 100, action = "allow", protocol = local.tcp, cidr = var.subnet_cidrs["app"], from = 5432, to = 5432 },
      { number = 105, action = "deny", protocol = local.tcp, cidr = local.any, from = 5432, to = 5432 },
      merge(local.return_inbound[0], { number = 110, action = "allow" }),
      merge(local.return_inbound[1], { number = 120, action = "allow" }),
    ]
    mgmt = [
      { number = 100, action = "allow", protocol = local.tcp, cidr = var.vpc_cidr, from = 1514, to = 1515 },
      { number = 105, action = "deny", protocol = local.tcp, cidr = local.any, from = 1514, to = 1515 },
      { number = 110, action = "allow", protocol = local.tcp, cidr = var.admin_pool_cidr, from = 443, to = 443 },
      merge(local.return_inbound[0], { number = 120, action = "allow" }),
      merge(local.return_inbound[1], { number = 130, action = "allow" }),
    ]
  }

  nacl_outbound = {
    public = concat(
      [
        { number = 100, protocol = "-1", cidr = var.vpc_cidr, from = null, to = null },
        { number = 110, protocol = local.tcp, cidr = local.any, from = 443, to = 443 },
        { number = 120, protocol = local.udp, cidr = local.any, from = 123, to = 123 },
        { number = 130, protocol = local.udp, cidr = local.any, from = local.ephemeral.from, to = local.ephemeral.to },
      ],
      var.open_https_test_window ? [
        { number = 140, protocol = local.tcp, cidr = local.any, from = local.ephemeral.from, to = local.ephemeral.to },
      ] : [],
    )
    dmz = concat(local.baseline_outbound, [
      { number = 100, protocol = local.tcp, cidr = var.subnet_cidrs["app"], from = 3000, to = 3000 },
      local.agents_outbound,
      { number = 160, protocol = local.tcp, cidr = var.vpn_pools_cidr, from = local.ephemeral.from, to = local.ephemeral.to },
    ])
    app = concat(local.baseline_outbound, [
      { number = 100, protocol = local.tcp, cidr = var.subnet_cidrs["data"], from = 5432, to = 5432 },
      local.agents_outbound,
      { number = 160, protocol = local.tcp, cidr = var.subnet_cidrs["dmz"], from = local.ephemeral.from, to = local.ephemeral.to },
    ])
    data = concat(local.baseline_outbound, [
      local.agents_outbound,
      { number = 160, protocol = local.tcp, cidr = var.subnet_cidrs["app"], from = local.ephemeral.from, to = local.ephemeral.to },
    ])
    mgmt = concat(local.baseline_outbound, [
      { number = 160, protocol = local.tcp, cidr = var.vpc_cidr, from = local.ephemeral.from, to = local.ephemeral.to },
      { number = 170, protocol = local.tcp, cidr = var.admin_pool_cidr, from = local.ephemeral.from, to = local.ephemeral.to },
    ])
  }

  nacl_rules = merge(
    merge([
      for subnet, rules in local.nacl_inbound : {
        for rule in rules : "${subnet}-in-${rule.number}" => merge(rule, { subnet = subnet, egress = false })
      }
    ]...),
    merge([
      for subnet, rules in local.nacl_outbound : {
        for rule in rules : "${subnet}-out-${rule.number}" => merge(rule, { subnet = subnet, egress = true, action = "allow" })
      }
    ]...),
  )
}

resource "aws_network_acl" "this" {
  for_each = var.subnet_ids

  vpc_id     = var.vpc_id
  subnet_ids = [each.value]

  tags = { Name = "${var.name}-${each.key}" }
}

resource "aws_network_acl_rule" "this" {
  for_each = local.nacl_rules

  network_acl_id = aws_network_acl.this[each.value.subnet].id
  rule_number    = each.value.number
  egress         = each.value.egress
  protocol       = each.value.protocol
  rule_action    = each.value.action
  cidr_block     = each.value.cidr
  from_port      = each.value.from
  to_port        = each.value.to
}
