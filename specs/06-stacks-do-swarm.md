# 06 – Stacks do Swarm (compose files)

Estado: **aprovado** (09/10/2026); ajustado em 10/10/2026 (frontend em `stop-first`, auditoria item 1; mensageria desligada com `REPLICAS_MESSAGING=0`, auditoria item 3; `stack.env` com `EXPECTED_NODES` e `MANAGER_COUNT`, auditoria item 11; mensageria com no máximo 1 réplica e `max_replicas_per_node: 1`, auditoria item 13; verificação de saúde com `wget` e `curl` de reserva, `VITE_*` vindos de variáveis do repositório, auditoria item 14; mensageria fixada no `app-1` por rótulo e regra do pareamento do WhatsApp com sessão, seção 6.4.1, E15 e R17, auditoria item 19) e em 11/10/2026 (`stack.env` com `DB_SCHEMA_REPO_URL`, `DB_SCHEMA_REF` e `DB_SCHEMA_PATH`, para o `db-init` do líder baixar o script do schema, seção 4 e E12, auditoria item 22). O microsserviço de mensageria está **PENDENTE** (aguarda a configuração dele): aqui ele aparece só como esqueleto, fica **desligado até a E8**, e tudo o que depende dele está marcado.
Depende de: 02 (serviços e posicionamento), 03 (`service_replicas`, `image_tags`), 04 (convergência), 05 (segredos), 07 (CI/CD e imagens).

## 1. Escopo
Define **o que roda dentro do Swarm**: as stacks, os serviços, a rede, o posicionamento, os segredos, as verificações de saúde, a política de atualização e os limites de memória. O que cria o Swarm e dispara o deploy está em 04; como as imagens chegam ao Docker Hub, em 07.

## 2. Stacks e ordem de deploy (*Decidido*)
| Ordem | Stack | Serviços | Onde roda |
|---|---|---|---|
| 1 | `tnf-rabbitmq` | `rabbitmq` | 1 nó `app` com o rótulo `rabbitmq=true` |
| 2 | `tnf-app` | `backend-som` e, **quando ligada**, `messaging` (PENDENTE) | nós `app`; a `messaging` só no nó com o rótulo `messaging=true` (o `app-1`, 6.4) |
| 3 | `tnf-web` | `frontend` | nós `web` |

- Uma stack por conjunto que muda em ritmo próprio: dá para atualizar o frontend sem encostar no backend (RF-09, tags separadas por stack).
- O frontend sobe por último porque o nginx resolve `backend-som` quando inicia (04, seção 7).
- Na prática os nomes no Swarm ganham o prefixo da stack (`tnf-app_backend-som`). O nome curto (`backend-som`, `messaging`) continua valendo **dentro da rede**, por um apelido explícito (seção 3).

### Mensageria desligada (*Decidido* em 10/10/2026, E11)
A imagem `tnf-messaging` só existe a partir da E8 (09). Até lá, `service_replicas.messaging = 0` (03, seção 3.4) e vale o seguinte:
- O compose da `tnf-app` fica em **dois arquivos estáticos**: `stacks/app.yml` (só o `backend-som`) e `stacks/app-messaging.yml` (só o `messaging`). O líder passa `-c app.yml` sempre e **acrescenta** `-c app-messaging.yml` somente quando `REPLICAS_MESSAGING > 0`. O `docker stack deploy` da `tnf-app` usa `--prune`: ao voltar para `0`, o serviço `messaging` é removido; a opção só atua sobre serviços da própria stack.
- Com `0`, a imagem não é resolvida nem baixada (04, seção 7, passo 7), `IMAGE_MESSAGING` e `MESSAGING_PORT` do `stack.env` são ignorados e `converge.json` mostra a mensageria como `off`.
- O RabbitMQ **não depende** do interruptor: continua implantado (imagem oficial, sem pendência de imagem própria). Em dev, ele ocupa memória mesmo sem consumidor (seção 8).
- O backend continua recebendo `MESSAGING_URL` e o segredo `MESSAGING_API_KEY`: o nome `messaging` simplesmente não resolve enquanto o serviço está desligado. É inofensivo hoje (o backend ainda não usa a integração) e, quando usar, vale a regra de 6.5 (falha do aviso não derruba a operação principal).

### Quem fala com quem (*Decidido* pelo autor)
```
cliente → ALB → frontend (nginx) → backend-som ──(envia eventos)──> messaging ──> RabbitMQ
                                        │                              │
                                        └──> RDS                       └──> WhatsApp (saída pela NAT)
```
- **Só o microsserviço usa o RabbitMQ.** O backend não se conecta a ele: apenas **envia eventos ao microsserviço**. Por isso o backend não recebe nenhum segredo do RabbitMQ.
- **Essa integração ainda não existe no backend** (informado pelo autor). A infra não a implementa (novas funcionalidades estão fora do escopo), mas **fixa o contrato** que o backend e o microsserviço devem seguir quando forem escritos (seção 6.5).

