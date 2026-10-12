# Rede do ambiente (02, seção 3; 03, seção 5): VPC, subnets, internet gateway,
# NAT e rotas. As subnets públicas e de banco existem sempre nas duas AZs; as
# web e app só nas az_count primeiras. Os nós do Swarm não têm IP público e
# saem pela NAT da própria AZ (per_az) ou pela da AZ1 (single).

locals {
  # cidrsubnet(vpc_cidr, 3, n): pública AZ1 = 0, web AZ1 = 1, web AZ2 = 2,
  # app AZ1 = 3, app AZ2 = 4, db AZ1 = 5, db AZ2 = 6, pública AZ2 = 7.
  netnums = {
    public = [0, 7]
    web    = [1, 2]
    app    = [3, 4]
    db     = [5, 6]
  }

  all_azs    = [0, 1]
  active_azs = range(var.az_count)

  # Subnets por chave estável "<camada>-az<n>".
  subnets = merge(
    { for i in local.all_azs : "public-az${i + 1}" => { tier = "public", az = i, public = true } },
    { for i in local.active_azs : "web-az${i + 1}" => { tier = "web", az = i, public = false } },
    { for i in local.active_azs : "app-az${i + 1}" => { tier = "app", az = i, public = false } },
    { for i in local.all_azs : "db-az${i + 1}" => { tier = "db", az = i, public = false } },
  )

  # NAT: só na AZ1 (single) ou uma por AZ ativa (per_az). Cada uma usa um Elastic IP.
  nat_azs = var.nat_mode == "per_az" ? local.active_azs : [0]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-igw" }
}

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id                  = aws_vpc.this.id
  availability_zone       = var.az_names[each.value.az]
  cidr_block              = cidrsubnet(var.vpc_cidr, 3, local.netnums[each.value.tier][each.value.az])
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-${each.key}"
    Tier = each.value.tier
  }
}

# --- NAT -------------------------------------------------------------------------

resource "aws_eip" "nat" {
  for_each = toset([for i in local.nat_azs : "az${i + 1}"])

  domain = "vpc"

  tags = { Name = "${var.name_prefix}-nat-${each.key}" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each = aws_eip.nat

  allocation_id = each.value.id
  subnet_id     = aws_subnet.this["public-${each.key}"].id

  tags = { Name = "${var.name_prefix}-nat-${each.key}" }

  depends_on = [aws_internet_gateway.this]
}

# --- Rotas -------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-rt-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

# Uma tabela privada por AZ ativa, com saída pela NAT da mesma AZ (per_az) ou
# pela da AZ1 (single).
resource "aws_route_table" "private" {
  for_each = toset([for i in local.active_azs : "az${i + 1}"])

  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-rt-private-${each.key}" }
}

resource "aws_route" "private_nat" {
  for_each = aws_route_table.private

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.nat_mode == "per_az" ? aws_nat_gateway.this[each.key].id : aws_nat_gateway.this["az1"].id
}

# Subnets de banco: sem rota para a internet (o RDS não precisa de saída).
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-rt-db" }
}

resource "aws_route_table_association" "this" {
  for_each = local.subnets

  subnet_id = aws_subnet.this[each.key].id
  route_table_id = (
    each.value.tier == "public" ? aws_route_table.public.id :
    each.value.tier == "db" ? aws_route_table.db.id :
    aws_route_table.private["az${each.value.az + 1}"].id
  )
}
