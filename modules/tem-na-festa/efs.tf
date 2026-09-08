# EFS

resource "aws_efs_file_system" "this" {
  performance_mode = "generalPurpose"
  encrypted        = true

  tags = {
    Name = "${var.project_name}-efs"
  }
}

resource "aws_efs_mount_target" "az_a" {
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = aws_subnet.private_frontend_1a.id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_mount_target" "az_b" {
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = aws_subnet.private_frontend_1b.id
  security_groups = [aws_security_group.efs.id]
}
