variable "name" {
  description = "Prefix for resource Name tags."
  type        = string
  default     = "mailbridge-lab"
}

variable "vpc_cidr" {
  description = "VPC address range (ARCHITECTURE.md §1)."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zone" {
  description = "Single AZ for all subnets; multi-AZ is skipped for cost."
  type        = string
  default     = "eu-central-1a"
}

variable "subnet_cidrs" {
  description = "Subnet name to CIDR (ARCHITECTURE.md §2). Must include the key public."
  type        = map(string)
  default = {
    public = "10.0.1.0/24"
    dmz    = "10.0.2.0/24"
    app    = "10.0.3.0/24"
    data   = "10.0.4.0/24"
    mgmt   = "10.0.5.0/24"
  }
}

variable "fw_private_ip" {
  description = "Fixed private address of fw-ips in the public subnet."
  type        = string
  default     = "10.0.1.10"
}

variable "vpn_cidr" {
  description = "VPN pools, routed to fw-ips rather than NATed so hosts see real client IPs."
  type        = string
  default     = "10.8.0.0/16"
}

variable "flow_log_bucket_arn" {
  description = "S3 bucket for VPC flow logs. Lives in persistent so evidence survives lab teardown."
  type        = string
}
