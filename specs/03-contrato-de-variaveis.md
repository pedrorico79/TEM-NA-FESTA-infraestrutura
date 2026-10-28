# 03 – Contrato de variáveis (topologia por ambiente)

Estado: **confirmado** (09/10/2026); consolidado com as decisões de 05 a 09; ajustado em 10/10/2026 (seção 4: sem conferência da soma entre ambientes; seção 3.3: AMI não substitui nós existentes; seção 3.4: mensageria desligada com `service_replicas.messaging = 0`, testes T16 e T17; seções 3.2 e 5: mudança de contagens num ambiente no ar e `manager_count` fixo, auditoria item 11; seções 3.5 e 5: `db_snapshot_identifier` só vale na criação do RDS e id do ciclo, auditoria item 12; seção 3.4 e T14/T17: `messaging` só com 0 ou 1 réplica, auditoria item 13; seções 3.5 e 3.8, T12 e T15: variáveis sem valor padrão em branco até existirem e `db_schema_*` só exigidas quando o banco nasce vazio, auditoria item 16; seção 3.6: `admin_ssh_cidrs` detectado a cada operação e `ssh_private_key_path` recuperável do state, auditoria item 18) e em 11/10/2026 (seção 5: o final do nome do nó é contrato com o `converge.sh`, e o rótulo `messaging=true` entra na lista de rótulos, auditoria item 21; seção 5: `DB_SCHEMA_*` no `stack.env`, auditoria item 22; título da seção 6 com "Critérios de aceite", para T1 a T17 entrarem na conferência automática de rastreabilidade, varredura final de 11/10/2026; seção 3.1: `az_names` informada com pelo menos 2 AZs, decidido na implementação da E1). Única pendência: `messaging_port` e `messaging_secrets` (aguardam a configuração do microsserviço; só são exigidos com a mensageria ligada).
Depende de: 01 (RF-03, RF-04, RF-05, RES-05, RES-06) e 02 (arquitetura).

## 1. Princípios
- **Poucas variáveis no dia a dia, muitas com padrão.** Subir um ambiente é um único comando que lê o arquivo de valores do ambiente (`envs/dev/terraform.tfvars` ou `envs/prod/terraform.tfvars`). Quem quer outra topologia edita esse arquivo; os demais valores têm padrão sensato.
- **Valores por ambiente em arquivo versionado, sem segredos.** Segredos manuais entram por fora do repositório (mecanismo definido em 05).
- **Erros cedo e claros.** Toda combinação inválida falha no `terraform plan`, com mensagem em português que diz o que corrigir (seção 6). Esses casos são testados automaticamente (`terraform test`, 07 e 08).
- **Derivado não é variável.** Subnets, nomes, rótulos de nó e distribuição por AZ são calculados a partir das variáveis (seção 5), nunca digitados.

## 2. Variáveis por nível de uso
**Nível 1 – topologia (as que você realmente mexe):** `az_count`, `web_node_count`, `app_node_count`, `manager_count`, `nat_mode`, `bastion_enabled`, `service_replicas`, `image_tags`, `db_multi_az`.
**Nível 2 – tamanhos:** `web_instance_type`, `app_instance_type`, `bastion_instance_type`, `root_volume_size_gb`, `db_instance_class`, `db_allocated_storage_gb`.
**Nível 3 – raramente alteradas:** `env`, `region`, `project_name`, `vpc_cidr`, `az_names`, `ami_id`, `ec2_instance_limit`, `bronze_bucket_name`, `bronze_bucket_region`, `db_engine_version`, `db_name`, `db_master_username`, `db_snapshot_identifier`, `db_schema_repo_url`, `db_schema_ref`, `db_schema_path`, `admin_ssh_cidrs`, `ssh_private_key_path`, `dockerhub_namespace`, `messaging_port`.
**Segredos manuais (sensíveis):** `messaging_secrets`.

