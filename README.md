# TEM-NA-FESTA Infraestrutura 

Este repositório contém a infraestrutura como código (IaC) para o ecossistema "Tem na Festa". A arquitetura foi migrada de instâncias isoladas para um cluster **Docker Swarm**, garantindo alta disponibilidade, auto-cura e deploy automatizado.

---

## 🚀 Visão Geral da Arquitetura

A infraestrutura é provisionada via Terraform e segue a seguinte topologia:

- **VPC & Rede:** Sub-redes públicas (Bastion, ALB) e privadas (Frontend, Backend).
- **Compute (Docker Swarm):** 
  - **Manager Node:** Uma instância na sub-rede de frontend que gerencia o cluster e publica o token de join no AWS SSM.
  - **Worker Nodes:** Instâncias de frontend e backend que fazem o join automático no cluster via SSM.
- **Orquestração:** Serviços distribuídos via `docker-compose.yml` com constraints de labels (`camada=frontend` e `camada=backend`).
- **Banco de Dados:** AWS RDS MySQL em sub-rede privada.
- **Armazenamento:** AWS EFS montado nos nós de frontend para arquivos estáticos compartilhados.
- **Entrada de Tráfego:** AWS Application Load Balancer (ALB) Público $\rightarrow$ Swarm Routing Mesh $\rightarrow$ Containers.

---

## 🛠️ Guia de Implementação (Passo a Passo)

Siga rigorosamente a ordem abaixo para subir o sistema do zero:

### 1. Pré-requisitos
- Conta AWS (Learner Lab ou Standard).
- Terraform instalado.
- Par de chaves SSH (`tem-na-festa-key.pem`) criado no console AWS (us-east-1).

### 2. Provisionamento da Infraestrutura (Terraform)
Navegue até a pasta do ambiente desejado (ex: `dev`) e execute:

```bash
cd environments/dev
terraform init
terraform apply
```

**O que acontece aqui?** O Terraform cria a rede, o RDS, o EFS, as instâncias EC2 e os repositórios ECR. O `user_data` das instâncias instala o Docker, configura as labels e monta o cluster Swarm automaticamente.

### 3. Configuração do CI/CD (GitHub Secrets)
Para que as aplicações subam automaticamente, você deve configurar as seguintes **Secrets** em cada um dos três repositórios (`backend`, `frontend`, `microservice`):

- `AWS_ACCESS_KEY_ID`: Sua chave de acesso AWS.
- `AWS_SECRET_ACCESS_KEY`: Sua chave secreta AWS.
- `AWS_SESSION_TOKEN`: Seu token de sessão (obrigatório para contas de estudante).

### 4. Deploy das Aplicações
Agora, basta fazer o push do código para a branch `main` de cada repositório. O fluxo será:
`Push` $\rightarrow$ `Build Docker` $\rightarrow$ `Push ECR` $\rightarrow$ `Update Swarm Service`.

**Ordem recomendada de push:**
1. Backend $\rightarrow$ 2. Microserviço Notificações $\rightarrow$ 3. Frontend.

### 5. Acesso ao Sistema
Após o deploy, execute:
```bash
terraform output website_url
```
Acesse a URL retornada no navegador.

---

## ⚙️ Como funciona o Fluxo Interno (Detalhes Técnicos)

### O "Pulo do Gato" do Auto-Join
Para evitar a configuração manual do cluster, implementamos:
1. O **Manager** executa `docker swarm init` e salva o token no **AWS SSM Parameter Store**.
2. Os **Workers** rodam um script em loop que tenta ler esse token do SSM. Assim que o token aparece, eles executam o `docker swarm join`.

### Comunicação Frontend $\rightarrow$ Backend
Não utilizamos ALB Interno. O tráfego flui via **Overlay Network**:
- O Nginx no Frontend está configurado para redirecionar `/api/` para `http://backend-som:8080`.
- O Swarm resolve `backend-som` para o IP de qualquer container do backend saudável, balanceando a carga internamente.

### Persistência de Dados
O **AWS EFS** é montado em `/var/www/html` em todos os nós de frontend. Isso garante que, se o Swarm mover o container do frontend da máquina A para a máquina B, os arquivos estáticos e uploads continuem disponíveis.

---

## 📋 Resumo de Comandos Úteis

| Ação | Comando |
| :--- | :--- |
| Iniciar Infra | `terraform apply` |
| Ver URL Site | `terraform output website_url` |
| Ver IP Bastion | `terraform output bastion_public_ip` |
| Destruir Tudo | `terraform destroy` |
