resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-private-rt-1a"
  }
}

resource "aws_route" "private_a_nat" {
  route_table_id         = aws_route_table.private_a.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.a.id
}

resource "aws_route_table" "private_b" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-private-rt-1b"
  }
}

resource "aws_route" "private_b_nat" {
  route_table_id         = aws_route_table.private_b.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.b.id
}

# ASSOCIATIONS
resource "aws_route_table_association" "public_bastion" {
  subnet_id      = aws_subnet.public_bastion.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_alb" {
  subnet_id      = aws_subnet.public_alb.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_frontend_1a" {
  subnet_id      = aws_subnet.private_frontend_1a.id
  route_table_id = aws_route_table.private_a.id
}

resource "aws_route_table_association" "private_backend_1a" {
  subnet_id      = aws_subnet.private_backend_1a.id
  route_table_id = aws_route_table.private_a.id
}

resource "aws_route_table_association" "private_db_1a" {
  subnet_id      = aws_subnet.private_db_1a.id
  route_table_id = aws_route_table.private_a.id
}

resource "aws_route_table_association" "private_frontend_1b" {
  subnet_id      = aws_subnet.private_frontend_1b.id
  route_table_id = aws_route_table.private_b.id
}

resource "aws_route_table_association" "private_backend_1b" {
  subnet_id      = aws_subnet.private_backend_1b.id
  route_table_id = aws_route_table.private_b.id
}

resource "aws_route_table_association" "private_db_1b" {
  subnet_id      = aws_subnet.private_db_1b.id
  route_table_id = aws_route_table.private_b.id
}
