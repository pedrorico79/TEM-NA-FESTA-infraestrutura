# 01 – Visão e requisitos

Estado: **confirmado** (08/10/2026); consolidado em 09/10/2026 com as decisões dos specs 02 a 09; ajustado em 10/10/2026 (RF-03 e RES-06, auditoria; RF-02 e critério 2, pareamento do WhatsApp como exceção ao nível 4, auditoria item 19)

## 1. Contexto
O Tem Na Festa é um sistema interno de gestão de pedidos de uma confeitaria, em fase final de desenvolvimento e ainda sem uso real. Faz parte de um projeto de extensão da faculdade de Ciência da Computação.

Componentes da aplicação:
- **Frontend** (React, servido por nginx): telas Inicial, Pedidos (Produtos, Eventos, Clientes), Relatórios e Usuários (apenas admin).
- **API backend** (Java + Spring Boot, arquitetura CLEAN).
- **Banco de dados** MySQL, com estrutura de dados já definida.
- **Microsserviço de mensageria**: envia WhatsApp aos clientes em momentos do pedido (criação, confirmação etc.). Recebe eventos do backend e usa o RabbitMQ internamente.

## 2. Objetivo
Recriar do zero a infraestrutura em nuvem (AWS) com Terraform, de forma **robusta e fácil de manter**, com foco em recriação e estabilização, e definir os fluxos de CI/CD.

A infra atual foi montada com foco em aprendizado e é difícil de manter, corrigir, estender e automatizar; a configuração do Swarm não ficou boa.

## 3. Escopo
**Dentro do escopo**
- Infraestrutura AWS completa por Terraform, conforme o diagrama de referência (rede em 2 AZs, ALB, EC2 com Docker Swarm, RDS, S3).
- Subida totalmente automática do ambiente (ver RF-02).
- Fluxo de envio de logs com Fluent Bit para o bucket bronze do S3.
- CI/CD: build e publicação das imagens no Docker Hub e deploy manual por workflow.
- Dois ambientes independentes: dev e prod.

**Fora do escopo (por enquanto)**
- Refatoração da API e versões de Java/Spring/React; novas funcionalidades (inclui a integração de eventos entre backend e microsserviço, que ainda não existe no backend; a infra apenas fixa o contrato, ver 06).
- Autoscaling automático.
- EFS (armazenamento compartilhado).
- HTTPS e domínio próprio (acesso por HTTP pelo DNS do ALB).
- Observabilidade (CloudWatch, SNS, e-mail do NOC): importante, será especificada depois que a infra estiver pronta.
- Datalake além do bucket bronze com os logs: Lambda, Glue, Athena e camadas silver/gold ficam para depois.
- Execução do Terraform por GitHub Actions (por ora o Terraform roda na máquina local, dentro do WSL no Windows).

## 4. Restrições do ambiente
- **RES-01** Ambiente: AWS Academy Learner Lab, com crédito de US$ 50.
- **RES-02** A sessão do laboratório dura 4 horas; as credenciais mudam a cada sessão. Os recursos não são apagados ao fim da sessão.
- **RES-03** Só existe a `LabRole` (com o `LabInstanceProfile`): não é possível criar roles ou políticas IAM próprias (inclui OIDC do GitHub).
- **RES-04** Custo não é preocupação do projeto, mas o crédito limita o tempo em que o ambiente fica de pé.
- **RES-05** Serviços e limites do laboratório (detalhe e resultados dos testes em 02, seção 10): valem para cada região (apenas `us-east-1` e `us-west-2`) o máximo de **9 instâncias EC2 simultâneas** e **32 vCPUs**; tipos EC2 de `nano` a `large`; RDS com classes `nano` a `medium`. O console oferece Multi-AZ e criptografia do RDS, a confirmar na primeira criação real; SSM Parameter Store, Secrets Manager e Athena funcionam; o limite de Elastic IPs e se o RDS conta nas 9 instâncias serão descobertos na implementação (09, E3 e E4).
- **RES-06** *Premissa de uso (decidida em 10/10/2026).* No laboratório, quem usa **não deve** subir dev e prod ao mesmo tempo se a soma de instâncias passar do limite da região (RES-05). A infra **não confere nem bloqueia** essa soma: se o limite for atingido, a AWS recusa a criação e o `apply` falha. Assim o provisionamento continua utilizável em contas fora do laboratório, sem esse limite. O limite **por ambiente** continua sendo uma variável (`ec2_instance_limit`, 03).