## 3. Rede (*Decidido*)
- Uma rede overlay única, **`tnf-net`**, criada pelo líder antes das stacks e usada por todas como rede externa. Todos os serviços se encontram pelo nome, entre nós web e app.
- Criptografia da rede overlay: **desligada** (o tráfego já corre dentro da VPC privada e a criptografia consome CPU em `t3.micro`). Pode ser ligada depois sem mudar os compose files.
- Apelidos de rede explícitos: `backend-som` no backend (nome exigido pelo `proxy_pass http://backend-som:8080/api/` do nginx atual) e `messaging` no microsserviço (o backend o usará para enviar eventos).
- **Firewall:** o tráfego do overlay (7946/tcp+udp, 4789/udp, 2377/tcp) passa **entre** os nós web e app (02, seção 5, decisão A11). Verificado pelo teste R3.

## 4. Como os compose files recebem valores (*Decidido*)
- Os compose files são **estáticos** (iguais em dev e prod, versionados em `stacks/`). Os valores que mudam por ambiente entram por **substituição de variáveis** do `docker stack deploy`, lidas de um arquivo de valores.
- O Terraform grava no bucket de artefatos o **`stack.env`**, sem segredos: `IMAGE_FRONTEND`, `IMAGE_BACKEND`, `IMAGE_MESSAGING` (imagens iniciais, de `image_tags`), `REPLICAS_FRONTEND`, `REPLICAS_BACKEND`, `REPLICAS_MESSAGING` (`0` = desligada), `DB_ENDPOINT` (endereço do RDS), `DB_NAME`, `DB_USER`, `MESSAGING_PORT` (valor **PENDENTE**, vem da configuração do microsserviço; vazio enquanto a mensageria estiver desligada).
- **Cinco valores não são usados pelos compose files**; servem ao líder e ao `infra` (auditoria itens 11 e 22): `EXPECTED_NODES` (lista, separada por vírgulas, dos hostnames dos nós do Swarm que devem existir, sem o bastion; 03, seção 5) e `MANAGER_COUNT` (quantos desses nós são managers). O líder usa o primeiro para esperar os nós e remover os que saíram do desenho (04, seção 7, passo 1); o `infra up` usa o segundo para recusar a mudança de `manager_count` com o ambiente no ar (03, seção 3.2; 08, G22). Os outros três, `DB_SCHEMA_REPO_URL`, `DB_SCHEMA_REF` e `DB_SCHEMA_PATH` (vindos de `db_schema_*`, 03, seção 3.5), dizem ao `db-init` do líder qual script do schema baixar (04, seção 7, passo 6; 05, B5); ficam em branco quando o banco nasce de um snapshot. Como o compose não referencia nenhum deles, o `docker stack deploy` os ignora.
- O **líder gera localmente** o arquivo efetivo de cada deploy: copia o `stack.env` e troca as imagens dos serviços ligados por referências fixadas por *digest* (`<repo>:<tag>@sha256:…`), resolvidas no Docker Hub (07, seção 5.2). Por isso o compose não usa `--resolve-image` nem `--with-registry-auth` (repositórios públicos).
- O manifesto de 04 (hash do conjunto) cobre também `stack.env`, então mudar réplicas, tag ou a contagem de nós e rodar `infra up` continua refazendo o deploy sozinho.
- Por quê: um compose sem formato de template é mais fácil de ler e de testar localmente; o Terraform só renderiza um arquivo plano de variáveis, e não YAML.
- *Validar na primeira subida:* a substituição de `replicas: ${REPLICAS_BACKEND}` como número (esperado funcionar).
- Os `VITE_*` do frontend **não passam por aqui**: são valores de build, gravados na imagem (07, 4.4), e não variáveis do `stack.env`.

## 5. Segredos e configurações (liga com 05)
Cada segredo tem três nomes ao longo do caminho:
| Parâmetro SSM (`/tnf/<env>/secrets/…`) | Segredo Docker | Arquivo dentro do container | Serviço |
|---|---|---|---|
| `db_password` | `tnf_db_password` | `/run/secrets/DB_PASSWORD` | backend |
| `jwt_secret` | `tnf_jwt_secret` | `/run/secrets/JWT_SECRET` | backend |
| `rabbitmq_user` | `tnf_rabbitmq_user` | `/run/secrets/rabbitmq_user` | RabbitMQ e microsserviço |
| `rabbitmq_password` | `tnf_rabbitmq_password` | `/run/secrets/rabbitmq_password` | RabbitMQ e microsserviço |
| `messaging_api_key` | `tnf_messaging_api_key` | backend: `/run/secrets/MESSAGING_API_KEY`; microsserviço: nome **PENDENTE** | backend e microsserviço |
| *(chaves de `messaging_secrets`)* | `tnf_<chave>` | **PENDENTE** | microsserviço (só existem com a mensageria ligada) |

- O `target` do segredo no compose é o nome do arquivo em maiúsculas para o backend, para o `configtree` do Spring (05, A3) criar as propriedades `DB_PASSWORD`, `JWT_SECRET` e `MESSAGING_API_KEY`, no mesmo estilo dos placeholders atuais.
- **Cada serviço monta só os segredos de que precisa.** Como o backend lê *todos* os arquivos de `/run/secrets/` como propriedades, não se monta nele nada que não seja dele.
- O compose só declara os segredos como **externos** (criados pelo líder, 04 passo 5), nunca valores.
- Configuração sem segredo vem de `stack.env`: `DB_URL` é montada no compose como `jdbc:mysql://${DB_ENDPOINT}:3306/${DB_NAME}?allowPublicKeyRetrieval=true&useSSL=false&serverTimezone=UTC` (os parâmetros da URL atual; `useSSL=false` mantido por estar dentro da VPC privada; *a rever se quiser TLS até o RDS*), e `DB_USER`, `PORT=8080`.
- A **sessão do WhatsApp**, quando o microsserviço a usa (6.4.1), **não é um segredo da infra**: é gerada pelo próprio microsserviço no pareamento e fica só no volume local; não passa por SSM, S3 nem segredo Docker (05, A1 e A6).

