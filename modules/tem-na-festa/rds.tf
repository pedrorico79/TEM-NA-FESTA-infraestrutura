# RDS MySQL

resource "aws_db_subnet_group" "this" {
  name        = "${var.project_name}-rds-subnet-group"
  description = "Subnet group para RDS ${var.project_name}"
  subnet_ids = [
    aws_subnet.private_db_1a.id,
    aws_subnet.private_db_1b.id,
  ]

  tags = {
    Name = "${var.project_name}-rds-subnet-group"
  }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.project_name}-mysql"
  instance_class = var.db_instance_class
  engine         = "mysql"
  engine_version = "8.0.46"

  username = var.db_master_username
  password = var.db_master_password
  db_name  = var.db_name

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.this.name

  multi_az = true

  publicly_accessible     = false
  backup_retention_period = 7
  deletion_protection     = false
  skip_final_snapshot     = true

  tags = {
    Name = "${var.project_name}-mysql"
  }
}
