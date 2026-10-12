# 08 – Estrutura do repositório de infra e convenções

Estado: **aprovado** (09/10/2026); ajustado em 10/10/2026 (regra de `lifecycle` para a AMI, auditoria item 2; `stacks/app-messaging.yml`, `init-secrets` e T1 a T17, auditoria item 3; `node/tnf-db-shell.sh` e `infra ssh` para o banco, auditoria item 5; ponto de partida com conteúdo antigo, importação do bucket bronze existente e aviso de sobras na conta, auditoria item 7; credenciais vencidas, `errored.tfstate`, lock órfão e `infra session`, seção 5.3, auditoria item 10; recusa de mudança de `manager_count` com o ambiente no ar, seção 5.4, G22 e H13, auditoria item 11; `infra snapshots`, `infra up --snapshot`, nomes dos snapshots, G23 e H14, auditoria item 12; CI verde nos PRs como regra de conduta, seções 7 e 11, auditoria item 15; metadados das instâncias, IMDSv2 obrigatório e limite de saltos 1, seções 3, 4.1 e 4.3 e H16, auditoria item 17; `infra access`, chave SSH recuperável e IP autorizado detectado a cada operação, seções 2, 3, 5, 5.1 e 5.6, G24, G25 e H17, auditoria item 18; rastreabilidade conferida automaticamente por `scripts/check-traceability.sh` e `make trace`, seções 2, 7 e 8, G10, G15 como conferência manual e H18, auditoria item 20; seção 7, G10 e H19: valores da situação, IDs lidos só nas listas "Pronto quando" de 09 e `DB_SCHEMA_*` no módulo `environment`, varredura final de 11/10/2026; em 12/10/2026, na E2: buckets do `bootstrap` criados pelo AWS CLI, por causa da SCP do laboratório, seções 3 e 5, G6, G16, H4, H11 e H20; G7 com ambiente desconhecido e credenciais, e pré-checagens testadas pelo `scripts/preflight.sh`, H21; na E3, raiz temporária `tests/live/e3-network/` na seção 2 e H22). O `infra` é em bash e roda no **WSL** em máquinas Windows (seção 5.1).
Repositório: `TEM-NA-FESTA-infraestrutura`.
Depende de: 02 (duas camadas), 03 (variáveis), 04 (fluxo de subida e scripts dos nós), 05 (segredos), 06 (stacks), 07 (CI).

## 1. Objetivo
Dizer **onde fica cada coisa** e **como se escreve**, para que a implementação (09) seja mecânica e o repositório continue fácil de manter e de destruir e recriar (objetivo do projeto). Também define o `infra`, o comando que o usuário realmente usa no dia a dia.

## 2. Estrutura de pastas
```
TEM-NA-FESTA-infraestrutura/
├── README.md                    # como começar (3 comandos), links para specs/
├── infra                        # comando principal (bash), seção 5
├── Makefile                     # atalhos: make fmt | lint | test | trace | check (os mesmos do CI)
├── secrets.env.example          # modelo dos segredos manuais, sem valores
├── .gitignore
├── .gitattributes               # força finais de linha LF nos scripts (seção 5.1)
├── bootstrap/                   # camada 1: bucket do state e bucket bronze (02, seção 2)
│   ├── main.tf  variables.tf  outputs.tf  versions.tf
│   └── terraform.tfvars
├── envs/
│   ├── dev/
│   │   ├── main.tf              # só chama modules/environment (alguns blocos)
│   │   ├── versions.tf  backend.tf
│   │   └── terraform.tfvars     # valores do ambiente, sem segredos
│   └── prod/                    # mesma forma que dev
├── modules/
│   ├── environment/             # composição: liga todos os módulos abaixo
│   ├── network/                 # VPC, subnets, IGW, NAT, rotas
│   ├── security/                # security groups
│   ├── compute/                 # chave SSH, nós Swarm (for_each), bastion
│   ├── alb/                     # ALB, listener, target group
│   ├── database/                # RDS, subnet group, id do ciclo, snapshot final
│   ├── secrets/                 # senhas geradas + parâmetros SSM
│   └── artifacts/               # bucket de artefatos e os objetos enviados a ele
├── node/                        # tudo o que roda DENTRO das EC2 (enviado ao S3, 04)
│   ├── node-bootstrap.sh        # papéis web, app e bastion (04, seção 5)
│   ├── converge.sh              # convergência (nós esperados, rótulos, rede, segredos, banco, digests, stacks)
│   ├── db-init.sh               # rotina do banco (05, A4 e B5)
│   ├── tnf-db-shell.sh          # acesso manual ao banco, instalado só nos nós app (05, A7)
│   ├── fluent-bit/              # fluent-bit.conf.tftpl (com a lista de unidades do systemd, 02 seção 7.1), parsers.conf
│   └── systemd/                 # units e timers (tnf-converge, Fluent Bit)
├── stacks/                      # compose files (06)
│   ├── rabbitmq.yml  app.yml  app-messaging.yml  web.yml
│   └── rabbitmq/                # rabbitmq.conf, definitions.json
├── scripts/                     # apoio do `infra`, executam na máquina do usuário
│   ├── lib/common.sh            # log, erros, helpers da AWS
│   ├── preflight.sh             # pré-checagens, inclusive sessão, errored.tfstate, lock (5.3) e manager_count (5.4)
│   ├── snapshots.sh             # listar, escolher (final mais recente ou `--snapshot`), criar o manual e podar (05, B2)
│   ├── access.sh                # chave SSH recuperada do state e IP autorizado no bastion (5.6)
│   ├── check-traceability.sh    # confere specs × tests/TRACEABILITY.md × etapas de 09 (seção 7)
│   └── wait-ready.sh            # acompanhar status e testar o ALB (04, seção 8)
├── tests/
│   ├── contract/                # *.tftest.hcl: casos T1 a T17 (03, 06)
│   ├── shell/                   # testes dos scripts (bats)
│   ├── live/e3-network/         # raiz TEMPORÁRIA da E3 (só rede e security groups); apagada na E4a (H22)
│   └── TRACEABILITY.md          # cada ID de teste dos specs → etapa de 09 e onde é verificado (seção 7)
├── templates/
│   └── deploy.yml               # modelo do workflow dos repositórios de aplicação (07)
├── docs/
│   └── primeiros-passos-windows.md   # instalar o WSL e as ferramentas (seção 5.1)
├── .github/workflows/
│   └── ci-infra.yml             # 07, seção 6 (único workflow do repositório)
└── specs/                       # estes documentos (00 a 09)
```
- **Esta é a árvore completa do repositório depois da E0** (seção 5.2): não sobra nenhum arquivo do conteúdo antigo fora dela.
- **Por que `modules/environment`:** `envs/dev` e `envs/prod` têm quase só valores (`terraform.tfvars`) e a chamada ao mesmo módulo de composição. Assim a lógica existe **uma vez**, dev e prod nunca divergem por acidente, e a diferença entre ambientes é visível em um único arquivo.
- **Por que `node/` separado de `modules/`:** são scripts que rodam nas instâncias, testados à parte (`shellcheck`, `bats`). O módulo `artifacts` só os envia ao S3.
- **Por que `stacks/` na raiz:** os compose files são do Swarm, não do Terraform; o módulo `artifacts` os envia sem alterá-los (06, seção 4).
- **Por que `app-messaging.yml` separado de `app.yml`:** o compose é estático e igual em dev e prod; para a mensageria poder ficar desligada até a E8, o serviço dela vive em um arquivo à parte que o líder só inclui quando `REPLICAS_MESSAGING > 0` (06, seção 2).
- **Por que `templates/deploy.yml`:** é o modelo de workflow que você copia para cada repositório de aplicação (07, seção 4), mantido junto da infra para ter uma só fonte. Inclui a trava de prod (07, 4.5) e a conferência dos `VITE_*` (07, 4.4).

