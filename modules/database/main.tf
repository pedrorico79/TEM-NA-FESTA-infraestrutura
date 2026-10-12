# Banco do ambiente (02, seção 6; 05, B1 e B2): RDS MySQL nas subnets de
# banco, acessível só pelo swarm-app, com snapshot final obrigatório
# <prefixo>-final-<id do ciclo> e restauração por db_snapshot_identifier só na
# criação (ignore_changes; 03, seção 3.5).

# Id do ciclo: 8 caracteres hexadecimais, gerados uma vez com o RDS e
# perdidos com o ambiente (03, seção 5; 05, B2).
resource "random_id" "cycle" {
  byte_length = 4
}

resource "aws_db_subnet_group" "this" {
  name        = "${var.name_prefix}-db"
  description = "Subnets de banco do ambiente ${var.name_prefix}"
  subnet_ids  = var.subnet_ids

  tags = { Name = "${var.name_prefix}-db" }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name_prefix}-db"
  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage_gb
  storage_type      = "gp2"
  storage_encrypted = true

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false

  # db_name é ignorado ao restaurar de snapshot (o schema vem nele).
  db_name             = var.snapshot_identifier == null ? var.db_name : null
  username            = var.master_username
  password            = var.master_password
  snapshot_identifier = var.snapshot_identifier

  backup_retention_period  = 1
  delete_automated_backups = true
  copy_tags_to_snapshot    = true
  apply_immediately        = true
  deletion_protection      = false

  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name_prefix}-final-${random_id.cycle.hex}"

  tags = { Name = "${var.name_prefix}-db" }

  lifecycle {
    # O snapshot de origem só vale na criação: mudar a variável depois nunca
    # recria o banco em uso (05, B2; conferido por Q21).
    ignore_changes = [snapshot_identifier, db_name]
  }
}
