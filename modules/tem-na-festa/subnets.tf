# Subnets

resource "aws_subnet" "public_bastion" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.0.0/27"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-bastion-1a"
  }
}

resource "aws_subnet" "public_alb" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.0.32/27"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-alb-1b"
  }
}

resource "aws_subnet" "private_frontend_1a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.0.64/28"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "${var.project_name}-private-frontend-1a"
  }
}

resource "aws_subnet" "private_frontend_1b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.0.80/28"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "${var.project_name}-private-frontend-1b"
  }
}

resource "aws_subnet" "private_backend_1a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.0.96/28"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "${var.project_name}-private-backend-1a"
  }
}

resource "aws_subnet" "private_backend_1b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.0.112/28"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "${var.project_name}-private-backend-1b"
  }
}

resource "aws_subnet" "private_db_1a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.0.128/28"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "${var.project_name}-private-db-1a"
  }
}

resource "aws_subnet" "private_db_1b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.0.144/28"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "${var.project_name}-private-db-1b"
  }
}
