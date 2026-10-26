# `modules/alb/`

ALB público nas subnets públicas das duas AZs, listener HTTP 80 e target group com todos os nós web na porta 80 (verificação `GET /` esperando 200). Saída: o nome DNS, que o `infra up` imprime e confere ao fim da subida. Referência: 02, seção 5; 06, seção 6.1; 08, seção 3.