## 3. Módulos: responsabilidades e interfaces
| Módulo | Responsabilidade | Entradas principais | Saídas principais |
|---|---|---|---|
| `environment` | Liga os demais; recebe **todas** as variáveis de 03; valida o contrato; resolve AMI, AZs e IPs dos nós; calcula `EXPECTED_NODES`, `MANAGER_COUNT` e `DB_SCHEMA_*` para o `stack.env` (03, seção 5) | variáveis de 03 | endereço do ALB, IP do bastion, endpoint do RDS, nome do bucket de artefatos, chave SSH privada e pública (a privada é saída **sensível**, usada só pelo `infra access`, 5.6) |
| `network` | VPC, subnets pelas regras de 02 (derivadas por `cidrsubnet`), IGW, NAT (`single` ou `per_az`), rotas | `vpc_cidr`, `az_names`, `az_count`, `nat_mode` | IDs de VPC e de subnets por camada e AZ |
| `security` | security groups `alb`, `swarm-web`, `swarm-app`, `rds`, `bastion` com as regras de 02 e 06 (incluindo overlay entre web e app; o `rds` aceita 3306 só do `swarm-app`; o `bastion` aceita 22 só de `admin_ssh_cidrs`, e essa regra é a única que o `infra access` altera, 5.6) | `vpc_id`, `admin_ssh_cidrs` | IDs dos grupos |
| `compute` | par de chaves (gerado pelo Terraform, privada gravada em `.keys/` com permissão 600), instâncias web e app com IP fixo (03, seção 5), bastion, `user_data` mínimo (04, seção 5). As três famílias de instância usam `lifecycle { ignore_changes = [ami] }` (03, seção 3.3) e `metadata_options` **fixo**: `http_tokens = "required"`, `http_put_response_hop_limit = 1`, `http_endpoint = "enabled"` (02, seção 4, A14; sem variável). Guarda a constante `fluent_bit_systemd_units` (02, seção 7.1) | subnets, grupos, AMI, tipos, contagens, perfil `LabInstanceProfile`, bucket de artefatos | mapa nó → ID, IP privado, AZ, papel; IP do bastion; chave privada e pública (sensível a privada) |
| `alb` | ALB público, listener 80, target group com verificação `GET /`, anexos dos nós web | subnets públicas, `swarm-web`/`alb`, nós web | nome DNS |
| `database` | RDS MySQL, subnet group, **id do ciclo** (`random_id`, 03 seção 5), snapshot final obrigatório `<prefixo>-final-<id do ciclo>`, restauração por `db_snapshot_identifier` **só na criação** (`lifecycle { ignore_changes = [snapshot_identifier] }`, 05, B2) | subnets de banco, grupo `rds`, classe, armazenamento, Multi-AZ, senha | endpoint, porta, identificador |
| `secrets` | `random_password` dos segredos gerados e **parâmetros SSM** `/tnf/<env>/secrets/<nome>` (05, A2), incluindo `db_admin_password` | segredos manuais (sensíveis) | nomes dos parâmetros |
| `artifacts` | bucket com `force_destroy`; envia `node/`, `stacks/`, `stack.env`, manifesto com hash e, **por último**, o marcador `READY` (04, seção 4) | caminhos dos arquivos, valores do ambiente | nome do bucket |
- Cada módulo documenta suas variáveis e saídas no próprio `variables.tf`/`outputs.tf` com `description` em português; não há valores fixos dentro dos módulos que sejam decisões de ambiente.
- O `bootstrap` **não usa módulos**: `prevent_destroy` precisa ser escrito literalmente nos recursos. Os dois buckets são criados pelo `infra bootstrap` com o AWS CLI e o Terraform gerencia só a configuração deles (05, B3; H20).
- O perfil de instância é lido por `data "aws_iam_instance_profile"` pelo nome `LabInstanceProfile`; o Terraform **não cria nenhum recurso de IAM** (RES-03).

## 4. Convenções de código
### 4.1 Terraform
| Tema | Regra |
|---|---|
| Versões | `required_version = ">= 1.11, < 2.0"`; provedor `aws` fixado em uma série (`~> 6.0`, a confirmar na implementação), mais `random`, `tls`, `local`. O arquivo `.terraform.lock.hcl` é **versionado** |
| Estado | S3 com `use_lockfile = true`; chave `envs/<env>/terraform.tfstate`; bucket e região passados por `-backend-config` pelo `infra` (02, seção 2) |
| Formatação | `terraform fmt` obrigatório (o CI recusa código sem formato) |
| Validação | toda variável de 03 tem bloco `validation` com **mensagem em português** que diz o que corrigir |
| Etiquetas | `default_tags` no provedor: `Project = tem-na-festa`, `Env = <env>`, `ManagedBy = terraform`; o `Name` de cada recurso segue a seção 4.2 |
| Sensíveis | toda variável/saída com segredo é `sensitive = true` (inclusive a chave SSH privada); nenhum segredo em `user_data` nem em `local-exec` com eco |
| `for_each` | sempre com chaves estáveis (`web-1`, `app-1`), nunca índices numéricos soltos, para que mudar a contagem não recrie nós já existentes |
| `lifecycle` das instâncias | web, app e bastion com `ignore_changes = [ami]`: um nó existente nunca é substituído por AMI nova (03, seção 3.3). Revisado no código, pois não é um teste de rejeição do `plan` |
| Metadados das instâncias | web, app e bastion com `metadata_options { http_tokens = "required", http_put_response_hop_limit = 1, http_endpoint = "enabled" }`, escritos literalmente no módulo `compute`, **sem variável** (02, seção 4, A14). Revisado no código e conferido por Q22 (05) |
| `lifecycle` do RDS | `ignore_changes = [snapshot_identifier]`: o snapshot de origem só vale na criação; mudar a variável depois não recria o banco (03, seção 3.5; 05, B2). Revisado no código e conferido por Q21 |
| Dependências | `depends_on` explícito onde 04 exige (EC2 depois das rotas da NAT; `READY` por último) |

