output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC address range."
  value       = aws_vpc.this.cidr_block
}

output "subnet_ids" {
  description = "Subnet name to subnet ID."
  value       = { for name, subnet in aws_subnet.this : name => subnet.id }
}

output "fw_eni_id" {
  description = "fw-ips network interface ID."
  value       = aws_network_interface.fw.id
}

output "fw_private_ip" {
  description = "fw-ips private address."
  value       = var.fw_private_ip
}