## 3. Contrato (nome, tipo, padrão, regra)

### 3.1 Identidade e região
| Variável | Tipo | Padrão | Regra |
|---|---|---|---|
| `env` | string | *(sem padrão; o `terraform.tfvars` de cada ambiente sempre a define)* | `dev` ou `prod` |
| `project_name` | string | `tem-na-festa` | minúsculas, números e hífen |
| `region` | string | `us-east-1` | `us-east-1` ou `us-west-2` (limite do laboratório) |
| `vpc_cidr` | string | `10.0.0.0/21` | precisa ser `/21` (a divisão em subnets depende disso) |
| `az_names` | list(string) | `null` | se `null`, usa as primeiras AZs disponíveis na região que suportam os tipos de instância escolhidos; se informado, deve ter **pelo menos 2 itens**, porque as subnets públicas e de banco sempre usam duas AZs (o ALB e o RDS exigem; 02), e só as `az_count` primeiras recebem nós web e app (*Decidido* em 11/10/2026, na E1) |

### 3.2 Topologia
| Variável | Tipo | dev | prod | Regra |
|---|---|---|---|---|
| `az_count` | number | 1 | 2 | 1 ou 2 |
| `nat_mode` | string | `single` | `per_az` | `single` (uma NAT, na AZ1) ou `per_az` (uma por AZ ativa) |
| `web_node_count` | number | 1 | 2 | ≥ 1; **total** de nós web, distribuídos em rodízio pelas AZs ativas |
| `app_node_count` | number | 1 | 3 | ≥ 1; **total** de nós app, distribuídos em rodízio pelas AZs ativas |
| `manager_count` | number | 1 | 3 | 1, 3 ou 5; ≤ `app_node_count`. **Fixo durante a vida do ambiente** (ver abaixo) |
| `bastion_enabled` | bool | `true` | `true` | se `false`, não há bastion (libera uma instância do limite do laboratório, mas remove o acesso de depuração) |
| `ec2_instance_limit` | number | 9 | 9 | limite **deste ambiente**; precondition: `web_node_count + app_node_count + (bastion_enabled ? 1 : 0)` não pode exceder este valor. 9 é o limite por região do laboratório (RES-05); em uma conta fora do laboratório, aumenta-se o valor no `terraform.tfvars` |

Distribuição em rodízio: o nó de índice `i` (começando em 0) fica na AZ `i mod az_count`. Com `az_count = 2`, `web_node_count = 2` dá um nó por AZ; `app_node_count = 3` dá 2 na AZ1 e 1 na AZ2.

**Mudar a contagem de nós com o ambiente no ar (*Decidido* em 10/10/2026):**
- **Aumentar** `web_node_count` ou `app_node_count`: cria só os nós novos (chaves estáveis, `web-3` etc.); eles leem o `join.json` e entram como worker, ou como manager se o índice estiver dentro de `manager_count` (04, seção 6). Os nós existentes não são recriados (08, G9).
- **Reduzir:** o Terraform destrói os nós de **maior índice**. Como os managers são os primeiros nós `app` e `manager_count ≤ app_node_count` é validado (T4), **só workers saem**. Antes, é preciso reduzir `service_replicas` se ele passar a exceder os nós restantes (T14). O líder remove do Swarm os nós que ficaram `Down` e não são mais esperados (04, seção 7, passo 1). O `app-1` (líder e RabbitMQ) nunca é removido.
- **`manager_count` não muda num ambiente no ar:** o papel de manager é definido na criação do nó e o Terraform não promove nem demove nós existentes. Por isso o `infra up` **recusa** um valor diferente do que está aplicado (a comparação usa o `MANAGER_COUNT` do `stack.env` já no S3), com a mensagem "para mudar o número de managers, recrie o ambiente (`infra down` e `infra up`)". A regra é do `infra` (08, G22), não do `plan`, porque depende do que já foi aplicado.