### 4.2 Nomes
| Item | Padrão | Exemplo |
|---|---|---|
| Prefixo de recursos | `<project_name>-<env>` | `tem-na-festa-dev` |
| Nós | `<prefixo>-web-1`, `<prefixo>-app-1`, `<prefixo>-bastion` | `tem-na-festa-prod-app-2` |
| Bucket de artefatos | `tnf-<env>-artifacts-<id-da-conta>-<região>` | `tnf-dev-artifacts-123456789012-us-east-1` |
| Bucket de state | `tnf-tfstate-<id-da-conta>-<região>` | – |
| Bucket bronze | `bucket-bronze-<id-da-conta>-<região>` | `bucket-bronze-827290239455-us-east-1` (já existe, 05 B3) |
| Parâmetros SSM | `/tnf/<env>/secrets/<nome>` | `/tnf/prod/secrets/jwt_secret` |
| Segredos Docker | `tnf_<nome>` | `tnf_db_password` |
| Stacks Swarm | `tnf-rabbitmq`, `tnf-app`, `tnf-web` | – |
| Imagens Docker Hub | `<namespace>/tnf-frontend`, `tnf-backend`, `tnf-messaging` | – |
| Snapshot final | `<prefixo>-final-<id do ciclo>` (8 caracteres hexadecimais) | `tem-na-festa-dev-final-a1b2c3d4` |
| Snapshot manual | `<prefixo>-manual-<AAAAMMDD-HHMMSS em UTC>` | `tem-na-festa-dev-manual-20261010-153012` |
- Nomes de buckets têm no máximo 63 caracteres; o `plan` falha com mensagem clara se o prefixo escolhido estourar esse limite.
- **Idioma:** identificadores, nomes de arquivo e de recurso em **inglês**; mensagens para o usuário, `description` das variáveis, comentários e documentação em **português**.

### 4.3 Scripts (bash)
- `#!/usr/bin/env bash` com `set -euo pipefail`; passam no `shellcheck` sem exceções não justificadas.
- Nunca imprimem valores de segredos; `set +x` em trechos sensíveis (05, A6). Senhas nunca vão na linha de comando de outro programa (05, A6).
- Toda falha termina com **uma mensagem que diz o que aconteceu e o que fazer**, e um código de saída: `0` sucesso; `1` erro inesperado; `2` pré-condição não atendida; `3` tempo esgotado esperando o ambiente (ou ambiente no ar, mas não pronto, 04 seção 8).
- Idempotentes: rodar duas vezes não estraga nada.
- Os scripts de `node/` registram em `/var/log/tnf-*.log` e escrevem status no S3 (04, seção 5).
- **Metadados da instância:** o IMDSv1 está desligado nas EC2 (02, A14). Qualquer script de `node/` que consulte o serviço de metadados (`169.254.169.254`) pede antes o token (`PUT /latest/api/token`) e o envia no cabeçalho; o AWS CLI v2 já faz isso sozinho. Os scripts não dependem de credenciais da AWS dentro de containers.

## 5. O comando `infra`
Um único ponto de entrada, em bash, para as operações do dia a dia. Ele só orquestra: a lógica de infraestrutura fica no Terraform e nos scripts de `node/`.

| Comando | O que faz | Refs |
|---|---|---|
| `infra doctor` | confere ferramentas e versões (Terraform ≥ 1.11, AWS CLI, `jq`, `curl`), credenciais do laboratório e região, e o ambiente WSL (5.1). **Também procura sobras de infraestrutura antiga na conta** (5.2): instâncias EC2, NAT gateways, Elastic IPs, load balancers e instâncias RDS que **não** tenham as etiquetas `ManagedBy = terraform` e `Project = tem-na-festa`. Só avisa e lista; **nunca apaga** nada. Mostra o que falta | 04, seção 3 |
| `infra session [minutos]` | informa quanto tempo resta no cronômetro do Learner Lab (a AWS não informa o vencimento das credenciais, 5.3); sem argumento, mostra a estimativa atual. Opcional | 5.3 |
| `infra bootstrap` | cria com o AWS CLI (ou confirma que existem) o bucket do state e o bronze, e aplica a configuração deles com o Terraform; roda uma vez por conta; seguro de repetir. **Se um bucket já existir** (por exemplo o bronze), ele é **adotado**, sem tocar nos objetos; se o `plan` mostrar qualquer mudança num bucket que já existia, o `infra` mostra e pede a sua confirmação antes de aplicar (5.2; 05, B3) | 02, seção 2; 05, B3 |
| `infra init-secrets` | cria `secrets.env` perguntando os valores obrigatórios, com permissão 600. **Só é necessário com a mensageria ligada** (não há segredo manual enquanto ela estiver desligada) | 05, A5 |
| `infra plan <env>` | executa as pré-checagens e mostra o `terraform plan`, sem criar nada. Detecta o IP atual (5.6) e destaca no plano se o IP autorizado no bastion mudar | 04, seção 3 |
| `infra up <env> [--snapshot <id>]` | pré-checagens (inclusive sessão, `errored.tfstate`, lock e coerência de `manager_count`, 5.3 e 5.4), detecção do IP atual (5.6), `init`, `apply`, acompanha os nós e o ALB até responder 200; imprime URL, IP do bastion e comando SSH. **Em ambiente novo**, o banco nasce do snapshot **final** mais recente, ou do `<id>` (final ou manual do ambiente) se `--snapshot` for dado; **com o ambiente no ar**, não mexe no banco e recusa `--snapshot` | 04, seção 3; 05, B2 |
| `infra status <env>` | situação dos nós (inclusive esperados ausentes), das stacks, das versões em execução (digests) e do ALB | 04, seção 8; 07, seção 5.2 |
| `infra access <env> [--ip <ip>]` | prepara o seu acesso SSH a partir **desta** máquina e rede: recria `.keys/<env>.pem` a partir do state se faltar e, com a sua confirmação, autoriza o seu IP atual no bastion (5.6). Não altera nenhum outro recurso | 02, seção 8 (A15); 5.6 |
| `infra ssh <env> [nó]` | SSH pelo bastion até o nó escolhido (sem digitar IPs nem chaves). **Antes de conectar** faz as verificações de `infra access` (chave presente; IP autorizado, oferecendo autorizar). **Para chegar ao banco:** `infra ssh <env> app-1` e, no nó, `tnf-db-shell` | 02, seções 8 e 9 (A12, A15); 05, A7; 5.6 |
| `infra snapshot <env>` | snapshot **manual** do RDS (`<prefixo>-manual-<data UTC>`) com o ambiente no ar; espera ficar disponível e imprime o nome. Nunca é restaurado sozinho | 05, B2 |
| `infra snapshots <env>` | lista os snapshots do ambiente (nome, tipo final ou manual, data, tamanho, estado) para escolher um `--snapshot`; só leitura | 05, B2 |
| `infra down <env>` | pré-checagens como as do `up` (sem a de `manager_count`), `terraform destroy` (snapshot final do RDS), depois poda: 3 finais e 3 manuais mais recentes | 04, seção 9; 05, B2 |
- **Segurança de uso:** `infra down prod` pede para digitar o nome do ambiente para confirmar; `--yes` pula a pergunta apenas em `dev`. Ambiente desconhecido é recusado (T1).
- **Como o Terraform recebe os segredos manuais:** o `infra` lê `secrets.env` e os entrega por variáveis de ambiente `TF_VAR_*`, nunca por linha de comando nem por arquivo `.tfvars` (05, A5).
- **Credenciais da AWS:** o `infra` usa as credenciais já configuradas na sessão (`aws configure` ou variáveis de ambiente) e nunca as grava. A cada sessão do laboratório, você as renova como já faz hoje, **dentro do WSL** (as credenciais configuradas no Windows não valem lá).
- **Estado do `bootstrap`:** guardado no próprio bucket de state, na chave `bootstrap/terraform.tfstate`. Como o `infra bootstrap` cria o bucket de state com o AWS CLI antes de rodar o Terraform, o state já nasce no bucket, sem migração (H4, H20). Se o estado se perder, o `infra bootstrap` reaplica a configuração dos buckets existentes em vez de falhar.
- Ajuda: `infra --help` e `infra <comando> --help` descrevem entradas e saídas.

