# ALB público do ambiente (02, seção 5; 08, seção 3): listener HTTP 80 (sem
# HTTPS por ora, 01) e target group com todos os nós web na porta 80, que o
# frontend publica em modo ingress. Pelo routing mesh, qualquer nó web
# encaminha a conexão ao serviço, então registrar todos basta. A verificação
# do ALB é GET / esperando 200 (06, seção 6.1).

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = var.subnet_ids
  security_groups    = [var.security_group_id]

  tags = { Name = "${var.name_prefix}-alb" }
}

resource "aws_lb_target_group" "web" {
  name        = "${var.name_prefix}-web"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  # Atualizações do frontend em stop-first derrubam uma réplica por vez
  # (06, seção 6.1): 30 s bastam para drenar as conexões de um nó.
  deregistration_delay = 30

  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.name_prefix}-web" }
}

resource "aws_lb_target_group_attachment" "web" {
  for_each = var.web_instance_ids

  target_group_arn = aws_lb_target_group.web.arn
  target_id        = each.value
  port             = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}