### 3.3 Instâncias
| Variável | Tipo | dev | prod | Regra |
|---|---|---|---|---|
| `web_instance_type` | string | `t3.micro` | `t3.micro` | tamanho `nano` a `large` |
| `app_instance_type` | string | `t3.small` | `t3.small` | tamanho `nano` a `large` |
| `bastion_instance_type` | string | `t3.micro` | `t3.micro` | tamanho `nano` a `large` |
| `root_volume_size_gb` | number | 20 | 20 | 8 a 100; volume gp3 |
| `ami_id` | string | `null` | `null` | sistema operacional **Ubuntu 24.04 LTS** (*Decidido*). Se `null`, o Terraform busca a AMI Ubuntu 24.04 LTS mais recente (publicada pela Canonical, arquitetura x86_64) **na região do ambiente, no momento em que o nó é criado**. Se informado, vale só para a região em que a AMI foi obtida (um ID de AMI não existe em outra região) e deve ser Ubuntu 24.04, pois os scripts de preparação (04) dependem dele |

- **A AMI não substitui nós existentes (*Decidido* em 10/10/2026).** As instâncias (web, app e bastion) usam `lifecycle { ignore_changes = [ami] }`: depois de criado, um nó nunca é trocado só porque a Canonical publicou uma AMI mais nova (nem porque o valor de `ami_id` mudou). Motivos: (1) `apply` repetido não altera nada (04, S2; 01, RNF-02); (2) evita substituir sem querer o líder do Swarm (`app-1`), que deixaria o `join.json` apontando para o próprio IP do nó recriado (04, seção 6).
- **Como atualizar a AMI de um ambiente vivo:** recriar o ambiente (`infra down` e `infra up`; cada ambiente novo nasce com a AMI mais recente) ou, de forma pontual, `terraform apply -replace=<nó>` (cuidado com o líder e com os managers; ver 04, seção 6).
- **Consequência aceita:** dois ciclos diferentes do mesmo ambiente podem usar AMIs diferentes (atualizações do Ubuntu). Isso é desejado para um ambiente que é recriado com frequência.

### 3.4 Serviços e imagens
| Variável | Tipo | dev | prod | Regra |
|---|---|---|---|---|
| `service_replicas` | object({frontend, backend, messaging}) | `{1, 1, 0}` | `{2, 2, 0}` | `frontend` e `backend` ≥ 1, **`frontend ≤ web_node_count` e `backend ≤ app_node_count`** (no máximo 1 réplica por nó, 06 seção 7); **`messaging` só pode ser `0` (desligada) ou `1`** (ver abaixo); o RabbitMQ não é variável (sempre 1, fixado em um nó). Os valores de `messaging` acima valem **até a E8**; na E8 passam a 1 nos dois ambientes (09) |
| `image_tags` | object({frontend, backend, messaging}) | `{dev, dev, dev}` | `{prod, prod, prod}` | etiqueta usada na **primeira subida** do ambiente; depois, as atualizações vêm dos deploys (07). Pode ser trocada por um `sha-<7>` para fixar uma versão. `image_tags.messaging` é **ignorada** enquanto `service_replicas.messaging = 0` |
| `dockerhub_namespace` | string | *(sem padrão; em branco até existir, 3.8)* | *(idem)* | usuário ou organização do Docker Hub; repositórios `tnf-frontend`, `tnf-backend` e `tnf-messaging` (07, seção 2). **Repositórios públicos**: os nós não precisam de credenciais. Não pode ficar em branco no `plan` |
| `messaging_port` | number | `null` | `null` | porta em que o microsserviço recebe os eventos do backend (06, 6.5). **PENDENTE**: o valor vem da configuração do microsserviço. **Obrigatória quando `service_replicas.messaging > 0`** (T16); quando informada, 1 a 65535 |