### 5.1 Ambiente de execução: WSL no Windows (*Decidido*)
A maioria das máquinas do projeto é Windows. O `infra` e os scripts são em **bash**, e no Windows rodam dentro do **WSL 2 com Ubuntu**. Também funcionam Linux e macOS.
- **Instalação:** `docs/primeiros-passos-windows.md` descreve, em ordem: instalar o WSL com Ubuntu; instalar Terraform (1.11 ou superior), AWS CLI v2, `jq`, `curl`, `make`, `shellcheck`, `tflint`, `bats`, `yamllint` e (opcional) `gh`; clonar o repositório; rodar `infra doctor`. O guia também diz que o `infra` **não deve ser executado no PowerShell** (G15).
- **Clonar dentro do sistema de arquivos do WSL** (por exemplo `~/projetos/`), **não** em `/mnt/c/...`. Em `/mnt/c` as permissões `600` de `secrets.env` e da chave SSH não funcionam (o SSH se recusa a usar uma chave com permissão aberta) e o Terraform fica muito mais lento. O `infra doctor` **avisa** se estiver rodando em `/mnt/c` e recusa gravar chaves ali.
- **Finais de linha:** o `.gitattributes` força `LF` em `*.sh`, `infra`, `*.tf`, `*.yml` e demais arquivos de texto. Com `CRLF` (padrão do Git no Windows), os scripts quebram com erros enigmáticos (`^M: command not found`). O CI recusa arquivos com `CRLF`.
- **SSH:** a chave fica em `.keys/` dentro do WSL e o `infra ssh` a usa de lá; o PowerShell não é usado para isso. **Em cada máquina nova** (ou clone novo), a chave aparece sozinha na primeira vez que se usa `infra ssh` ou `infra access` (5.6).
- **Editor:** pode continuar sendo o VS Code do Windows, abrindo a pasta pelo WSL (extensão *WSL*), de modo que os arquivos fiquem no sistema de arquivos do Linux.
- **Docker local não é necessário** para o dia a dia; o `make check` valida os compose files por análise de sintaxe (`yamllint`), sem precisar do Docker. O cliente MySQL também não é necessário na sua máquina: ele fica nos nós app (02, A12).

### 5.2 Ponto de partida: conteúdo antigo (*Decidido*, auditoria item 7)
Hoje existem, juntos: um repositório de infra com conteúdo da versão antiga (incluindo workflows de ECR), um bucket bronze já criado e, possivelmente, recursos da infraestrutura antiga na conta AWS. O tratamento é:
- **Repositório (etapa E0, 09):** antes de qualquer mudança, cria-se a **tag `legacy-pre-specs`** no `main` atual, que preserva o conteúdo antigo no histórico do Git. A E0 acontece em uma **branch** (por exemplo `chore/e0-estrutura`) e **remove todo o conteúdo antigo**, inclusive os workflows de ECR (07, seção 2), substituindo-o pela árvore da seção 2. **Não existe pasta `legacy/`**: o que o repositório mostra é só o que está nos specs; para consultar o antigo, usa-se a tag.
- **Bucket bronze existente:** o `infra bootstrap` o **adota** em vez de recriá-lo; os objetos nunca são alterados nem apagados (05, B3). Se não existir (conta nova), é criado com o AWS CLI.
- **Recursos antigos na AWS:** **não são apagados pela infra** (ela só gerencia o que cria). Você remove à mão o que sobrar da versão antiga **antes da E3**, e o `infra doctor` ajuda listando as sobras sem as etiquetas desta versão. Isso evita que EC2, NAT, Elastic IPs ou RDS antigos consumam o limite de instâncias, de EIPs e os créditos do laboratório.

### 5.3 Credenciais vencidas e state travado (*Decidido*, auditoria item 10)
As credenciais do Learner Lab vencem com a sessão (cerca de 4 horas). Se isso acontece no meio de um `apply` ou `destroy`, o Terraform não consegue mais falar com a AWS nem apagar o arquivo de lock do state no S3, e pode não conseguir gravar o state no fim. Os recursos já criados continuam existindo. O `infra` previne e recupera, **sempre pedindo a sua confirmação antes de qualquer ação sobre o state**.

**Quanto tempo resta (prevenção).** A AWS não informa o vencimento das credenciais do laboratório. Por isso o `infra` combina duas fontes:
- se você informou (`infra session 90`, lendo o cronômetro do Learner Lab), usa esse valor, que fica em `.infra/session.json` ligado à sessão atual (a um resumo do *token*, nunca ao *token*);
- senão, estima pelo tempo desde que viu aquele *token* pela primeira vez, e avisa que é uma estimativa (a sessão pode ter começado antes).
- Antes de `up`, `down` e `bootstrap`, se restarem **menos de 20 minutos** (ou se a estimativa já passou de 3h40), o `infra` avisa e pede confirmação (`s/N`) para continuar. `--yes` não pula esse aviso. Também confirma que as credenciais funcionam (`aws sts get-caller-identity`) logo antes do `apply`.

**Estado salvo localmente (`errored.tfstate`).** Se o Terraform não consegue gravar o state remoto no fim, salva uma cópia em `envs/<env>/errored.tfstate`. Antes de qualquer `plan`, `up` ou `down`, o `infra` procura esse arquivo; se existir:
1. recusa continuar (código `2`) e orienta a renovar as credenciais do laboratório;
2. com as credenciais válidas, oferece enviá-lo ao state remoto com `terraform state push`, mostrando a diferença de versão (*serial*) entre o local e o remoto;
3. se o remoto estiver **mais novo** que o arquivo local, o `infra` **não envia** (nunca usa `-force`) e explica que é preciso decidir manualmente, indicando o caminho do arquivo, que é preservado;
4. depois do envio, o arquivo vai para `.infra/recovered/` com data e hora, e o `infra` roda um `plan` para mostrar o que ainda falta.

**Lock órfão.** Se o Terraform recusar por já existir um lock, o `infra` lê o arquivo de lock no S3 (`envs/<env>/terraform.tfstate.tflock`) e mostra **quem** o criou, **quando**, qual **operação** e o **ID**. Pergunta se existe outra execução sua em andamento (por exemplo em outra janela do WSL ou outra máquina). Só destrava (`terraform force-unlock`) se você **digitar o nome do ambiente**; se o lock foi criado há menos de 10 minutos ou por outra máquina, o `infra` avisa isso com destaque antes de pedir. Depois de destravar, ele roda um `plan` e pede para você repetir `infra up` ou `infra down`, que são idempotentes.

