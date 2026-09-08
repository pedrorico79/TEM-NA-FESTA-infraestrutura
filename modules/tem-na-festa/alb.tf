# Load balancers and target groups

resource "aws_lb_target_group" "frontend" {
  name        = "${var.project_name}-frontend-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "instance"

  health_check {
    path     = "/"
    protocol = "HTTP"
    interval = 30
  }

  tags = {
    Name = "${var.project_name}-frontend-tg"
  }
}

resource "aws_lb_target_group_attachment" "frontend_1" {
  target_group_arn = aws_lb_target_group.frontend.arn
  target_id        = aws_instance.frontend_1.id
  port             = 80
}

resource "aws_lb_target_group_attachment" "frontend_2" {
  target_group_arn = aws_lb_target_group.frontend.arn
  target_id        = aws_instance.frontend_2.id
  port             = 80
}

resource "aws_lb" "public" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  subnets = [
    aws_subnet.public_bastion.id,
    aws_subnet.public_alb.id,
  ]
  security_groups = [aws_security_group.alb.id]

  tags = {
    Name = "${var.project_name}-alb"
  }
}

resource "aws_lb_listener" "public_http" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

resource "aws_lb_target_group" "backend" {
  name        = "${var.project_name}-backend-tg"
  port        = var.backend_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "instance"

  health_check {
    path     = "/api/v1/health"
    protocol = "HTTP"
    interval = 30
  }

  tags = {
    Name = "${var.project_name}-backend-tg"
  }
}

resource "aws_lb_target_group_attachment" "backend_1" {
  target_group_arn = aws_lb_target_group.backend.arn
  target_id        = aws_instance.backend_1.id
  port             = var.backend_port
}

resource "aws_lb_target_group_attachment" "backend_2" {
  target_group_arn = aws_lb_target_group.backend.arn
  target_id        = aws_instance.backend_2.id
  port             = var.backend_port
}

resource "aws_lb" "internal" {
  name               = "${var.project_name}-internal-alb"
  internal           = true
  load_balancer_type = "application"
  subnets = [
    aws_subnet.private_backend_1a.id,
    aws_subnet.private_backend_1b.id,
  ]
  security_groups = [aws_security_group.internal_alb.id]

  tags = {
    Name = "${var.project_name}-internal-alb"
  }
}

resource "aws_lb_listener" "internal_http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}