**Mensageria desligada (`service_replicas.messaging = 0`) (*Decidido* em 10/10/2026).** A imagem `tnf-messaging` só existe a partir da E8 (09), mas o ambiente precisa subir e ser aceito antes disso. Por isso o valor `0` é permitido **somente para `messaging`** e tem este significado, em todos os specs:
- O serviço `messaging` **não existe** no Swarm: a stack `tnf-app` tem só o `backend-som` (06, seção 2). O RabbitMQ continua sendo implantado normalmente, pois não depende desse interruptor.
- A imagem da mensageria **não é resolvida nem baixada**, e o deploy não a menciona (04, seção 7, passos 7 e 8).
- Os critérios que pedem "todas as réplicas em execução" (04, S1; 06, R1) e o `state: ready` consideram **só os serviços ligados**.
- `messaging_port` e `messaging_secrets` **não são exigidos**; sem eles, não existe nenhum segredo manual (05, A5).
- Ligar ou desligar depois é só mudar o valor no `terraform.tfvars` e rodar `infra up`; o líder percebe o novo `stack.env` e inclui ou remove o serviço (06, R14).

**Mensageria com no máximo 1 réplica (*Decidido* em 10/10/2026).** Ainda não se sabe se o microsserviço é seguro com mais de uma réplica: um consumidor de WhatsApp que mantém sessão pode duplicar envios ou disputar a mesma sessão. Por isso `service_replicas.messaging` aceita apenas `0` ou `1` e qualquer valor maior é recusado no `plan` (T17), com a mensagem "o microsserviço de mensageria ainda não foi confirmado como seguro com mais de uma réplica". Como `1` sempre cabe, a regra "`messaging ≤ app_node_count`" deixa de existir (o frontend e o backend continuam com a de nós). O compose da mensageria também fixa `max_replicas_per_node: 1` (06, seção 6.4). Para permitir mais réplicas, é preciso a configuração do microsserviço confirmando que é seguro e uma nova decisão que altere este item, T17 e 06.

### 3.5 Banco de dados
| Variável | Tipo | dev | prod | Regra |
|---|---|---|---|---|
| `db_instance_class` | string | `db.t3.micro` | `db.t3.small` | tamanho `nano` a `medium` (limite do laboratório) |
| `db_allocated_storage_gb` | number | 20 | 20 | 20 a 100 |
| `db_multi_az` | bool | `false` | `false` | `true` só se o laboratório permitir (02, seção 10) |
| `db_engine_version` | string | `8.0` | `8.0` | versão principal do MySQL (*Decidido*: 8.0, a que você usa hoje) |
| `db_name` | string | `tem_na_festa` | `tem_na_festa` | nome do schema (vem do seu `DB_URL` atual); ignorado ao restaurar de snapshot |
| `db_master_username` | string | `tnf_admin` | `tnf_admin` | usuário administrador do RDS; a senha é gerada (05) |
| `db_snapshot_identifier` | string | `null` | `null` | se informado, o RDS é criado a partir desse snapshot. **Só vale na criação do RDS**: o recurso usa `ignore_changes = [snapshot_identifier]`, então mudar o valor depois nunca recria o banco (05, B2). O `infra up` o preenche sozinho **apenas em ambiente novo**: com o snapshot **final** mais recente, ou com o que você escolher em `--snapshot <id>`; num ambiente já no ar, não o preenche |
| `db_schema_repo_url` | string | *(sem padrão; em branco até existir, 3.8)* | *(idem)* | URL do repositório **público** com o script SQL do schema (`TEM-NA-FESTA-database`); usado só quando o banco nasce vazio (05, B5). **Exigida só quando `db_snapshot_identifier` é `null`** |
| `db_schema_ref` | string | *(sem padrão; em branco até existir, 3.8)* | *(idem)* | **tag ou commit** do repositório do schema; nomes de branch (`main`, `master`, `develop`, `HEAD`) são recusados, para o schema ser reproduzível. **Exigida só quando `db_snapshot_identifier` é `null`**; se informada, a regra da branch vale sempre |
| `db_schema_path` | string | *(sem padrão; em branco até existir, 3.8)* | *(idem)* | caminho do arquivo SQL dentro do repositório (por exemplo `schema/init.sql`; o caminho real é informado na implementação). **Exigida só quando `db_snapshot_identifier` é `null`** |