**Regras gerais:** nada disso roda sozinho; os dois fluxos funcionam também para o `bootstrap`; as mensagens sempre dizem o que aconteceu, o que será feito e como desfazer ou conferir. O CI testa os fluxos com um `terraform` simulado (`bats`), sem AWS.

### 5.4 Mudar a contagem de nós e `manager_count` (*Decidido*, auditoria item 11)
As regras de negócio estão em 03, seção 3.2; aqui está o que cabe ao `infra`:
- **Aumentar ou reduzir `web_node_count`/`app_node_count`** não pede nada especial do `infra`: o `plan` mostra os nós criados ou destruídos (G9), a validação T14 impede reduzir abaixo das réplicas, e o líder faz a limpeza no Swarm (04, seção 7, passo 1). O `infra plan` e o `infra up` listam, em destaque, **quais nós serão destruídos** numa redução.
- **`manager_count` fixo com o ambiente no ar:** a verificação fica no `scripts/preflight.sh`, **depois** das checagens de estado limpo e **antes** do `terraform apply`. O `infra` lê o `stack.env` aplicado no bucket de artefatos do ambiente, extrai `MANAGER_COUNT` e compara com o valor de `manager_count` em `terraform.tfvars`. Se forem diferentes, recusa (código `2`) com uma mensagem que diz o valor em vigor, o valor pedido, por que não é permitido (os managers são o quórum do Swarm) e o caminho: `infra down <env>` e `infra up <env>`. Se o `stack.env` não existir (ambiente novo) ou o bucket não responder por o ambiente não existir, a checagem passa em silêncio. Não vale para `infra down` e `infra plan` só informa.
- Como é regra do `infra`, **não é um teste do contrato do `plan`** (a validação de variáveis não enxerga o ambiente em execução). Quem rodar `terraform apply` diretamente fica fora dessa proteção (03, seção 6).

### 5.5 Snapshots do banco no `infra` (*Decidido*, auditoria item 12)
O comportamento está em 05, B2; aqui, o que cabe ao `infra` (`scripts/snapshots.sh`):
- **Como sabe se o ambiente é novo:** consulta o state (`terraform state list`); se o RDS do módulo `database` consta, o ambiente está no ar. É esse o critério para procurar ou recusar snapshot em `infra up`.
- **Escolha em ambiente novo:** sem `--snapshot`, o final mais recente (filtro pelo prefixo `<prefixo>-final-`, estado disponível, ordenado pela data de criação). Com `--snapshot <id>`, o `<id>` precisa começar com `<prefixo>-final-` ou `<prefixo>-manual-` e estar disponível na região; do contrário, recusa (código `2`) listando os do ambiente.
- **Criar e podar:** o manual usa o nome com a data em UTC; a poda só considera os dois prefixos do próprio ambiente, mantém 3 de cada tipo e roda depois de um `destroy` concluído.
- **Recuperar um snapshot manual:** `infra down` e `infra up --snapshot <id>`. Não existe "voltar o banco no ar" para um snapshot: restaurar sempre cria um RDS novo, por isso exige recriar o ambiente.

### 5.6 Acesso de qualquer máquina ou rede: `infra access` (*Decidido*, auditoria item 18)
Você é o operador único, mas usa máquinas e redes diferentes. Sem tratamento, o SSH só funcionaria na máquina e na rede do `infra up` (a chave fica em um arquivo local e o bastion aceita um IP só). O comportamento está em 02, seção 8 (A15); o `scripts/access.sh` implementa o que segue, para o ambiente `<env>` (ambiente que não existe ou sem state: mensagem "o ambiente não está no ar", código `2`).

**Chave SSH**
1. Se `.keys/<env>.pem` existe e corresponde ao par do ambiente, nada é feito. A correspondência é conferida derivando a chave pública (`ssh-keygen -y`) e comparando com a saída pública do Terraform.
2. Se o arquivo falta, a chave é lida do state (`terraform output -raw` da saída sensível, o que exige `init` com o backend e as credenciais do laboratório) e gravada com `umask 077` e permissão `600`. O `infra` recusa gravar em `/mnt/c` (5.1). Isto **não precisa de confirmação**: só cria um arquivo seu, sem tocar na AWS.
3. Se o arquivo existe mas não corresponde (sobra de um ambiente anterior com o mesmo nome), é trocado e a antiga fica como `<env>.pem.anterior`, com aviso.

**IP autorizado no bastion**
1. **Detecção:** `curl -fsS https://checkip.amazonaws.com` (IPv4). Com `--ip <ip>` (útil com VPN, CGNAT ou falha da detecção), usa o informado. Só se aceita **um endereço IPv4 único** (vira `/32`); qualquer outra forma, em especial `0.0.0.0/0`, é recusada (T9). Se a detecção falhar e não houver `--ip`, a mensagem diz como informar.
2. **Lista sua no `tfvars`:** se `admin_ssh_cidrs` estiver preenchida em `terraform.tfvars`, ela manda: o `infra` **não altera nada** e só avisa, caso o IP atual não esteja coberto, o que editar (03, seção 3.6).
3. **Comparação:** com a lista vazia, o `infra` lê da AWS os CIDRs liberados para a porta 22 no security group do bastion (localizado pelas etiquetas do ambiente) e compara com o IP atual. Se está coberto, nada a fazer.
4. **Autorizar:** se não está, mostra "autorizado: `<ips>`; seu IP atual: `<ip>`" e pergunta `s/N`. Com `s`: pré-checagens de 5.3 (sessão restante, `errored.tfstate`, lock), depois `terraform plan -out` com `admin_ssh_cidrs=["<ip>/32"]`, e o `infra` confere o plano em JSON: **se houver qualquer mudança além da regra do SSH do security group do bastion, recusa** (código `2`, "há outras mudanças pendentes; rode `infra up <env>`") e não aplica nada. Só se o plano for apenas essa regra, aplica o plano salvo e imprime o resultado. Conexões SSH já abertas não são derrubadas.
5. O IP novo **substitui** o anterior (a premissa é um operador). Para acessar de dois lugares ao mesmo tempo, preencha `admin_ssh_cidrs` no `terraform.tfvars` (passo 2).

**Onde é acionado**
- `infra access <env>`: faz tudo acima de forma explícita.
- `infra ssh <env> [nó]`: antes de conectar, faz a parte da chave (sem perguntar) e a comparação do IP; se não estiver coberto, oferece autorizar (`s/N`). Em `N`, termina com código `2` e a mensagem diz o comando `infra access <env>`. Isso evita o sintoma de "a conexão expira sem explicação".
- `infra plan` e `infra up`: com a lista vazia no `tfvars`, detectam o IP e o passam ao Terraform (`-var`, que vale mais que o `tfvars`); se mudou desde o último `apply`, o plano **destaca** "o IP autorizado no bastion mudará de X para Y" e o `up` aplica junto com o resto, sem pergunta extra. Repetir o `infra up` do mesmo IP não altera nada (04, S2).
- `infra down` não precisa do IP.