## 6. Serviços

### 6.1 `frontend` (nginx + React)
| Item | Valor |
|---|---|
| Imagem | `${IMAGE_FRONTEND}` (o `nginx.conf` e as variáveis `VITE_*` já vão **dentro da imagem**, definidos no build a partir das variáveis do repositório do frontend, 07 seção 4.4; a infra não os altera) |
| Posicionamento | `node.labels.tier == web`, no máximo 1 réplica por nó |
| Porta | publica **80** (modo *ingress*, routing mesh); o ALB aponta para a porta 80 dos nós web (02, seção 5) |
| Rede | `tnf-net` |
| Réplicas | `${REPLICAS_FRONTEND}` (dev 1, prod 2) |
| Saúde | requisição HTTP a `http://127.0.0.1/` esperando 200; intervalo 15 s, 3 falhas, período de partida 10 s. Comando (*Decidido* em 10/10/2026): `CMD-SHELL` com `wget -q -O /dev/null http://127.0.0.1/ \|\| curl -fsS -o /dev/null http://127.0.0.1/`, ou seja, tenta o `wget` e, se não der certo, o `curl`. A imagem precisa ter pelo menos um dos dois (07, 4.4; C17). Usa-se `127.0.0.1` e não `localhost` porque o `wget` do Alpine pode resolver `localhost` para IPv6, e o nginx do `nginx.conf` atual escuta só em IPv4 |
| Atualização | uma réplica por vez, **derrubar a antiga antes de subir a nova** (`stop-first`), esperar a nova ficar saudável antes de passar à próxima, rollback automático se falhar |
| Limite de memória | 128 MB |
- **Por que `stop-first` (*Decidido* em 10/10/2026):** com `start-first` e `max_replicas_per_node: 1`, o Swarm não tem onde colocar a réplica nova enquanto a antiga ainda ocupa o nó (réplicas = nós no padrão), e a atualização trava com "max replicas per node limit exceed" ([moby/moby #40797](https://github.com/moby/moby/issues/40797), ainda aberto). Em prod (2 réplicas em 2 nós), uma atende pelo *routing mesh* enquanto a outra atualiza, sem indisponibilidade. Em dev (1 réplica), há uma pausa de alguns segundos no deploy, aceitável. O nginx é leve e reinicia rápido.
- O ALB usa `GET /` como verificação (devolve o `index.html`, 200).
- *Validar:* os logs do nginx precisam sair em stdout/stderr para o Fluent Bit ler pelo Docker. A imagem oficial do nginx faz isso ligando `/var/log/nginx/access.log` a stdout; o `nginx.conf` atual já usa esse caminho, então só vale se a imagem for baseada na oficial.

### 6.2 `backend-som` (Spring Boot)
| Item | Valor |
|---|---|
| Imagem | `${IMAGE_BACKEND}` |
| Posicionamento | `node.labels.tier == app`, no máximo 1 réplica por nó |
| Porta | **não publica** nada no host; só `8080` dentro da rede `tnf-net` |
| Variáveis | `DB_URL`, `DB_USER`, `PORT=8080`, `SPRING_CONFIG_IMPORT=optional:configtree:/run/secrets/`, `MESSAGING_URL=http://messaging:${MESSAGING_PORT}` (6.5) |
| Segredos | `db_password`, `jwt_secret`, `messaging_api_key`; nenhum do RabbitMQ |
| Réplicas | `${REPLICAS_BACKEND}` (dev 1, prod 2) |
| Saúde | Comando (*Decidido* em 10/10/2026): `CMD-SHELL` com `wget -q -O /dev/null http://127.0.0.1:8080<caminho> \|\| curl -fsS -o /dev/null http://127.0.0.1:8080<caminho>`, esperando 200; a imagem precisa ter `wget` ou `curl` (07, 4.4; C17). **PENDENTE** o `<caminho>`: precisa de um endpoint HTTP que responda 200 quando a aplicação está pronta e conectada ao banco (por exemplo `/actuator/health`; ver pendências) |
| Atualização | uma réplica por vez, **derrubar a antiga antes de subir a nova** (`stop-first`), rollback automático se não ficar saudável em 60 s |
| Limite de memória | 768 MB, com reserva de 512 MB; a JVM é limitada por `JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=70` |
- Por que `stop-first` no backend: com duas JVMs ao mesmo tempo, um nó `t3.small` (2 GB) estoura a memória (e, como no frontend, `start-first` não funcionaria com `max_replicas_per_node: 1`). Com 2 réplicas em nós diferentes (prod), uma atende enquanto a outra atualiza, então não há indisponibilidade. Com 1 réplica (dev), há uma interrupção curta durante o deploy, aceitável.
- Tempo de partida do Spring Boot em `t3.small`: esperam-se 40 a 90 s, por isso o período de partida da verificação de saúde é longo (90 s).
- O backend **não deve depender** de o microsserviço estar de pé para iniciar ou para ficar saudável (a verificação de saúde não consulta o microsserviço). Isso é o que permite a mensageria desligada.
- Enquanto o backend não ler `MESSAGING_URL` e `MESSAGING_API_KEY`, as duas entradas são inofensivas: o Spring ignora propriedades que o código não usa.

### 6.3 `rabbitmq`
| Item | Valor |
|---|---|
| Imagem | `rabbitmq` série 4.x, sem o plugin de gerenciamento (versão exata fixada na implementação) |
| Posicionamento | `node.labels.rabbitmq == true` (o nó `app-1`), 1 réplica |
| Nome do host | **fixo**: `hostname: rabbitmq` e `RABBITMQ_NODENAME=rabbit@rabbitmq` |
| Volume | volume local nomeado `rabbitmq_data` em `/var/lib/rabbitmq` |
| Porta | só `5672` dentro da rede `tnf-net`; sem publicação. Usada **apenas pelo microsserviço** |
| Usuário e senha | `RABBITMQ_DEFAULT_USER_FILE` e `RABBITMQ_DEFAULT_PASS_FILE` apontando para os segredos Docker |
| Filas e permissões | arquivo `definitions.json` carregado na inicialização (`load_definitions` em `rabbitmq.conf`), entregue como *config* do Docker. Lista de filas **PENDENTE** (depende do microsserviço) |
| Saúde | `rabbitmq-diagnostics -q ping`; intervalo 30 s, período de partida 60 s |
| Atualização | `stop-first` (instância única com volume) |
| Limite de memória | 512 MB |
- **Por que o nome do host fixo:** o RabbitMQ grava seus dados em uma pasta com o nome do host. No Swarm, cada novo container recebe um nome de host diferente, e sem fixá-lo as mensagens e filas "somem" depois de um reinício do container (ficam num diretório de outro nome). Isto é o que torna a persistência de P1 (02) real.
- O usuário padrão é criado quando o volume nasce; o `definitions.json` **não define usuários** (evita uma senha em arquivo), só filas, trocas e vínculos.
- O nome do *config* leva o hash do conteúdo (por exemplo `rabbitmq_definitions_<hash>`), porque o Docker não permite alterar um *config* existente; mudou o arquivo, muda o nome e o serviço é atualizado.
- Painel de gerenciamento (interface web): fora do escopo agora; entra junto com a observabilidade.

### 6.4 `messaging` (microsserviço de WhatsApp) — **PENDENTE**, desligado até a E8
Esqueleto, sem valores; fica em `stacks/app-messaging.yml` (seção 2):
| Item | Valor |
|---|---|
| Imagem | `${IMAGE_MESSAGING}` |
| Posicionamento | `node.labels.tier == app` **e** `node.labels.messaging == true` (*Decidido* em 10/10/2026, item 19): o rótulo `messaging=true` fica sempre no nó `app-1`, o mesmo do RabbitMQ (04, seção 7, passo 2), e **`max_replicas_per_node: 1`** |
| Rede | `tnf-net` com o apelido `messaging`; sai para o WhatsApp pela NAT; **recebe os eventos do backend** na porta `${MESSAGING_PORT}` (sem publicação no host) |
| Réplicas | `${REPLICAS_MESSAGING}`: `0` = desligado (padrão até a E8); `1` na E8. **No máximo 1** (*Decidido* em 10/10/2026, 03 seção 3.4, T17): ainda não se sabe se mais de uma réplica é segura, pois um consumidor de WhatsApp com sessão pode duplicar envios; o `plan` recusa valores maiores. O limite de 1 por nó fica no compose só como ajuste de desenho, caso o valor seja liberado depois |
| Volume | `messaging_session`: volume local nomeado no `app-1`, **só se o microsserviço guarda a sessão do WhatsApp em disco** (6.4.1). Caminho de montagem **PENDENTE** (vem da configuração do microsserviço) |
| Segredos e variáveis | RabbitMQ (usuário e senha), `messaging_api_key` (se adotado), as chaves de `messaging_secrets` e as variáveis de conexão: **PENDENTE** |
| Saúde, memória | **PENDENTE** (a verificação seguirá o formato de 6.1 e 6.2 se a imagem tiver `wget` ou `curl`). A memória é medida na E8 junto com o RabbitMQ e o backend no mesmo nó (seção 8) |
| Atualização | `stop-first` (*Decidido* para o caso com sessão: duas instâncias com a mesma sessão do WhatsApp ao mesmo tempo disputariam o login) e `stop_grace_period` de 30 s para o serviço gravar a sessão ao parar (valor a confirmar na E8) |
- **Por que o rótulo `messaging=true` existe sempre (*Decidido*):** o rótulo é aplicado pelo líder mesmo com a mensageria desligada (custo nenhum). Com ele, o serviço sempre volta ao mesmo nó e, se houver sessão em volume local, o volume está lá. Sem ele, o Swarm poderia reagendar o serviço em outro nó app e a sessão ficaria para trás. O rótulo reaproveita o padrão do RabbitMQ (nó fixo e volume local, P1 em 02).
- **Trade-off aceito:** no `app-1` passam a conviver o RabbitMQ, uma réplica do backend e o microsserviço (seção 8). Se faltar memória, a saída é `app_instance_type = t3.medium`, como já previsto.

#### 6.4.1 Sessão e pareamento do WhatsApp (*Decidido* em 10/10/2026, auditoria item 19)
**O problema.** O "nível 4" (01, RF-02) promete um ambiente que sobe sem intervenção. Um microsserviço de WhatsApp que usa uma biblioteca com sessão (por exemplo `whatsapp-web.js` ou Baileys) exige que alguém **pareie** o aparelho uma vez: escanear um QR code (ou digitar um código de pareamento) com o celular. Depois do pareamento, a sessão fica em arquivos no disco. Se o microsserviço usa a API oficial da Meta (token), não há pareamento. Qual dos dois é o caso depende da configuração do microsserviço (**PENDENTE**); a regra abaixo cobre os dois.

**Regra geral.** O nível 4 vale **até o serviço estar de pé**. O pareamento do WhatsApp, quando existe, é uma **exceção declarada**: um passo manual, único por ambiente novo, documentado no README (E8, 09) e **não automatizado**. O `converge.json` e o `infra status` **não sabem** se o WhatsApp está pareado: `ready` significa que as réplicas estão de pé, não que há mensagens saindo.

| Caso | O que a infra faz |
|---|---|
| **A – Biblioteca com sessão em disco** | Serviço fixado no `app-1` (6.4). Volume local `messaging_session` montado no caminho em que o microsserviço grava a sessão. Pareamento manual a cada ambiente novo (abaixo). Sem cópia da sessão em SSM, S3 ou state |
| **B – API oficial (token)** | Nada de especial: sem pareamento, sem volume. Os tokens entram por `messaging_secrets` (05, A5). O serviço fica fixado no `app-1` por causa do rótulo, sem efeito prático |
| **C – Sessão guardada fora do disco** (por exemplo, no banco) | Tratado como o caso B para a infra; o microsserviço cuida da própria sessão |

**Procedimento de pareamento (caso A).** Com a mensageria ligada e o `infra up` concluído:
1. `infra ssh <env> app-1` (02, seção 8).
2. No nó: `docker service logs -f tnf-app_messaging`.
3. No celular: WhatsApp → Aparelhos conectados → Conectar um aparelho. Escanear o QR code que o microsserviço imprime no log (ele se renova sozinho em poucos segundos), ou digitar o código de pareamento, se o microsserviço oferecer essa forma.
4. Esperar a mensagem de "conectado" nos logs (texto exato **PENDENTE**, vem da configuração do microsserviço).
5. Depois disso, reiniciar, atualizar ou reagendar o serviço **não** pede novo pareamento (a sessão está no volume).

**Quando o pareamento precisa ser refeito.**
- Ambiente novo (`infra down` e `infra up`): o volume morre com o nó (consequência aceita, como as mensagens do RabbitMQ em 05, B1). O banco **não** é afetado, pois volta pelo snapshot.
- O nó `app-1` é recriado, ou o volume é apagado.
- A sessão é encerrada pelo celular (desconectar o aparelho) ou invalidada pelo WhatsApp.
- No celular, os aparelhos conectados de ambientes destruídos continuam listados até expirarem ou serem removidos à mão; remova-os para não acumular.

**O que acontece antes do pareamento.** O microsserviço fica de pé, mas não envia. O backend não é afetado (6.5: falha do aviso não derruba a operação principal). O destino dos eventos recebidos nesse período depende do microsserviço (**PENDENTE**); a recomendação é que fiquem na fila do RabbitMQ até o envio ser possível.

**Segurança.**
- Os arquivos da sessão equivalem a uma credencial da conta de WhatsApp: ficam **só no volume local**, nunca em SSM, S3 de artefatos, state, logs ou imagem; **não há backup** (05, A6 e Q23).
- O QR code ou código de pareamento aparece nos logs do container e, portanto, também no bronze (origem `docker`, 02, seção 7.1). É de vida curta e inútil depois do pareamento; fica registrado como risco conhecido.
- Quem tem SSH no `app-1` lê a sessão por definição (é o acesso previsto, 02, seção 8).

**Número de WhatsApp por ambiente.** Recomenda-se um **número de teste no dev**, para que mensagens de teste não cheguem a clientes reais e para não arriscar o número de produção. Bibliotecas não oficiais de WhatsApp podem levar o WhatsApp a restringir o número; é um risco do produto e fora da infra. A escolha dos números é do autor e entra na configuração do microsserviço (**PENDENTE**).

**Alternativa descartada (por ora): guardar a sessão no S3 e restaurá-la a cada ambiente novo, sem QR.** Exigiria mudar o microsserviço ou criar um processo auxiliar, poria uma credencial sensível no S3 e, com dois ambientes restaurando a mesma sessão, arrisca disputa e bloqueio do número. Só se reavalia se o pareamento a cada ciclo se tornar um problema real, com uma nova decisão.

**Verificação:** R17 (09, E8) e Q23 (05).

### 6.5 Contrato de integração backend → microsserviço (*Decidido*; porta e detalhes do microsserviço pendentes)
Como o backend ainda não envia eventos, o que a infra garante desde já é o seguinte; o desenvolvimento dos dois lados deve seguir isso (ou propor outra coisa, que muda este item):
| Aspecto | Contrato |
|---|---|
| Meio | **chamada HTTP** do backend ao microsserviço, pela rede `tnf-net`. Faz sentido porque o backend não usa o RabbitMQ (E9) e o RabbitMQ fica como detalhe interno do microsserviço |
| Endereço | variável **`MESSAGING_URL`** = `http://messaging:<porta>`, entregue pela infra. O backend lê `${MESSAGING_URL}` como já lê `${DB_URL}` |
| Porta | `MESSAGING_PORT`, **definida pela configuração do microsserviço** (pendente) |
| Autenticação | segredo compartilhado **`MESSAGING_API_KEY`**, gerado pelo Terraform (um por ambiente) e entregue aos dois. O backend o envia em um cabeçalho e o microsserviço o confere. Motivo: todos os serviços (inclusive o frontend) estão na mesma rede, e a chave impede que outro container dispare mensagens de WhatsApp. É opcional: se o microsserviço não validar, o segredo sobra sem efeito |
| Falha do microsserviço | recomendação para o backend: tempo limite curto na chamada e **não falhar a operação principal** (por exemplo, a criação do pedido) se o aviso não puder ser enviado; registrar o erro no log. Vale também com a mensageria desligada (o nome não resolve) e com o WhatsApp ainda não pareado (6.4.1). Reentrega de eventos perdidos (fila no backend ou tabela de eventos) é decisão da aplicação e **está fora do escopo da infra**. Limitação registrada: um evento enviado enquanto o microsserviço está fora do ar se perde, porque o RabbitMQ só protege o que já entrou no microsserviço |
- **Tarefa fora da infra:** implementar o envio de eventos no backend e o recebimento no microsserviço.

## 7. Política geral dos serviços (*Decidido*)
- Reinício: `condition: any`, espera de 5 s entre tentativas, sem limite de tentativas (o ambiente é de curta duração e o Swarm deve insistir).
- Logs: driver `json-file` com rotação (configurada no daemon em 04). Para o Fluent Bit saber de qual serviço veio cada linha, o daemon inclui nos logs os rótulos `com.docker.swarm.service.name` e `com.docker.stack.namespace` (04, seção 5, passo 2).
- Máx. 1 réplica por nó para frontend e backend (`max_replicas_per_node: 1`): evita duas réplicas no mesmo nó, o que anularia a redundância. Consequência: `réplicas ≤ nós do grupo`, validada no `plan` (T14, 03). Sem isso, a réplica que não coubesse ficaria "pendente" para sempre. **Consequência para as atualizações:** como esse limite impede `start-first` (6.1), os dois serviços atualizam em `stop-first`. A mensageria tem no máximo 1 réplica (6.4), então a regra de réplicas por nó não se aplica a ela na prática, e o RabbitMQ é uma instância única fixada em um nó.
- O Swarm distribui as réplicas pelos nós, mas **não conhece as AZs**: o rodízio de 03 já coloca os nós em AZs diferentes; com 2 réplicas e 2 nós, cada uma fica em uma AZ. Posicionamento por AZ explícito fica fora do escopo.

## 8. Memória prevista por nó (`t3.small` de 2 GB)
| Cenário | Backend | RabbitMQ | Messaging | Sistema, Docker, Fluent Bit | Total aproximado |
|---|---|---|---|---|---|
| dev (1 nó app com tudo) | 768 MB | 512 MB | desligada até a E8; depois, a definir | ~400 MB | **~1,7 GB** com a mensageria desligada: apertado; **+ messaging** depois da E8 |
| prod (3 nós app) | 768 MB | 512 MB (só `app-1`) | desligada até a E8; depois, a definir (**sempre no `app-1`**, 6.4) | ~400 MB | folgado fora do `app-1`; o `app-1` fica como o dev se o Swarm também colocar ali uma réplica do backend |
- Em dev tudo cai no `app-1`. Se faltar memória, a saída é aumentar `app_instance_type` para `t3.medium` (variável), sem mudar o desenho. Será medido na primeira subida (09, E6) e de novo na E8, com a mensageria ligada.
- Como a mensageria fica sempre no `app-1` (6.4), é nesse nó que a medição da E8 importa.

## 9. Mudanças em outros specs (aplicadas na consolidação de 09/10/2026)
| Spec | Mudança |
|---|---|
| 02, seção 5 | Regras dos security groups com o tráfego do overlay entre web e app (A11) |
| 03 | Validação T14 (réplicas ≤ nós); `messaging_port`; (10/10/2026) `service_replicas.messaging = 0`, T16 e T17; (10/10/2026) `EXPECTED_NODES` e `MANAGER_COUNT` no `stack.env` e regras de mudança da contagem de nós (seções 3.2 e 5); (10/10/2026) `messaging` só com 0 ou 1 réplica (seção 3.4 e T17) |
| 04 | Rede `tnf-net`, `stack.env`, rótulos de log do daemon, resolução por *digest* e deploy das stacks (seções 4, 5, 7); (10/10/2026) passos 7 a 9 com serviço desligado; (10/10/2026) passo 1 da convergência com nós esperados e remoção de workers que saíram; (10/10/2026, item 19) rótulo `messaging=true` no passo 2 e `ready` sem relação com o pareamento (passo 9, D21); (11/10/2026, item 21) rótulos pelo final do hostname (passo 2, D22); (11/10/2026, item 22) passo 6 do `db-init` com marcadores `started` e `failed`, limpeza do schema e `DB_SCHEMA_*` lidas do `stack.env` (D23) |
| 05 | `messaging_api_key`; mapeamento de nomes de segredos; (11/10/2026, item 22) usuário da aplicação sem `DROP`, limpeza e nova tentativa do script do schema (A4, B5, Q11 a Q13, Q24); (10/10/2026) sem segredo manual com a mensageria desligada; (10/10/2026, item 19) sessão do WhatsApp fora de SSM e S3, B1 e Q23 |
| 07 | (10/10/2026) `Dockerfile` na raiz, `VITE_*` como variáveis do repositório do frontend e ferramenta de saúde nas imagens (seções 4.2, 4.3 e 4.4; C15 a C17; F10) |
| 01 e 02 | (10/10/2026, item 19) exceção declarada ao nível 4 (01, RF-02 e critério 2); rótulo `messaging=true` e A16 (02) |
| 09 | (10/10/2026, item 19) E4a (rótulos), E8 (pareamento, R17, Q23), pré-requisito, riscos e I9 |

## 10. Critérios de aceite
"Todas as réplicas" significa as dos **serviços ligados**; com a mensageria desligada, `tnf-app` tem só o `backend-som`.
| # | Cenário | Esperado |
|---|---|---|
| R1 | Subida do zero | as três stacks ficam com todas as réplicas dos serviços ligados em execução, na ordem RabbitMQ, app, web |
| R2 | `GET /` e `GET /api/...` pelo ALB | `/` devolve o front; `/api/` chega ao backend (qualquer resposta HTTP do backend, mesmo 401) |
| R3 | Do nó web, resolver e acessar `backend-som:8080` pela rede `tnf-net` | funciona (o tráfego do overlay passa entre web e app) |
| R4 | Tentar acessar a porta 8080, a do microsserviço (quando ligado) ou 5672 de fora da rede | não acessível |
| R5 | Reiniciar o container do RabbitMQ (`docker service update --force`) | filas e mensagens pendentes continuam lá |
| R6 | `docker inspect` dos serviços | nenhum segredo em variáveis de ambiente; o backend só tem seus próprios segredos em `/run/secrets` |
| R7 | Prod com 2 réplicas do backend e do frontend: publicar uma imagem nova de cada um e fazer o deploy, com requisições contínuas ao ALB | nenhuma resposta 5xx durante a atualização, e a atualização termina (não fica parada por causa do limite de réplicas por nó) |
| R8 | Publicar uma imagem do backend que não sobe | o Swarm reverte para a versão anterior sozinho |
| R9 | `service_replicas.backend = 2` com `app_node_count = 1` | rejeitado no `plan` (T14) |
| R10 | Cada serviço no seu grupo de nós | frontend só em `tier=web`; backend em `tier=app`; mensageria (quando ligada) só no nó `messaging=true` (o `app-1`); RabbitMQ só no nó `rabbitmq=true` |
| R11 | Logs de um container chegam ao bronze | linha com o nome do serviço no registro |
| R12 | **Com a mensageria ligada (E8):** dentro do container do backend, conferir `MESSAGING_URL` e o arquivo `/run/secrets/MESSAGING_API_KEY`; resolver `messaging` pela rede | variável e segredo presentes; o nome resolve; o backend não tem segredos do RabbitMQ *(a chamada real só pode ser testada quando a integração existir)*. Com a mensageria desligada, variável e segredo estão presentes e o nome **não** resolve |
| R13 | Dev com 1 réplica de frontend: publicar uma imagem nova e fazer o deploy | a atualização termina; uma pausa curta é esperada e aceita |
| R14 | Com o ambiente no ar, mudar `service_replicas.messaging` de `0` para `1` (imagem publicada, `messaging_port` informada), rodar `infra up`, e depois voltar para `0` e rodar `infra up` | ao ligar, em até 3 min o serviço `messaging` existe, com o *digest* da etiqueta e todas as réplicas; ao desligar, em até 3 min o serviço é removido da `tnf-app`, `backend-som`, RabbitMQ e frontend ficam intactos e `converge.json` volta a `ready` com a mensageria `off` |
| R15 | `service_replicas.messaging = 2` (com nós app suficientes) | rejeitado no `plan` com a mensagem de 03, seção 3.4 (T17) |
| R16 | Com o ambiente no ar, `docker service ps` do `frontend` e do `backend-som` | as réplicas aparecem como saudáveis (*healthy*) usando o comando de saúde de 6.1 e 6.2; parar o nginx dentro de um container faz o Swarm reiniciá-lo |
| R17 | **Com a mensageria ligada (E8).** Se o microsserviço guarda a sessão em disco (caso A, 6.4.1): **(a)** `docker service ps tnf-app_messaging` mostra o serviço no `app-1`; **(b)** fazer o pareamento pelo procedimento de 6.4.1; **(c)** `docker service update --force tnf-app_messaging` e esperar o serviço voltar; **(d)** `infra down` e `infra up` no ambiente. Nos casos B e C: registrar "não se aplica" e conferir só (a) | **(a)** o nó é o `app-1`; **(b)** o log mostra o WhatsApp conectado; **(c)** volta conectado, **sem novo QR code**; **(d)** o ambiente novo pede um novo pareamento (comportamento aceito, 6.4.1) e o banco volta pelo snapshot |

## 11. Decisões
| # | Decisão | Situação |
|---|---|---|
| E1 | Três stacks (`tnf-rabbitmq`, `tnf-app`, `tnf-web`) nessa ordem | **Decidido** |
| E2 | Rede overlay única `tnf-net`, sem criptografia, com apelidos `backend-som` e `messaging` | **Decidido** (09/10/2026) |
| E3 | Compose estático + `stack.env` por substituição de variáveis | **Decidido** (09/10/2026) |
| E4 | Segredos montados só no serviço que usa; backend com `target` em maiúsculas | **Decidido** (09/10/2026) |
| E5 | Frontend, backend e RabbitMQ com `stop-first` (o limite de uma réplica por nó impede `start-first`); rollback automático | **Decidido** (09/10/2026; frontend alterado de `start-first` para `stop-first` em 10/10/2026) |
| E6 | RabbitMQ com hostname fixo, volume local, usuário padrão por segredo e filas por `definitions.json` | **Decidido** (09/10/2026) |
| E7 | `max_replicas_per_node: 1` e validação `réplicas ≤ nós` (frontend e backend) | **Decidido** (09/10/2026) |
| E8 | Limites de memória: frontend 128 MB, backend 768 MB, RabbitMQ 512 MB (a medir) | **Decidido** (09/10/2026) |
| E9 | Só o microsserviço usa o RabbitMQ; o backend envia eventos ao microsserviço | **Decidido** (autor) |
| E10 | Contrato backend → microsserviço por HTTP: `MESSAGING_URL`, `MESSAGING_API_KEY` e porta do microsserviço (6.5) | **Decidido** (09/10/2026); porta e validação da chave dependem da configuração do microsserviço |
| E11 | Mensageria desligada com `REPLICAS_MESSAGING=0` até a E8: compose da mensageria em arquivo separado (`stacks/app-messaging.yml`), incluído só quando ligada, com `--prune` na `tnf-app`; o RabbitMQ segue implantado | **Decidido** (10/10/2026) |
| E12 | `stack.env` carrega também `EXPECTED_NODES` e `MANAGER_COUNT`, não usados pelos compose files: servem à espera e à limpeza de nós no líder e à recusa de mudar `manager_count` no `infra up`. Em 11/10/2026 (item 22) passou a carregar também `DB_SCHEMA_REPO_URL`, `DB_SCHEMA_REF` e `DB_SCHEMA_PATH`, igualmente fora dos compose files: servem ao `db-init` do líder | **Decidido** (10/10/2026; ampliado em 11/10/2026) |
| E13 | Mensageria com no máximo 1 réplica (`0` ou `1`) até a configuração do microsserviço confirmar que várias são seguras; `messaging ≤ app_node_count` deixa de existir; `max_replicas_per_node: 1` no compose; recusado no `plan` (03, T17; R15) | **Decidido** (10/10/2026) |
| E14 | Verificação de saúde de frontend e backend por `CMD-SHELL` com `wget` e `curl` de reserva, em `127.0.0.1`; a imagem precisa ter um dos dois, conferido na E5 (07, 4.4; C17); `VITE_*` são valores de build, vindos de variáveis do repositório do frontend (07, F10), e não do `stack.env` | **Decidido** (10/10/2026) |
| E15 | WhatsApp com sessão (auditoria item 19, opção A): o nível 4 vale até o serviço estar de pé e o pareamento é uma exceção manual declarada, uma vez por ambiente novo; a `messaging` fica sempre no `app-1` por rótulo `messaging=true` (aplicado mesmo com ela desligada); se o microsserviço guarda a sessão em disco, usa o volume local `messaging_session`, sem cópia em SSM, S3 ou state; `stop-first` com `stop_grace_period`; procedimento de pareamento pelos logs via `infra ssh`; número de teste recomendado no dev; sessão no S3 descartada; R17 e Q23. Vale só se o microsserviço usar sessão; com a API oficial (token), nada disso se aplica | **Decidido** (10/10/2026); detalhes (caminho do volume, texto do log, forma do pareamento) dependem da configuração do microsserviço |

## 12. Pendências
- **Configuração do microsserviço de mensageria (PENDENTE):** imagem, porta que recebe os eventos, variáveis, segredos, verificação de saúde, memória, se aceita mais de uma réplica (o que permitiria rever E13), a lista de filas do RabbitMQ e se ele valida a `MESSAGING_API_KEY`. Pelo item 19, também: **como ele se autentica no WhatsApp** (biblioteca com sessão e QR code ou código de pareamento, API oficial com token, ou outra forma), **em que caminho grava a sessão** (para o volume `messaging_session`), qual o texto do log de "conectado", o que faz com eventos recebidos antes do pareamento e **quais números de WhatsApp** serão usados em dev e em prod. Só bloqueia a E8.
- **Caminho do endpoint de saúde do backend:** existe um endpoint (por exemplo o Actuator do Spring) que responda 200 quando a aplicação está pronta e conectada ao banco? Qual o caminho? Define o `<caminho>` de 6.2. A ferramenta (`wget` ou `curl`) deixou de ser pendência: está decidida em E14 e é conferida na E5.
- **Imagem do frontend baseada na oficial do nginx** (logs em stdout, 6.1).
- Itens da auditoria de 10/10/2026 que ainda alteram este documento (ver 00): nenhum pendente (o item 19 foi resolvido em 6.4, 6.4.1 e E15, e o item 22, em 11/10/2026, só ampliou o `stack.env` na seção 4 e em E12).