## 5. Requisitos funcionais da infra
- **RF-01 Recriação repetível.** Todo o ambiente deve poder ser destruído e recriado repetidamente a partir do código, sem passos manuais.
- **RF-02 Automação total (nível 4).** Após o `apply`, o ambiente fica completo e funcionando: instâncias preparadas (com Docker e Fluent Bit instalados), Swarm formado, stacks da aplicação e do RabbitMQ no ar e dados do banco restaurados, sem acesso manual. O bastion com SSH permanece disponível para depuração. **Exceção declarada (*Decidido* em 10/10/2026, auditoria item 19):** se o microsserviço de WhatsApp usar uma sessão que exige pareamento (QR code ou código de pareamento no celular), esse pareamento é um passo manual, feito uma vez por ambiente novo, depois de o serviço estar de pé; o procedimento está em 06, seção 6.4.1. O nível 4 vale até o serviço estar no ar, e o resto do ambiente (inclusive o sistema respondendo por HTTP) não depende desse passo. Com a API oficial do WhatsApp (token), a exceção não existe.
- **RF-03 Ambientes independentes.** Dev e prod podem subir juntos ou separados, sem interferir um no outro. O provisionamento **não impede** subir os dois ao mesmo tempo, mesmo que a soma passe do limite de instâncias do laboratório (RES-06).
- **RF-04 Topologia parametrizável.** Número de AZs, de instâncias por camada, de réplicas por serviço e tipos de instância são definidos por variáveis, com valores padrão por ambiente. Subir um ambiente deve ser um único comando.
- **RF-05 HA do banco opcional.** O Multi-AZ do RDS é ligado ou desligado por variável (padrão desligado). Se o laboratório não permitir, permanece desligado.
- **RF-06 Persistência entre ciclos.** Os buckets S3 não são removidos pelo destroy. Os dados do banco são preservados por snapshots nativos do RDS e restaurados na subida seguinte.
- **RF-07 Segredos.** Somente o que vem de fora (token do WhatsApp e demais segredos do microsserviço) é fornecido manualmente à infra; todos os demais segredos são gerados automaticamente. (As credenciais de publicação no Docker Hub existem só nos repositórios de aplicação do GitHub; os nós não precisam de credenciais porque as imagens são públicas.)
- **RF-08 Logs.** Os logs dos containers, do sistema operacional (`auth.log`) e do systemd são enviados pelo Fluent Bit, instalado em cada instância, ao bucket bronze.
- **RF-09 Imagens.** As imagens vivem no Docker Hub (repositórios públicos), com tags separadas por ambiente e por stack.
- **RF-10 Deploy manual.** Uma nova versão de uma stack entra em um ambiente por workflow manual no GitHub Actions, no qual se escolhe o ambiente e a branch a construir, sem recriar a infra. Com a infra fora do ar, o workflow apenas publica a imagem.
- **RF-11 Acesso.** O sistema é acessado por HTTP pelo DNS do ALB.
- **RF-12 Saída para a internet.** Todos os nós do Swarm (web e app) alcançam a internet pela NAT, sem IP público (necessário para o envio de WhatsApp e para baixar imagens).

## 6. Requisitos não funcionais
- **RNF-01 Manutenibilidade.** Código organizado em módulos, com um único repositório de infra (Terraform, scripts e compose files).
- **RNF-02 Previsibilidade.** Subidas repetidas produzem o mesmo resultado; variáveis têm padrões sensatos.
- **RNF-03 Segurança básica.** Segredos fora do repositório e fora de imagens; nenhum nó do Swarm com IP público; apenas o ALB e o bastion expostos; acesso administrativo apenas pelo bastion.
- **RNF-04 Rastreabilidade.** Cada requisito aqui deve ser rastreável até a especificação que o detalha e até o teste que o valida (08, `tests/TRACEABILITY.md`).

## 7. Critérios de aceite da infra (confirmados)
1. Um único comando local sobe um ambiente completo e, sem intervenção, o sistema responde por HTTP no DNS do ALB. *(O pareamento do WhatsApp, quando existe, é a exceção de RF-02 e não entra neste critério.)*
2. Um pedido criado pela interface dispara a mensagem de WhatsApp pelo microsserviço. *(Depende da integração backend → microsserviço, tarefa fora da infra: a infra entrega a rede, as variáveis e os segredos; ver 06, seção 6.5. Se o microsserviço usa sessão, depende também de o WhatsApp do ambiente já ter sido pareado, 06, seção 6.4.1.)*
3. Os logs dos containers aparecem no bucket bronze.
4. Destruir e recriar o ambiente preserva os buckets e restaura os dados do banco.
5. Dev e prod sobem de forma independente, com topologias diferentes definidas só por variáveis.
6. Uma versão nova de uma stack, publicada pelo workflow de deploy com `env=dev`, entra no dev sem afetar o prod.
7. Nenhum segredo gerado aparece em arquivos do repositório nem em logs.

## 8. Rastreabilidade
- Documentos que detalham os requisitos: 02 (arquitetura), 03 (variáveis), 04 (subida), 05 (segredos e dados), 06 (stacks), 07 (CI/CD), 08 (repositório e convenções), 09 (plano e validação).
- O índice (`00-indice.md`) lista o estado de cada documento e as pendências abertas.