**Segurança e limites:** nenhum recurso novo na AWS; a chave privada continua só no state (criptografado) e na cópia local `600` (05, A2 e A6); `infra access` nunca altera outro recurso além da regra do SSH; vale também no WSL de outra máquina com as credenciais do laboratório renovadas. O CI testa tudo com `aws`, `terraform`, `curl` e `ssh-keygen` simulados (G24).

## 6. Arquivos sensíveis e `.gitignore`
| Padrão | Motivo |
|---|---|
| `secrets.env` | segredos manuais (05, A5) |
| `.keys/`, `*.pem` | chave SSH privada (05, A6) |
| `.terraform/`, `*.tfstate`, `*.tfstate.*`, `crash.log` | estado e cache local (inclui `errored.tfstate`) |
| `.infra/` | cache local do `infra` (por exemplo, resultado do último `status`, `session.json` e `recovered/`) |
| `*.auto.tfvars` | valores locais; os de ambiente ficam em `terraform.tfvars`, sem segredos |
- **Versionados:** `.terraform.lock.hcl`, `terraform.tfvars` dos ambientes (sem segredos), `secrets.env.example` (só nomes das chaves), `.gitattributes`, `specs/`.
- O CI verifica por varredura que nenhum arquivo ignorado entrou no Git e que não há padrões de segredo (07, seção 6).