### 3.6 Acesso e dados compartilhados
| Variável | Tipo | Padrão | Regra |
|---|---|---|---|
| `admin_ssh_cidrs` | list(string) | `[]` | CIDRs autorizados a fazer SSH no bastion; **proibido** `0.0.0.0/0` (T9). **Vazia (padrão):** o `infra` detecta o seu IP público atual e usa `["<ip>/32"]` a cada `plan`, `up` e `access`; o IP novo **substitui** o anterior (08, seção 5.6). **Preenchida no `terraform.tfvars`:** a lista é sua e o `infra` não a altera; só avisa se o IP atual não estiver coberto |
| `ssh_private_key_path` | string | `./.keys/<env>.pem` | onde a chave privada gerada é gravada (fora do versionamento). A chave também fica no state, como saída sensível, e `infra access` a regrava neste caminho quando o arquivo não existe (outra máquina, clone novo; 08, seção 5.6) |
| `bronze_bucket_name` | string | `null` | se `null`, segue a convenção `bucket-bronze-<id-da-conta>-<bronze_bucket_region>` |
| `bronze_bucket_region` | string | `us-east-1` | região do bucket bronze (pode diferir de `region`) |

### 3.7 Segredos manuais (sensíveis)
| Variável | Tipo | Padrão | Observação |
|---|---|---|---|
| `messaging_secrets` | map(string) | `{}` | segredos manuais do microsserviço, vindos do `secrets.env` pelo `infra` (05, A5). Desde a E8: `whapi_token`. **Só são exigidos quando `service_replicas.messaging > 0`** |
| `messaging_db_name` | string | `"temnafesta_notificacao"` | schema do microsserviço no mesmo RDS (E8, 05 B5); o mesmo que o script do schema cria |
| `messaging_db_schema_repo_url` | string | `""` | repositório público com o script do banco do microsserviço; **obrigatória com a mensageria ligada** (T16) |
| `messaging_db_schema_ref` | string | `""` | tag ou commit desse script; branch é recusada; **obrigatória com a mensageria ligada** (T16) |
| `messaging_db_schema_path` | string | `""` | caminho do script no repositório; **obrigatória com a mensageria ligada** (T16) |

- Marcada `sensitive = true`; nunca aparece em saída do Terraform. Mecanismo de entrega em 05.
- **Não são mais variáveis:** `dockerhub_username` e `dockerhub_token` (repositórios públicos, 07). As credenciais de publicação no Docker Hub existem só como *secrets* dos repositórios de aplicação no GitHub.
- **Gerados, não variáveis:** senhas do RDS, do usuário da aplicação e do RabbitMQ, `JWT_SECRET` e `messaging_api_key` (05, A1).

