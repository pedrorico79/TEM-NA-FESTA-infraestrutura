# Security Groups for Data Storage
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-sg-rds"
  description = "RDS MySQL"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "MySQL a partir do Backend"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    # O SG do backend será definido no módulo de compute, então usaremos a 
    # referência ao SG do compute através de variáveis ou permitiremos a 
    # entrada do range da subnet de backend para evitar dependência circular.
    cidr_blocks = [cidrsubnet(var.vpc_cidr, 4, 4)] # Subnet private_backend_1a
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-rds"
  }
}

resource "aws_security_group" "efs" {
  name        = "${var.project_name}-sg-efs"
  description = "EFS NFS"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "NFS a partir do Frontend"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    cidr_blocks = [cidrsubnet(var.vpc_cidr, 4, 2)] # Subnet private_frontend_1a
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-efs"
  }
}