## 7. Convenções de Git e fluxo de trabalho
- **Branches:** `main` protegida por convenção; mudanças por *pull request* a partir de branches curtas (`feat/…`, `fix/…`, `docs/…`, `chore/…`). O PR só entra com o `ci-infra` verde e com o `make check` passando na sua máquina. Como o GitHub só consegue **exigir** isso (*branch protection*) em alguns planos, a regra vale como **conduta** e passa a ser bloqueio de verdade se o plano permitir (*Decidido* em 10/10/2026, auditoria item 15; 07, 4.5).
- **Commits:** mensagens no padrão *Conventional Commits* (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`), em português ou inglês, mas consistentes.
- **Specs são a fonte da verdade (SDD):** uma mudança de comportamento só entra com a **mudança correspondente em `specs/` no mesmo PR**. Um requisito sem teste ou um teste sem requisito é defeito.
- **Rastreabilidade (*Decidido* em 10/10/2026, auditoria item 20):** os nomes dos testes carregam o ID do spec (por exemplo, `T5_managers_par`, `S3_replicas`), e `tests/TRACEABILITY.md` lista, **para cada ID dos specs, a etapa do plano (09) em que é verificado e o verificador**: teste automático ou procedimento manual no laboratório. A conferência é **automática**, pelo `scripts/check-traceability.sh` (`make trace`, que faz parte do `make check` e do CI):
  - **Quais IDs:** os IDs (letra e número, como `T5`, `S3`, `Q22`, `R17`, `C19`, `G24`, `P2`) da primeira coluna das tabelas sob os títulos "Critérios de aceite" de 03 a 09. Os IDs de decisões (`A`, `D`, `E`, `F`, `H`, `I`) e os das tabelas de decisões de 02 (`P1` a `P3`) não entram.
  - **A tabela de rastreabilidade** tem, por linha: `ID | etapa (E0 a E9) | verificador | situação`. O verificador é um arquivo de teste (por exemplo, `tests/contract/T5.tftest.hcl`), o nome de um teste `bats` ou "manual: <procedimento>". A situação tem **três valores**: `pendente`, `verificado` ou `não aplicável nesta entrega: <motivo>` (por exemplo, os testes da E8 sem a configuração do microsserviço).
  - **O que o script recusa (código `2`):** (a) um ID dos specs sem linha na tabela; (b) uma linha da tabela cujo ID não existe mais nos specs; (c) um ID que **não aparece** nas listas "Pronto quando" da seção "Etapas" de 09 (a falha que a auditoria do item 20 encontrou); o script só lê essas listas, e nelas o serviço da AWS se escreve "bucket de artefatos" ou "bronze", nunca "S3" sozinho, porque S3 é também um ID de teste (04); (d) uma linha cuja etapa difere da etapa de 09 em que o ID aparece (os intervalos escritos em 09, como `Q19 a Q21`, são expandidos; um ID citado em mais de uma etapa, como `Q22`, aceita qualquer uma delas).
  - **Modo estrito (`--strict`):** exige também verificador preenchido (nunca "a definir") e situação `verificado` ou `não aplicável nesta entrega: <motivo>` (com o motivo escrito) em todas as linhas; recusa `pendente`. Na E0 a tabela nasce com todos os IDs, a etapa de 09, o verificador previsto e a situação `pendente`; cada etapa preenche as suas linhas ao terminar; a **E9 roda o modo estrito** (09). O CI e o `make check` rodam o modo normal.
- **Versões:** marcas (`v0.1.0`…) para pontos estáveis; o `README` registra qual versão foi usada em cada entrega. A marca `legacy-pre-specs` é reservada para o conteúdo antigo (5.2) e nunca é movida.

## 8. Atalhos do desenvolvedor (`Makefile`)
| Alvo | O que roda | Equivale no CI |
|---|---|---|
| `make fmt` | `terraform fmt -recursive` | formatação |
| `make lint` | `tflint`, `shellcheck`, `yamllint` | boas práticas, scripts e compose files |
| `make test` | `terraform validate` nas três raízes, `terraform test` do contrato e `bats` | validação e contrato |
| `make trace` | `scripts/check-traceability.sh` (e, com `make trace STRICT=1`, o modo estrito) | rastreabilidade (07, seção 6) |
| `make check` | `fmt` (em modo de verificação), `lint`, `test` e `trace` | tudo, como o `ci-infra.yml` |
- O mesmo `make check` roda no CI e na sua máquina, então "funciona aqui" e "passa no CI" significam a mesma coisa. Nenhum deles usa credenciais da AWS.

## 9. Critérios de aceite
| # | Cenário | Esperado |
|---|---|---|
| G1 | Clonar o repositório e rodar `infra doctor` | lista de ferramentas e credenciais, com instrução para o que faltar |
| G2 | `make check` sem credenciais da AWS | passa |
| G3 | Procurar segredos ou arquivos ignorados versionados | nenhum |
| G4 | Comparar `envs/dev` e `envs/prod` | diferem apenas em `terraform.tfvars` e na chave do state |
| G5 | `infra bootstrap` duas vezes | a segunda não altera nada |
| G6 | Tentar destruir o `bootstrap` com objetos nos buckets | não apaga nenhum bucket nem objeto (o Terraform não gerencia os buckets, e a configuração tem `prevent_destroy`) |
| G7 | Pré-checagens com ambiente desconhecido (`staging`) e com credenciais ausentes ou inválidas (teste `bats`, sem AWS) | recusado com mensagem clara em português (T1, ou credenciais) e código `2`, antes de qualquer chamada ao Terraform |
| G8 | `infra down prod` sem digitar o nome do ambiente (teste `bats`, com `terraform` simulado); repetir digitando; repetir `infra down dev --yes` | sem digitar: nada é destruído e o `terraform` simulado não é chamado; digitando o nome: segue; `--yes` pula a pergunta só em `dev` (e em `prod` não) |
| G9 | Mudar `web_node_count` de 2 para 3 | o `plan` cria só `web-3`; `web-1` e `web-2` não são recriados |
| G10 | Usar o `scripts/check-traceability.sh` (teste `bats` com specs e tabela de exemplo): **(a)** specs e tabela corretos; **(b)** um ID de spec sem linha na tabela; **(c)** uma linha da tabela com ID inexistente nos specs; **(d)** um ID de spec que não aparece nas etapas de 09; **(e)** uma linha com etapa diferente da de 09; **(f)** intervalos como `Q19 a Q21` e IDs repetidos em duas etapas; **(g)** `--strict` com uma linha `pendente`, uma com verificador "a definir", uma `não aplicável nesta entrega` sem motivo e uma com motivo; **(h)** a palavra "S3" fora das listas "Pronto quando" de 09. Depois, rodar no repositório real | **(a)** passa; **(b)** a **(e)** recusam com código `2`, nomeando o ID e o que fazer; **(f)** os intervalos são expandidos e o ID repetido aceita qualquer das etapas; **(g)** o modo normal passa; o `--strict` recusa as três primeiras e aceita a com motivo; **(h)** não conta como citação do teste S3. No repositório real, o modo normal passa em todo `make check` e o **modo estrito passa na E9** (09), com todos os IDs de 03 a 09 (T, S, Q, R, C, G, P) com etapa e verificador |
| G11 | `infra ssh dev app-1` com o ambiente no ar | abre shell no nó pelo bastion |
| G12 | Verificar `.terraform.lock.hcl` | versionado |
| G13 | Rodar `infra doctor` em um clone dentro de `/mnt/c` | avisa que o repositório deve estar no sistema de arquivos do WSL |
| G14 | Commitar um script com `CRLF` | o CI falha apontando o arquivo; o `.gitattributes` evita que aconteça por padrão |
| G15 | **Conferência manual na E0:** ler `docs/primeiros-passos-windows.md` (não há como testar o `infra` num Windows sem WSL de forma automática) | o guia existe e traz, em ordem: instalar o WSL com Ubuntu, instalar as ferramentas de 5.1, clonar dentro do sistema de arquivos do WSL (não em `/mnt/c`), configurar as credenciais do laboratório dentro do WSL, rodar `infra doctor`; e diz que o `infra` não deve ser executado no PowerShell |
| G16 | `infra bootstrap` em conta onde o bucket bronze já existe e tem objetos | o bucket é adotado, sem ser recriado; nenhum objeto é apagado ou alterado; qualquer diferença de configuração é mostrada e só aplicada com a sua confirmação; a segunda execução não altera nada |
| G17 | `infra doctor` em conta com EC2, NAT, Elastic IP, load balancer ou RDS sem as etiquetas `ManagedBy = terraform` e `Project = tem-na-festa` | lista esses recursos como sobras prováveis da infraestrutura antiga; não apaga nada |
| G18 | Conferir o repositório depois da E0 | contém apenas a estrutura da seção 2; nenhum workflow de ECR; a tag `legacy-pre-specs` existe e aponta para o conteúdo antigo |
| G19 | Existe `envs/<env>/errored.tfstate` e rodar `infra up <env>` (com `terraform` simulado e, depois, no laboratório) | recusa com código `2` e mensagem; com credenciais válidas oferece o `state push`; não envia se o remoto for mais novo; o arquivo é preservado ou arquivado em `.infra/recovered/`; nada é enviado sem confirmação |
| G20 | Existe um lock órfão (no laboratório: interromper um `apply` com `kill -9`) e rodar `infra up <env>` | o `infra` mostra quem, quando, operação e ID; sem digitar o nome do ambiente nada é destravado; com a confirmação, destrava, roda o `plan` e o `infra up` seguinte conclui |
| G21 | Restam menos de 20 minutos (`infra session 15`) e rodar `infra up` ou `infra down`; repetir com `--yes` e com 60 minutos | com 15 min avisa e pede confirmação, e `--yes` não pula o aviso; com 60 min não avisa; sem informar o tempo, o aviso diz que é uma estimativa |
| G22 | Com um `stack.env` aplicado com `MANAGER_COUNT=1` (no teste automático, o bucket e o `terraform` são simulados; no laboratório, um ambiente dev no ar), mudar `manager_count` para `3` em `terraform.tfvars` e rodar `infra up dev`; repetir com `infra down dev` e com um ambiente novo (sem `stack.env`) | o `up` recusa com código `2` antes de qualquer `apply`, dizendo o valor em vigor, o pedido e o caminho (`infra down` e `infra up`); o `down` não é afetado; no ambiente novo a checagem passa; com `manager_count` igual ao aplicado, passa |
| G23 | Com `aws` e `terraform` simulados (teste automático): ambiente novo com snapshots finais e manuais de vários datas e de outro ambiente; rodar `infra up dev` sem opções; com `--snapshot` de um manual do ambiente; com `--snapshot` inexistente, de outro ambiente e com o ambiente já no ar (RDS no state); `infra snapshots dev` | sem opções escolhe o final mais recente e ignora os manuais; com o manual do ambiente usa esse; inexistente, de outro ambiente e com o ambiente no ar são recusados com código `2` antes do `apply`; a listagem mostra só os do ambiente, com o tipo; a poda simulada mantém 3 de cada tipo e não toca nos de outro ambiente |
| G24 | Com `aws`, `terraform`, `curl` e `ssh-keygen` simulados (teste automático), rodar `infra access` e `infra ssh` nos cenários: **(a)** `.keys/<env>.pem` ausente; presente e correto; presente mas de outro ambiente; clone em `/mnt/c`. **(b)** IP atual já coberto; não coberto (com resposta `N` e com `s`); plano com outra mudança além da regra do SSH. **(c)** `admin_ssh_cidrs` preenchida no `tfvars`. **(d)** detecção do IP falhando, `--ip` válido e `--ip 0.0.0.0/0` | **(a)** ausente: recriada a partir da saída do state, com permissão `600`, sem perguntar; correta: não é tocada; de outro ambiente: trocada e a antiga guardada como `.pem.anterior`; em `/mnt/c`: recusa. **(b)** coberto: nada acontece; não coberto: mostra autorizado × atual e pergunta; `N` não aplica nada e o `ssh` termina com código `2` dizendo `infra access`; `s` aplica só o plano salvo; com outra mudança no plano: recusa com código `2` e não aplica nada. **(c)** nada é alterado, só aviso. **(d)** falha de detecção: mensagem diz como usar `--ip`; `--ip` válido vira `/32`; `0.0.0.0/0` é recusado (T9) |
| G25 | No laboratório, com o ambiente no ar e subido de outra máquina ou rede (por exemplo, o celular como roteador Wi-Fi): em uma máquina sem `.keys/<env>.pem`, rodar `infra ssh <env> app-1` e responder `s`; depois, voltar à rede anterior e tentar de novo | a chave é recriada e a conexão ao bastion expira antes da autorização; o `infra` avisa que o IP não está autorizado, a autorização muda **só** a regra do SSH e o acesso passa a funcionar; na rede anterior o `infra ssh` volta a avisar e oferece autorizar de novo; `infra up` repetido do mesmo IP não altera nada |

## 10. Decisões
| # | Decisão | Situação |
|---|---|---|
| H1 | Terraform e scripts em repositório só de infra | **Decidido** (autor) |
| H2 | `modules/environment` de composição; `envs/*` só com valores | **Decidido** (09/10/2026) |
| H3 | `infra` em bash, com os comandos da seção 5; no Windows, dentro do WSL 2 (Ubuntu) | **Decidido** (autor, 09/10/2026) |
| H4 | Estado do `bootstrap` guardado no próprio bucket, que o `infra bootstrap` cria antes do Terraform (H20) | **Decidido** (09/10/2026; ajustado em 12/10/2026) |
| H5 | Idioma: identificadores em inglês; mensagens, descrições e documentos em português | **Decidido** (09/10/2026) |
| H6 | Convenções de nomes da seção 4.2 | **Decidido** (09/10/2026) |
| H7 | `Makefile` com os mesmos checks do CI; `tests/TRACEABILITY.md` | **Decidido** (09/10/2026) |
| H8 | Specs como fonte da verdade e exigidas em todo PR de comportamento | **Decidido** (09/10/2026) |
| H9 | `infra ssh` como atalho de acesso pelo bastion | **Decidido** (09/10/2026) |
| H10 | Clonar no sistema de arquivos do WSL; `.gitattributes` com `LF`; `infra doctor` avisa sobre `/mnt/c` | **Decidido** (09/10/2026) |
| H11 | Ponto de partida: tag `legacy-pre-specs` no `main` atual, E0 em branch que remove todo o conteúdo antigo e os workflows de ECR (sem pasta `legacy/`); `infra bootstrap` adota o bronze existente sem tocar nos objetos; recursos antigos da AWS removidos por você, com o `infra doctor` apenas avisando | **Decidido** (10/10/2026, opção A da auditoria item 7) |
| H12 | O `infra` previne (aviso com menos de 20 min, `infra session`) e recupera (`errored.tfstate` por `state push`, lock órfão por `force-unlock`) o vencimento das credenciais no meio de uma operação, sempre com confirmação e sem nunca usar `-force` no `state push` | **Decidido** (10/10/2026, opção A da auditoria item 10) |
| H13 | A regra "`manager_count` é fixo com o ambiente no ar" é verificada pelo `infra up` (`preflight.sh`, comparando com o `MANAGER_COUNT` do `stack.env` aplicado), e não pelo `plan`; mudar a contagem de nós web/app é livre e o `infra` só lista os nós que serão destruídos | **Decidido** (10/10/2026, opção A da auditoria item 11) |
| H14 | Snapshots pelo `infra`: `infra snapshot` (manual, nome com data UTC), `infra snapshots` (lista), `infra up --snapshot <id>` (só em ambiente novo); o `up` sem opções restaura só o final mais recente; poda de 3 finais e 3 manuais; `ignore_changes = [snapshot_identifier]` no RDS (05, B2; 03, seção 3.5) | **Decidido** (10/10/2026, opção A da auditoria item 12) |
| H15 | Exigir o `ci-infra` verde e o `make check` antes do merge é regra de conduta; vira bloqueio no GitHub (*branch protection*) só se o plano permitir, sem que a spec dependa disso nem da visibilidade do repositório | **Decidido** (10/10/2026, opção A da auditoria item 15; 07, F11) |
| H16 | Metadados das EC2 protegidos no módulo `compute`, sem variável: `http_tokens = "required"` e `http_put_response_hop_limit = 1` em web, app e bastion; scripts de `node/` que usam o serviço de metadados pedem o token (IMDSv2); conferido por Q22 | **Decidido** (10/10/2026, opção A da auditoria item 17; 02, A14) |
| H17 | Acesso de qualquer máquina ou rede: `infra access` recria a chave a partir do state e autoriza o IP atual no bastion (com confirmação, só a regra do SSH, recusando se o plano tiver outra mudança); `infra ssh` aciona as mesmas verificações; `infra plan` e `infra up` detectam o IP; `admin_ssh_cidrs` preenchida no `tfvars` não é alterada; um IP autorizado por vez; sem recurso novo na AWS | **Decidido** (10/10/2026, opção A da auditoria item 18; 02, A15) |
| H19 | Rastreabilidade ajustada: a situação tem três valores (`pendente`, `verificado`, `não aplicável nesta entrega: <motivo>`) e o `--strict` aceita os dois últimos; a tabela nasce com o verificador previsto; o script lê os IDs de 09 só nas listas "Pronto quando", onde o serviço da AWS não se escreve "S3" | **Decidido** (varredura final de 11/10/2026) |
| H22 | Na E3, `infra plan`, `infra up` e `infra down <env>` usa a raiz temporária `tests/live/e3-network/` (só os módulos `network` e `security`), com os valores de `envs/<env>/terraform.tfvars` e o state em `e3/<env>/terraform.tfstate`; cada ambiente usa a pasta de dados `.infra/tfdata/<env>`. Na E4a a raiz passa a ser `envs/<env>`, sem mudar o comando, e a pasta temporária é apagada. `infra up` e `infra down` pedem o nome do ambiente digitado antes de qualquer chamada ao Terraform; `--yes` dispensa só em dev (G8) | **Decidido** (12/10/2026, na E3, opção A e A) |
| H20 | Os buckets do `bootstrap` são criados pelo `infra bootstrap` com o AWS CLI, e o Terraform gerencia só a configuração deles (versionamento, criptografia, bloqueio de acesso público, só TLS), com `prevent_destroy`: a SCP do AWS Academy nega `s3:GetBucketObjectLockConfiguration`, que o recurso `aws_s3_bucket` sempre lê. O state do `bootstrap` nasce no bucket, sem migração; buckets existentes são adotados | **Decidido** (12/10/2026, na E2) |
| H21 | G7 cobre o ambiente desconhecido e as credenciais ausentes ou inválidas; na E2, as pré-checagens de 5.3 e 5.4 são entregues e testadas pelo `scripts/preflight.sh <plan\|up\|down\|bootstrap> [env]` com `aws` e `terraform` simulados (G7, G19, G21, G22), e o `infra up`/`down` passa a chamá-lo na E3 | **Decidido** (12/10/2026, na E2) |
| H18 | Todo ID de teste tem etapa e verificador, e a conferência é automática: `scripts/check-traceability.sh` (`make trace`, parte do `make check` e do CI) compara os specs 03 a 09, `tests/TRACEABILITY.md` (com coluna de etapa) e as etapas de 09; o modo `--strict` roda na E9; G15 passa a ser uma conferência manual do guia de Windows; G7 (E2) e G8 (E3) viram testes `bats` | **Decidido** (11/10/2026, opção A da auditoria item 20) |

## 11. Pendências
- Versão exata do provedor `aws` a fixar (na implementação).
- *Opcional, não bloqueia:* ligar *branch protection* com o `ci-infra` obrigatório na `main`, se o plano do GitHub permitir (07, 4.5).