### 3.8 Variáveis sem valor padrão (*Decidido* em 10/10/2026, auditoria item 16)
Quatro variáveis não têm padrão porque o valor é seu e ainda não existe quando o contrato é escrito: `dockerhub_namespace`, `db_schema_repo_url`, `db_schema_ref` e `db_schema_path`. (`env` também não tem padrão, mas o `terraform.tfvars` de cada ambiente sempre a define como `dev` ou `prod`, nunca em branco.)
- **Em branco, nunca um valor inventado.** Os `terraform.tfvars` de `envs/dev` e `envs/prod` saem da E1 com essas quatro variáveis como `""`. Não há valores fictícios que pareçam reais.
- **O `plan` recusa o que estiver em branco e é exigido**, com mensagem em português que diz o que fazer, por exemplo: *"Preencha `dockerhub_namespace` em `envs/dev/terraform.tfvars` (usuário ou organização do Docker Hub)."* Todas as que faltam aparecem na mesma execução.
- **`db_schema_*` só são exigidas quando o banco nasce vazio**, isto é, quando `db_snapshot_identifier` é `null`. Com um snapshot (o final mais recente ou o de `--snapshot <id>`), as três podem ficar em branco e são ignoradas, porque a rotina do banco só baixa o script se o schema não tem tabelas (05, B5). Se estiverem preenchidas, são validadas do mesmo jeito (por exemplo, `db_schema_ref` não pode ser branch, T15). Como o `infra up` preenche `db_snapshot_identifier` **antes** do `plan` (04, seção 3, passo 7), a regra enxerga o snapshot escolhido; sem nenhum snapshot (primeira subida), as três são exigidas.
- **Exceção que o `plan` não enxerga:** um snapshot que tenha o schema vazio (o de um ambiente cujo `db-init` falhou, 05, B5) é aceito pelo `plan` com `db_schema_*` em branco; quem recusa, depois, é o `db-init`, com a mensagem de 04, seção 10, e a correção é preencher as três e rodar `infra up`, sem recriar nada.
- **Como é feito:** blocos `validation` que consultam `db_snapshot_identifier` (referência entre variáveis exige Terraform 1.9 ou superior; o contrato exige 1.11).
- **Os testes não dependem dos `tfvars`.** `terraform test` passa os próprios valores (T12 e T15) e `terraform validate` não avalia valores, então a E1 termina sem nenhuma dessas informações.
- **Quando o valor precisa existir:** antes do primeiro `infra up` com a raiz `envs/<env>` completa, que acontece na **E4a** (09, seção 2). As etapas anteriores (testes da E1, bootstrap da E2 e a rede da E3, que usa uma raiz temporária) não precisam deles.
- Quem rodar `terraform apply` direto passa pela mesma validação.

## 4. Orçamento de instâncias (referência do laboratório)
Com os padrões acima, na mesma região:
| Ambiente | Bastion | Web | App | Total |
|---|---|---|---|---|
| dev | 1 | 1 | 1 | 3 |
| prod | 1 | 2 | 3 | 6 |
| **dev + prod** | | | | **9** (no limite do laboratório) |

- O `ec2_instance_limit` protege **cada ambiente isoladamente** (teste T6).
- **A soma entre ambientes não é conferida** (decisão de 10/10/2026, 01 RES-06): a premissa é que, no laboratório, quem usa não sobe dev e prod juntos quando a soma passa do limite da região. Se alguém tentar e o limite for atingido, a AWS recusa a criação e o `apply` falha. O provisionamento segue permitindo os dois ao mesmo tempo, o que vale para contas fora do laboratório.
- Para ter dev e prod no ar juntos sem estourar o limite no laboratório, use regiões diferentes (por exemplo, dev em `us-west-2`): cada região tem 9 instâncias.
- Ainda a confirmar: se as instâncias do RDS contam no limite de 9 do laboratório (as fontes sugerem que não, por serem outro serviço). Será descoberto em E4b (09).

