# Provedor AWS simulado dos testes do contrato: nenhuma chamada à AWS.
# Três AZs, todas oferecendo os tipos padrão (t3.micro e t3.small) e o
# t3.medium do nó app do dev (E8).

mock_data "aws_availability_zones" {
  defaults = {
    names = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
}

mock_data "aws_ec2_instance_type_offerings" {
  defaults = {
    locations      = ["us-east-1a", "us-east-1a", "us-east-1a", "us-east-1b", "us-east-1b", "us-east-1b", "us-east-1c", "us-east-1c", "us-east-1c"]
    instance_types = ["t3.micro", "t3.small", "t3.medium", "t3.micro", "t3.small", "t3.medium", "t3.micro", "t3.small", "t3.medium"]
  }
}

# Valores válidos para os data sources dos módulos do ambiente.
mock_data "aws_iam_policy_document" {
  defaults = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}

mock_data "aws_caller_identity" {
  defaults = {
    account_id = "000000000000"
  }
}

mock_data "aws_ami" {
  defaults = {
    id = "ami-00000000000000000"
  }
}

mock_data "aws_iam_instance_profile" {
  defaults = {
    name = "LabInstanceProfile"
  }
}
