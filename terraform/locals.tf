resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  suffix = random_id.suffix.hex
  env    = terraform.workspace != "" ? terraform.workspace : "dev"
  name   = "${var.project}-${local.env}-${local.suffix}"

  tags = {
    Project     = var.project
    Environment = local.env
  }
}


#(optional) terraform/provider.auto.tfvars