## 5. Valores derivados (não são variáveis)
| Valor | Regra |
|---|---|
| Prefixo de nomes | `<project_name>-<env>` (ex.: `tem-na-festa-dev`) |
| Nome de nó | `<prefixo>-web-<n>`, `<prefixo>-app-<n>` (n a partir de 1) e `<prefixo>-bastion`; é também o hostname do nó (04, seção 5). **O final do nome (`-web-<n>`, `-app-<n>`) é um contrato com o `converge.sh`**, que o usa para aplicar os rótulos (04, seção 7, passo 2): mudar o formato exige mudar a regra do script no mesmo PR |
| CIDR das subnets | `cidrsubnet(vpc_cidr, 3, n)` com n: pública AZ1 = 0, web AZ1 = 1, web AZ2 = 2, app AZ1 = 3, app AZ2 = 4, db AZ1 = 5, db AZ2 = 6, pública AZ2 = 7 |
| IP privado dos nós | fixo e determinístico: o nó de índice `i` de cada grupo recebe o host `10 + i` da subnet da sua AZ (o líder do Swarm tem endereço conhecido de antemão) |
| Papel de manager | os `manager_count` primeiros nós app, em ordem de índice |
| Nó do RabbitMQ e do microsserviço | o nó `app-1` (primeiro nó app), que recebe `rabbitmq=true` e `messaging=true` (02, A16) |
| Lista de nós esperados | os hostnames de todos os nós web e app planejados (`<prefixo>-web-1` … `<prefixo>-app-N`), em `EXPECTED_NODES` do `stack.env`; o bastion não entra, pois não é nó do Swarm |
| Id do ciclo | 8 caracteres hexadecimais (`random_id` de 4 bytes), gerados uma vez com o RDS do ambiente, guardados no state e perdidos com o ambiente; entram só no nome do snapshot final `<prefixo>-final-<id do ciclo>` (05, B2) |
| Rótulos Swarm | `tier=web` (nós web), `tier=app` (nós app), `rabbitmq=true` e `messaging=true` (só o `app-1`, sempre, mesmo com a mensageria desligada); aplicados pelo líder casando o **final** do hostname (04, seção 7, passo 2); não são gravados pelo Terraform |
| Prefixo de logs no bronze | `env=<env>/` |
| Referências de imagem | `<dockerhub_namespace>/tnf-<stack>:<image_tags.stack>` (a primeira subida); as seguintes são resolvidas por *digest* pelo líder (07, seção 5.2). A da mensageria só é usada com `service_replicas.messaging > 0` |
| `stack.env` | gravado pelo Terraform no bucket de artefatos com imagens iniciais, réplicas, endpoint do RDS, nome do banco, usuário da aplicação, `MESSAGING_PORT`, `EXPECTED_NODES`, `MANAGER_COUNT` e a origem do script do schema (`DB_SCHEMA_REPO_URL`, `DB_SCHEMA_REF`, `DB_SCHEMA_PATH`, copiados de `db_schema_*`, em branco quando há snapshot) (06, seção 4). Com a mensageria desligada, `IMAGE_MESSAGING` e `MESSAGING_PORT` são gravados mas ignorados |
| Nomes de buckets, parâmetros SSM, segredos Docker e stacks | ver 08, seção 4.2 |

