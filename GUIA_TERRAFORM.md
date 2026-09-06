# Guia rápido — executar e testar o Terraform

Os comandos abaixo consideram **Git Bash**, Terraform 1.5+ e AWS CLI instalados. Execute tudo na raiz deste repositório.

## 1. Preparar o AWS Learner Lab

1. Inicie uma sessão no Learner Lab.
2. No painel de credenciais, abra a opção que mostra `cat ~/.aws/credentials`.
3. Copie `aws_access_key_id`, `aws_secret_access_key` e `aws_session_token`.
4. Configure o AWS CLI:

```bash
aws configure
```

Preencha os campos com os valores mostrados pelo `cat ~/.aws/credentials` do laboratório:

```text
AWS Access Key ID: cole aws_access_key_id
AWS Secret Access Key: cole aws_secret_access_key
AWS Session Token: cole aws_session_token
Default region name: us-east-1
Default output format: json
```

Cole novamente as três credenciais temporárias sempre que iniciar uma nova sessão, mesmo que o terminal mostre valores antigos mascarados entre colchetes.

Teste as credenciais:

```bash
aws sts get-caller-identity
```

Resultado esperado: um JSON com a conta e um ARN contendo `assumed-role/voclabs`. As credenciais expiram junto com a sessão e nunca devem ser enviadas ao Git.

## 2. Preparar as variáveis locais

Antes do primeiro `apply`, é obrigatório criar a Key Pair usada pelas EC2:

1. No Console AWS, selecione a região **Norte da Virgínia (`us-east-1`)**.
2. Acesse **EC2 → Rede e segurança → Pares de chaves**.
3. Clique em **Criar par de chaves**.
4. Use o nome `tem-na-festa-key`, tipo `RSA` e formato `.pem`.
5. Guarde o arquivo baixado em local seguro e nunca o envie ao Git.

O Terraform associa essa chave ao bastion, aos dois frontends e aos dois backends. Ela permite acesso SSH para diagnóstico; as instâncias privadas são acessadas por meio do bastion. Mesmo que o SSH não seja usado durante o teste, o `apply` falhará se a Key Pair informada não existir nessa região.

Crie a configuração privada:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Descubra seu IP público:

```bash
curl -s https://checkip.amazonaws.com
```

Edite `terraform.tfvars` e preencha:

- `bastion_ssh_cidr` com o IP retornado seguido de `/32`;
- `key_pair_name` com a Key Pair existente;
- `db_master_password` com uma senha forte;
- `jwt_secret` com uma chave aleatória de pelo menos 32 caracteres.

Mantenha `enable_datalake = false` no AWS Student. O arquivo `terraform.tfvars` é privado e já está ignorado pelo Git.

## 3. Validar e planejar

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan -out=deploy.tfplan
```

Resultados esperados:

```text
Terraform has been successfully initialized!
Success! The configuration is valid.
Plan: 55 to add, 0 to change, 0 to destroy.
```

`terraform fmt -check` termina sem imprimir nada quando a formatação está correta. Se o plano apresentar erro, destruição inesperada ou uma quantidade diferente, não aplique antes de investigar.

## 4. Criar a infraestrutura

```bash
terraform apply "deploy.tfplan"
```

Resultado esperado ao final:

```text
Apply complete! Resources: 55 added, 0 changed, 0 destroyed.
```

O comando também mostra `website_url`, `internal_backend_url` e `bastion_public_ip`. Aguarde de 2 a 5 minutos após o `apply`: as EC2 ainda estarão clonando e compilando os projetos.

## 5. Testar a infraestrutura

### Frontends no Load Balancer público

```bash
FRONTEND_TG_ARN=$(aws elbv2 describe-target-groups --names tem-na-festa-frontend-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "$FRONTEND_TG_ARN" --query 'TargetHealthDescriptions[].{Instance:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' --output table
```

Resultado esperado: duas instâncias com `State` igual a `healthy`.

### Backends no Load Balancer interno

```bash
BACKEND_TG_ARN=$(aws elbv2 describe-target-groups --names tem-na-festa-backend-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "$BACKEND_TG_ARN" --query 'TargetHealthDescriptions[].{Instance:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' --output table
```

Resultado esperado: duas instâncias com `State` igual a `healthy`.

### Site e fluxo até o backend

```bash
terraform output -raw website_url
curl -I "$(terraform output -raw website_url)"
curl "$(terraform output -raw website_url)/api/v1/health"
```

Resultados esperados:

```text
HTTP/1.1 200 OK
Server: nginx
{"status":"UP"}
```

O último teste percorre:

```text
Internet -> ALB público -> Nginx -> ALB interno -> backend
```

Ele verifica o caminho de rede e a aplicação backend, mas não consulta o banco. Para testar também o RDS, abra a URL retornada por `terraform output -raw website_url` e faça login com um usuário de teste criado pelo SQL:

```text
E-mail: joao.atendimento@temnafesta.com
Senha: senha123
```

Login bem-sucedido confirma frontend, proxy, backend, autenticação e acesso ao RDS.

## 6. Destruir após o teste

Não deixe a infraestrutura consumindo os créditos do Learner Lab.

```bash
terraform plan -destroy -out=destroy.tfplan
```

Resultado esperado:

```text
Plan: 0 to add, 0 to change, 55 to destroy.
```

Confira o plano e remova os recursos:

```bash
terraform apply "destroy.tfplan"
terraform state list
```

Resultado esperado:

```text
Apply complete! Resources: 0 added, 0 changed, 55 destroyed.
```

`terraform state list` não deve retornar nenhuma linha.
