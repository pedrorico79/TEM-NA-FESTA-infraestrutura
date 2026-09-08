# Data sources

data "aws_availability_zones" "available" {
  state = "available"
}

# Equivalente ao Parameter LatestUbuntuAmiId
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

data "aws_caller_identity" "current" {}
