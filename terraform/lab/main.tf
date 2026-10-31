provider "aws" {
  region = "eu-central-1"
}

module "network" {
  source = "../modules/network"

  flow_log_bucket_arn = var.flow_log_bucket_arn
}

module "security" {
  source = "../modules/security"

  vpc_id        = module.network.vpc_id
  vpc_cidr      = module.network.vpc_cidr
  fw_eni_id     = module.network.fw_eni_id
  fw_private_ip = module.network.fw_private_ip
  subnet_ids    = module.network.subnet_ids
  subnet_cidrs  = module.network.subnet_cidrs
}
