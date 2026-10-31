locals {
  # Every subnet except public sends its traffic through fw-ips.
  private_subnets = { for name, cidr in var.subnet_cidrs : name => cidr if name != "public" }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

# An empty default group means anything attached to it by accident gets no access.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-default-deny" }
}

# Records accepted and rejected traffic, including paths that never cross fw-ips.
resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "s3"
  log_destination          = var.flow_log_bucket_arn
  max_aggregation_interval = 60

  tags = { Name = var.name }
}

resource "aws_subnet" "this" {
  for_each = var.subnet_cidrs

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = { Name = "${var.name}-${each.key}" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = var.name }
}

# Standalone so routes can target fw-ips before the instance exists, and so
# replacing the instance leaves the routes untouched. Free while unattached.
resource "aws_network_interface" "fw" {
  subnet_id         = aws_subnet.this["public"].id
  private_ips       = [var.fw_private_ip]
  source_dest_check = false # fw-ips forwards packets not addressed to itself.

  tags = { Name = "${var.name}-fw-ips" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.this["public"].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-private" }
}

resource "aws_route" "private_internet" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_network_interface.fw.id
}

resource "aws_route" "private_vpn" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = var.vpn_cidr
  network_interface_id   = aws_network_interface.fw.id
}

resource "aws_route_table_association" "private" {
  for_each = local.private_subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.private.id
}
