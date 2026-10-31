variable "name" {
  description = "Prefix for security group names."
  type        = string
  default     = "mailbridge-lab"
}

variable "vpc_id" {
  description = "VPC ID from the network module."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC address range."
  type        = string
}

variable "fw_eni_id" {
  description = "fw-ips network interface that receives sg-fw."
  type        = string
}

variable "fw_private_ip" {
  description = "fw-ips address, where private hosts send DNS queries (Unbound)."
  type        = string
}

variable "vpn_source_cidr" {
  description = "Who may reach OpenVPN. Narrow to a home IP if it is static."
  type        = string
  default     = "0.0.0.0/0"
}

variable "vpn_pools_cidr" {
  description = "User and admin VPN pools together."
  type        = string
  default     = "10.8.0.0/22"
}

variable "admin_pool_cidr" {
  description = "Admin VPN pool."
  type        = string
  default     = "10.8.1.0/24"
}

variable "open_https_test_window" {
  description = "Opens TCP 443 on fw-ips to the internet. Outside-attack test windows only."
  type        = bool
  default     = false
}

variable "subnet_ids" {
  description = "Subnet name to subnet ID, from the network module."
  type        = map(string)
}

variable "subnet_cidrs" {
  description = "Subnet name to CIDR, from the network module."
  type        = map(string)
}
