# Provedor AWS simulado dos testes do contrato: nenhuma chamada à AWS.
# Três AZs, todas oferecendo os tipos padrão (t3.micro e t3.small).

mock_data "aws_availability_zones" {
  defaults = {
    names = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
}

mock_data "aws_ec2_instance_type_offerings" {
  defaults = {
    locations      = ["us-east-1a", "us-east-1a", "us-east-1b", "us-east-1b", "us-east-1c", "us-east-1c"]
    instance_types = ["t3.micro", "t3.small", "t3.micro", "t3.small", "t3.micro", "t3.small"]
  }
}