## 6. Critérios de aceite: testes do contrato (casos que o `plan` deve rejeitar)
Automatizados com `terraform test` e provedor simulado, sem credenciais da AWS (07, seção 6; 08).
| # | Entrada | Resultado esperado |
|---|---|---|
| T1 | `env = "staging"` | erro: apenas `dev` ou `prod` |
| T2 | `region = "eu-west-1"` | erro: o laboratório só permite `us-east-1` e `us-west-2` |
| T3 | `az_count = 3` | erro: valores aceitos são 1 e 2 |
| T4 | `manager_count = 3`, `app_node_count = 2` | erro: managers não podem exceder os nós app |
| T5 | `manager_count = 2` | erro: número de managers deve ser ímpar (1, 3 ou 5) |
| T6 | `web_node_count = 5`, `app_node_count = 5` | erro: excede `ec2_instance_limit` |
| T7 | `app_instance_type = "t3.xlarge"` | erro: tamanho máximo `large` |
| T8 | `db_instance_class = "db.t3.large"` | erro: tamanho máximo `medium` |
| T9 | `admin_ssh_cidrs = ["0.0.0.0/0"]` (pelo `tfvars` ou pelo IP informado ao `infra`, `--ip`) | erro: SSH aberto para o mundo é proibido |
| T10 | `vpc_cidr = "10.0.0.0/16"` | erro: precisa ser `/21` |
| T11 | `db_allocated_storage_gb = 500` | erro: máximo 100 |
| T12 | todos os padrões de dev (mensageria desligada), mais `env = "dev"`, `dockerhub_namespace`, `db_schema_repo_url`, `db_schema_ref` e `db_schema_path`; e uma segunda execução com `db_snapshot_identifier` informado e as três `db_schema_*` em branco | `plan` válido com 3 instâncias nas duas execuções; o `stack.env` gerado traz `DB_SCHEMA_*` preenchidas na primeira e em branco na segunda |
| T13 | `ami_id` informado com `region` diferente da região da AMI | erro do provedor ao criar a instância; documentado como limitação do override (**não automatizável sem a AWS**: verificado no laboratório) |
| T14 | `service_replicas.backend = 2`, `app_node_count = 1` (e o análogo de `frontend` com `web_node_count`) | erro: réplicas não podem exceder o número de nós do grupo |
| T15 | (a) `db_schema_ref = "main"` (ou `master`, `develop`, `HEAD`), com ou sem `db_snapshot_identifier`; (b) `dockerhub_namespace = ""`; (c) `db_schema_repo_url`, `db_schema_ref` ou `db_schema_path` em branco com `db_snapshot_identifier = null` | (a) erro: informe uma tag ou um commit, não uma branch; (b) e (c) erro "Preencha `<variável>` em `envs/<env>/terraform.tfvars`" (3.8), listando todas as que faltam |
| T16 | `service_replicas.messaging = 1` com `messaging_port = null`, ou sem `messaging_db_schema_*` ou sem `whapi_token` em `messaging_secrets` (E8) | erro: informe o que falta ou deixe a mensageria desligada (`0`) |
| T17 | `service_replicas.frontend = 0` (ou `backend = 0`); e `service_replicas.messaging = 2` (com `app_node_count` suficiente) | erro: frontend e backend precisam de ao menos 1 réplica, e a mensageria só pode ter `0` ou `1` (3.4); só a mensageria pode ficar em `0` |

A regra de AMI da seção 3.3 (nós existentes não são substituídos por uma AMI mais nova) **não é um caso de rejeição do `plan`**: é verificada no laboratório por S2 (04), repetindo o `apply`, e conferida na revisão do código (`ignore_changes` nas três famílias de instância).
A regra de `manager_count` fixo (seção 3.2) também **não é do `plan`**: depende do que já foi aplicado e é verificada pelo `infra` antes do `apply` (08, G22; 04, S14).
A regra de `db_snapshot_identifier` (seção 3.5) também **não é um caso de rejeição**: é conferida na revisão do código (`ignore_changes = [snapshot_identifier]` no RDS) e no laboratório por Q21 (05).
A detecção do IP e a recuperação da chave (seção 3.6) são comportamento do `infra`, não do `plan`: verificadas por G24 e G25 (08).
O contrato do final do nome do nó (seção 5) é conferido no laboratório: R10 (06) e a E4a (09, `docker node inspect` mostra os rótulos nos nós certos) falham se a regra do `converge.sh` não casar com os nomes gerados pelo Terraform.

## 7. Pendências
- Configuração do microsserviço de mensageria (define `messaging_port`, as chaves de `messaging_secrets` e as variáveis do compose em 06, e se mais de uma réplica é segura, o que liberaria o limite de 3.4); só bloqueia a E8.
- Valores a preencher nos `terraform.tfvars` antes da E4a (3.8): `dockerhub_namespace`; caminho real do script dentro de `TEM-NA-FESTA-database` (`db_schema_path`), a URL do repositório (`db_schema_repo_url`) e a tag a usar em `db_schema_ref` (esta só se o banco for nascer vazio).
- Se as instâncias do RDS entram no limite de 9 do laboratório (teste no laboratório, 09, E4b).
- Itens da auditoria de 10/10/2026 que ainda alteram este documento (ver 00): nenhum.
