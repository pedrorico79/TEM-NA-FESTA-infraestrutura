# 07 – CI/CD (imagens, deploy e validação da infra)

Estado: **aprovado** (09/10/2026); ajustado em 10/10/2026 (testes T1 a T17 em 6; serviço desligado em 5.2; workflows antigos de ECR removidos na seção 2, auditoria item 7; etiqueta apontando para imagem que falhou, em 5.2, C5, C13 e C14, auditoria item 8; Dockerfile, variáveis `VITE_*` e ferramenta de saúde das imagens, em 2, 4.2, 4.3, 4.4, C15 a C17 e F10, auditoria item 14; trava de prod por branch no próprio workflow, em 4.2, 4.5, C18, C19 e F11, auditoria item 15) e em 11/10/2026 (verificação automática da rastreabilidade dos testes no CI, em 6, auditoria item 20). Decididos: repositórios do Docker Hub **públicos**; deploy manual **em cada repositório da aplicação**, escolhendo ambiente e branch; o Swarm percebe a nova versão sozinho, sem credenciais da AWS no GitHub; estratégia de tags; CI da infra. Faltam apenas dados de entrada (seção 11).
Depende de: 01 (RF-09, RF-10), 03 (`image_tags`, `dockerhub_namespace`), 04 (convergência), 06 (stacks e política de atualização), 08 (rastreabilidade, seção 7).

## 1. Escopo
- Como uma versão do frontend, do backend ou do microsserviço vira imagem no Docker Hub e chega a **dev** ou **prod** por um gatilho manual, por stack (RF-09).
- Como o repositório de infraestrutura se valida sozinho (formato, sintaxe, testes do contrato de variáveis e rastreabilidade dos testes).
- **Fora do escopo agora (*Decidido*):** rodar o Terraform pelo GitHub Actions. A infra continua sendo criada e destruída localmente com o `infra` (08). Depende de decidir como entregar as credenciais do laboratório, que mudam a cada sessão.

## 2. Repositórios e imagens
| Repositório | Papel | Imagem no Docker Hub | Stack/serviço |
|---|---|---|---|
| `TEM-NA-FESTA-frontend` | código do frontend | `<namespace>/tnf-frontend` | `frontend` |
| `TEM-NA-FESTA-backend` | código do backend | `<namespace>/tnf-backend` | `backend-som` |
| `TEM-NA-FESTA-microservice` | código do microsserviço (**PENDENTE** até a configuração dele) | `<namespace>/tnf-messaging` | `messaging` |
| `TEM-NA-FESTA-database` | script SQL do schema | *(não gera imagem)* | usado por `db_schema_repo_url`/`db_schema_ref` (05, B5) |
| `TEM-NA-FESTA-infraestrutura` | Terraform, scripts, compose files e `specs/` | *(não gera imagem)* | – |
- Nenhum dos repositórios de aplicação tem hoje CI/CD para o Docker Hub (informado pelo autor): os workflows deste documento são **novos**.
- **Workflows antigos de ECR (*Decidido* em 10/10/2026):** os que existirem (no repositório de infra, removidos na E0, 08 seção 5.2; e em qualquer repositório de aplicação) são **apagados** ao criar o `deploy.yml`. As imagens passam a ir só para o Docker Hub, e nenhum workflow guarda credenciais da AWS (C8). O histórico do Git preserva o que existia.
- `<namespace>` é a variável `dockerhub_namespace` (03). Os nomes `tnf-*` estão definidos aqui e em 03.
- Cada repositório de aplicação que gera imagem precisa de um **`Dockerfile` na raiz** e de uma imagem com `wget` ou `curl` (4.4).
- **Visibilidade dos repositórios do GitHub:** nenhuma regra desta spec depende de eles serem públicos ou privados (4.5). As imagens, sim, são públicas no Docker Hub (a seguir).

### Imagens públicas (*Decidido*)
- Os nós **não precisam de login** para baixar imagens. As variáveis `dockerhub_username` e `dockerhub_token` e a opção `--with-registry-auth` saíram do desenho (03, 04, 05, 06 já ajustados).
- Nada secreto pode estar **dentro** de uma imagem. Já é o desenho de 05: segredos entram em tempo de execução. Os `VITE_*` do frontend (`VITE_CNPJ`, `VITE_API_URL=/api/v1`) ficam visíveis a quem baixar a imagem; não são segredos, e por isso são **variáveis** do repositório, e não *secrets* (4.4). O código-fonte pode continuar privado.
- Limite do Docker Hub sem login: **100 baixadas a cada 6 h por IP** (IPv4 ou /64 de IPv6), segundo a [documentação do Docker](https://docs.docker.com/docker-hub/usage/pulls/). Todos os nós de um ambiente saem pelo(s) IP(s) da(s) NAT, então contam juntos. Pior caso de uma subida (prod: 2 web, 3 app): 10 a 15 baixadas. Folgado, mesmo repetindo ciclos. Dev e prod usam NATs (e IPs) diferentes.

## 3. Estratégia de tags (*Decidido*, mantém RF-09)
| Tag | Tipo | Quem move | Significado |
|---|---|---|---|
| `dev` | mutável | workflow de deploy com `env=dev` | o que deve rodar em dev |
| `prod` | mutável | workflow de deploy com `env=prod` | o que deve rodar em prod |
| `sha-<7 primeiros do commit>` | **imutável** | todo build | uma versão específica; serve para auditar e para voltar atrás |
- As etiquetas são **separadas por stack** (uma imagem por repositório): publicar o backend em prod não mexe no frontend (RF-09).
- Cada imagem recebe também *labels* OCI com a **branch**, o **commit** (`org.opencontainers.image.revision`) e a data do build, para saber o que está no ar mesmo sem consultar o GitHub.
- `image_tags` (03) vale para a **primeira subida** de um ambiente novo (padrão: `dev` ou `prod`, as etiquetas de ambiente). Pode ser trocada por um `sha-…` para fixar uma versão.
- Diferença em relação a "construir uma vez e promover": como cada deploy **constrói a imagem da branch escolhida**, dev e prod podem rodar builds distintos mesmo da mesma branch. Para um projeto acadêmico é aceitável, e o `sha-<7>` mantém tudo rastreável.

## 4. O workflow de deploy (nos repositórios `frontend`, `backend` e `microservice`) (*Decidido*)
Cada um desses repositórios ganha um workflow **`deploy.yml`** com disparo **manual** (`workflow_dispatch`). O modelo fica em `templates/deploy.yml` do repositório de infra (08).

### 4.1 Como se usa
No GitHub, aba **Actions → Deploy → Run workflow**:
| O que se escolhe | Como | Valores |
|---|---|---|
| **Branch** a construir | seletor de branch do próprio GitHub ("Use workflow from"), que também aceita tags do Git | em `dev`, qualquer branch ou tag; em `prod`, só `main` ou uma tag (4.5) |
| **Ambiente** | entrada `env` | `dev` ou `prod` |
| **Reaproveitar uma imagem** (opcional) | entrada `reuse_tag` | vazio (padrão) ou um `sha-…` já publicado |
- A **stack é a do próprio repositório** (o frontend publica o frontend etc.), então não há entrada para isso.
- Com `reuse_tag` preenchido, o workflow **não constrói nada**: só aponta a etiqueta do ambiente para aquela imagem. É o **voltar atrás** (rollback) rápido, e também o jeito de **tirar a etiqueta de uma imagem que falhou** (5.2). Nesse caso a conferência dos `VITE_*` (4.4) não roda, porque não há build. A trava de prod (4.5) vale também aqui: para voltar atrás em prod, rode o workflow a partir da `main`.

### 4.2 O que o workflow faz
1. **Confere a trava de prod** (4.5): com `env=prod`, só segue se a referência escolhida for a branch `main` ou uma tag do Git; depois faz o checkout.
2. Executa os testes do projeto. Se falharem, o workflow para e **nada é publicado** (depende de os testes existirem, ver seção 11).
3. Constrói a imagem para `linux/amd64` (as EC2 `t3` são x86_64), a partir do `Dockerfile` da raiz. **No frontend**, antes do build o workflow confere as variáveis `VITE_*` e as passa como `--build-arg` (4.4); se faltar alguma, para aqui e nada é construído nem publicado.
4. Publica `<namespace>/tnf-<stack>:sha-<7>` e `<namespace>/tnf-<stack>:<env>`.
5. Registra no resumo da execução: repositório, branch, commit, ambiente, e o *digest* anterior e o novo da etiqueta `<env>` (com o `sha-<7>` anterior, que é o que se usa em `reuse_tag` para voltar atrás). No frontend, registra também os `VITE_*` usados e seus valores (não são segredos).
- Dois deploys ao mesmo tempo para o mesmo ambiente não correm juntos (`concurrency` por repositório e ambiente).
- O job declara `environment: <env>` (o *GitHub Environment* de mesmo nome). Sem regras configuradas, isso não muda nada; se você ligar a aprovação por revisor em `prod` (4.5), ela passa a valer sem alterar o workflow.

### 4.3 Credenciais e configuração no GitHub
| Onde | O que | Para quê |
|---|---|---|
| GitHub: `frontend`, `backend`, `microservice` | *secrets* `DOCKERHUB_USERNAME` e `DOCKERHUB_TOKEN` (token com permissão de **escrita**, o de menor permissão possível) | publicar imagens |
| GitHub: `frontend` | *variáveis do repositório* (`vars`, não *secrets*) `VITE_*`, uma por `ARG` sem valor padrão do Dockerfile (4.4) | valores embutidos no build |
| GitHub: `infraestrutura` | nenhum do Docker Hub | – |
| GitHub, qualquer repositório | **nenhuma credencial da AWS** | – |
| Nós do Swarm | nenhuma | baixam imagens públicas |
| Sua máquina | credenciais do laboratório e, com a mensageria ligada, `secrets.env` (05) | criar e destruir ambientes |

### 4.4 O que cada repositório de aplicação precisa ter (*Decidido* em 10/10/2026, auditoria item 14)
**Dockerfile.** Cada repositório que gera imagem tem um `Dockerfile` na **raiz**, usada como contexto de build. O workflow não escreve Dockerfile e não altera o código da aplicação. Os workflows antigos de ECR já construíam imagens, então é esperado que os Dockerfiles existam; o que faltar (por exemplo `ARG VITE_*`) é tarefa do repositório de aplicação (seção "Tarefas fora da infra" de 00).

**Variáveis `VITE_*` do frontend.**
- O Vite grava os `VITE_*` dentro do JavaScript **no momento do build**; mudar um valor exige construir a imagem de novo. Por isso o Dockerfile declara um `ARG` para cada um e o workflow passa `--build-arg`.
- **Origem dos valores:** *variáveis do repositório* (`vars`) do `TEM-NA-FESTA-frontend` (Settings → Secrets and variables → Actions → Variables), com o **mesmo nome** do `ARG` (por exemplo `VITE_CNPJ`). Não são *secrets*: o valor termina no JavaScript público do site e é legível por quem baixar a imagem (seção 2).
- **Lista de obrigatórias derivada do Dockerfile:** todo `ARG VITE_*` **sem valor padrão** é obrigatório. O passo "Conferir variáveis" lê o Dockerfile, recebe as variáveis do repositório (`toJSON(vars)`) e, se faltar alguma ou estiver vazia, **falha antes do build** com a mensagem: *"Falta a variável `VITE_X` no repositório do frontend (Settings → Secrets and variables → Actions → Variables). Nada foi construído nem publicado."* Uma variável `VITE_*` do repositório sem `ARG` correspondente é ignorada, com um aviso no resumo. Um `ARG` com valor padrão é opcional. Assim, acrescentar um `VITE_*` novo é só declarar o `ARG` e cadastrar a variável, sem editar o workflow.
- **Mesmos valores em dev e prod.** A imagem é construída a cada deploy, mas as variáveis do repositório são únicas, então dev e prod recebem os mesmos `VITE_*`. Funciona hoje porque `VITE_API_URL` é relativo (`/api/v1`) e `VITE_CNPJ` é uma constante do negócio. **Limitação registrada:** valor diferente por ambiente não é suportado. Exigiria configuração em tempo de execução (um arquivo de configuração gerado ao iniciar o container), o que altera o código do frontend e está fora do escopo.

**Backend e microsserviço.** Não recebem argumentos de build. Toda configuração entra em tempo de execução (variáveis do `stack.env` e Docker secrets, 05 e 06).

**Ferramenta para a verificação de saúde.** A verificação roda **dentro do container** (06, 6.1 e 6.2) e usa `wget` ou, na falta dele, `curl`. A imagem precisa ter pelo menos um dos dois.
- É conferida na **E5**, com a primeira imagem de cada stack: `docker run --rm --entrypoint sh <imagem> -c 'command -v wget || command -v curl'` deve imprimir um caminho (C17).
- Se a imagem não tiver nenhum, a correção é no Dockerfile do repositório (trocar a base por uma que tenha, ou instalar o pacote), sem alterar o código da aplicação.
- No frontend, a base preferida é a imagem oficial do nginx (logs em stdout, 06 6.1).

### 4.5 Proteção do deploy em prod (*Decidido* em 10/10/2026, auditoria item 15)
**Princípio:** a proteção mora **dentro do workflow**, para valer em qualquer plano do GitHub e em repositório público ou privado. Os recursos pagos do GitHub ficam como reforço opcional.
- **Trava de branch:** com `env=prod`, o `deploy.yml` só continua se a referência escolhida em "Use workflow from" for a **branch `main`** ou uma **tag do Git** (qualquer tag: criar uma é um ato deliberado). Qualquer outra faz o workflow falhar no primeiro passo, antes do checkout e do build, com a mensagem: *"Prod só aceita a branch `main` ou uma tag do Git. Você escolheu `<ref>`. Faça o merge em `main`, crie uma tag, ou use `env=dev`."* Nada é construído nem publicado, e nenhuma etiqueta é movida.
- **`env=dev`:** qualquer branch ou tag, como antes.
- **Vale também com `reuse_tag`** (4.1): voltar atrás em prod exige rodar o workflow a partir da `main` (ou de uma tag).
- **Como a trava é feita:** o primeiro passo compara `github.ref_type` e `github.ref_name` com a regra acima. O modelo `templates/deploy.yml` já traz o passo, então os três repositórios ficam iguais.
- **Aprovação por revisor (opcional):** o job declara `environment: <env>` (4.2). Se o seu plano permitir (repositório público em qualquer plano; privado com GitHub Pro, que o Student Developer Pack inclui, ou Team/Enterprise), você pode ligar em Settings → Environments → `prod` a opção *Required reviewers* com você mesmo. A spec **não exige** isso e nada depende dela.
- **CI do repositório de infra:** não vira bloqueio configurado no GitHub. O `ci-infra.yml` roda e aparece nos PRs, e o `make check` local (08, seção 8) é o mesmo teste; exigir o CI verde antes do merge é regra de conduta (08, seção 7), e vira bloqueio de verdade só se o plano permitir *branch protection*.
- **Limite do que a trava garante:** impede publicar em prod um código que não esteja na `main` nem numa tag, mas não impede você de fazer o merge de código ruim na `main`; para isso valem os testes do passo 2 (4.2) e o `reuse_tag` para voltar atrás.

## 5. Como a nova versão chega ao Swarm (*Decidido*: F4 e F5)
### 5.1 Visão geral
```
Run workflow ──> build ──> push  <ns>/tnf-backend:prod   (etiqueta passa a apontar para outro digest)
                                      │
        líder do Swarm (a cada 60 s) ─┘ pergunta ao Docker Hub o digest atual de :prod
                                        ├─ igual ao que roda → nada
                                        └─ diferente → atualiza só aquele serviço (uma réplica por vez, com rollback)
```

### 5.2 O lado do Swarm
O serviço de convergência que já roda a cada 60 s no líder (04, seção 7, passos 7 e 8) faz:
1. Para cada serviço de aplicação **ligado** (réplicas maiores que 0; a mensageria desligada é pulada, 03 seção 3.4), pergunta ao Docker Hub qual é o *digest* atual de `<repo>:<etiqueta do ambiente>` (consulta só do cabeçalho do manifesto, sem baixar a imagem).
2. Se o *digest* é diferente do que está rodando (e não está anotado como falho), atualiza **só aquele serviço** usando a imagem fixada por *digest* (`<repo>:<tag>@sha256:…`), com a política de atualização de 06 (uma réplica por vez, rollback automático).
3. Grava em `status/converge.json` o *digest* em execução de cada serviço, o *digest* para o qual a etiqueta aponta e a situação do serviço (`ok`, `failed_tag` ou `off`); o `infra status` mostra tudo isso.
- **Por que fixar por *digest*:** a etiqueta `prod` é mutável. Fixar o *digest* garante que todos os nós rodam exatamente a mesma imagem, mesmo que a etiqueta mude no meio da atualização, e deixa claro o que está no ar.
- **Latência esperada:** até 1 minuto para o líder perceber, mais o tempo da atualização (alguns minutos para o backend).
- Consultas ao Docker Hub: uma por serviço ligado a cada ciclo. As consultas de cabeçalho (`HEAD`) não entram na contagem de baixadas segundo a política do Docker; *validar na implementação* (se contarem, o intervalo sobe para 5 min).
- Na criação do ambiente, o mesmo passo resolve as etiquetas de `image_tags` para *digests* antes do primeiro deploy; assim a subida e as atualizações seguem o mesmo caminho.

#### Quando a imagem da etiqueta não fica saudável (*Decidido*, auditoria item 8)
- **Atualização de um ambiente no ar:** o Swarm reverte para a versão anterior (06). O líder **anota o *digest* que falhou** em `status/deploy-failed.json` (no S3), com serviço, etiqueta, *digest*, o **commit** (lido da *label* OCI da imagem baixada) e a hora, e não tenta de novo até a etiqueta apontar para outro *digest*. Sem isso o líder repetiria a atualização que falha a cada minuto.
- **A etiqueta continua apontando para a imagem ruim** no Docker Hub: a infra não tem credencial para mexer nela (F5). O que roda no cluster é a versão anterior, e o `converge.json` marca o serviço como `failed_tag`.
- **Visibilidade:** o `infra status` destaca o serviço com a mensagem: *"backend: a etiqueta `prod` aponta para uma imagem que falhou (commit abc1234). Rodando: versão anterior. Ação: rode o deploy do backend com a branch corrigida ou com `reuse_tag=sha-<anterior>`."*
- **Como corrigir:** sempre pelo workflow (4.1): com a branch corrigida, ou com `reuse_tag` apontando para o `sha-<7>` anterior (que está no resumo da execução que causou o problema). Quando a etiqueta passar a apontar para outro *digest*, o líder atualiza em até 1 minuto e a situação volta a `ok`.
- **Ambiente recriado (`infra down` e `infra up`) com a etiqueta ainda ruim:** o `deploy-failed.json` some junto com o bucket de artefatos, então o ambiente novo tenta a imagem ruim. Como não há versão anterior, o serviço nunca fica saudável: se não atingir as réplicas desejadas em **10 minutos** depois do deploy (constante do `converge.sh`), o líder o anota como falho e marca `converge.json` = `degraded`, com a mesma mensagem acionável. Os demais serviços seguem normalmente. Corrigindo a etiqueta pelo workflow, o líder atualiza e o ambiente vai a `ready` sem recriar nada.
- **Decisão consciente:** a infra **não guarda** o "último digest bom" entre recriações (seção 10, F9). A correção pelo workflow é suficiente e fica visível.

### 5.3 Feedback do deploy
O workflow **não enxerga o Swarm** (não há credenciais da AWS no GitHub). Ele mostra o resultado do build e da publicação; o resultado da atualização no cluster se vê por `infra status <env>` (versão em execução por serviço, e aviso quando a etiqueta aponta para uma imagem que falhou) e pelos logs. É uma troca consciente por não ter segredos da AWS no GitHub.

### 5.4 Alternativas consideradas
| Alternativa | Por que não foi escolhida |
|---|---|
| Workflow dispara o deploy por SSM Run Command | exige credenciais da AWS no GitHub, renovadas a cada sessão do laboratório (3 valores que expiram), e depende do agente do SSM nos nós, ainda não testado no laboratório. Dá feedback imediato, mas o custo operacional é maior |
| Workflow grava a versão desejada no S3 e o líder lê (manifesto) | também exige credenciais da AWS no GitHub |
| Atualização automática a cada push (estilo Watchtower) | tira o gatilho manual que você definiu; o desenho acima mantém o manual |
| Workflow acessa o líder por SSH | os nós não têm IP público e o SSH é restrito ao seu IP (02); IPs dos runners do GitHub variam |
| Guardar o último *digest* bom e os que falharam em arquivo persistente (bucket de state) e subir ambientes novos com ele | acrescenta um estado persistente e uma escrita do líder no bucket de state; a visibilidade mais a correção pelo workflow bastam (auditoria item 8) |
| Proteger prod só com recursos do GitHub (*Environments* com revisor e *branch protection*) | dependem do plano e da visibilidade do repositório; a trava dentro do workflow vale em qualquer caso (4.5) |

## 6. Validação do repositório de infra (CI) (*Decidido*)
Workflow **`ci-infra.yml`** no `TEM-NA-FESTA-infraestrutura`, em cada pull request e push na `main`, **sem credenciais da AWS**:
| Verificação | Ferramenta |
|---|---|
| Formatação | `terraform fmt -check -recursive` |
| Sintaxe e referências | `terraform init -backend=false` e `terraform validate` em `bootstrap`, `envs/dev` e `envs/prod` |
| Boas práticas | `tflint` |
| Contrato de variáveis | testes automatizados do Terraform (`terraform test`) com provedor simulado, cobrindo os casos **T1 a T17** de 03 (rejeições e o `plan` válido; T13 é verificado no laboratório), sem acessar a AWS |
| Scripts | `shellcheck` em `scripts/`, `node/` e no `infra`; testes `bats` |
| Compose files | validação de sintaxe dos arquivos das stacks (`yamllint`), incluindo `app-messaging.yml` |
| Finais de linha | recusa arquivos de texto com `CRLF` (08, seção 5.1) |
| Segredos no repositório | varredura de padrões (por exemplo `gitleaks`) para garantir RNF-03 |
| Rastreabilidade dos testes | `scripts/check-traceability.sh` (`make trace`): todo ID de teste dos specs 03 a 09 tem linha em `tests/TRACEABILITY.md` com etapa e verificador, e as etapas batem com as de 09; no CI roda no modo normal, e o modo `--strict` (sem nenhum "pendente") roda na E9 (08, seção 7; G10) |
- O objetivo é que todo requisito testável de 03 e 06 tenha um teste que roda sem gastar nada do laboratório.
- As mesmas verificações rodam localmente com `make check` (08, seção 8), que inclui `make trace`.

## 7. Critérios de aceite
| # | Cenário | Esperado |
|---|---|---|
| C1 | Rodar o `deploy.yml` do backend com a branch `develop` e `env=dev` | a imagem é construída dessa branch; `tnf-backend:dev` e `tnf-backend:sha-<7>` existem e a *label* de branch diz `develop` |
| C2 | O ambiente dev está no ar; depois do C1 | em até 3 min o backend em dev roda o novo *digest* (`infra status`); frontend, microsserviço e prod não mudam |
| C3 | Rodar de novo o mesmo deploy sem mudança de código | o `sha-<7>` é o mesmo; nada é atualizado no cluster |
| C4 | Testes falham na branch escolhida | o workflow falha e nenhuma etiqueta é movida |
| C5 | Publicar uma versão do backend que não fica saudável | o Swarm reverte; o líder não repete a tentativa; `converge.json` e o `infra status` mostram o *digest* e o commit com falha, o serviço como `failed_tag` e o que fazer (5.2) |
| C6 | Rodar o deploy com `reuse_tag=sha-<anterior>` | nada é construído; `:<env>` aponta para a imagem antiga; a versão antiga volta a rodar |
| C7 | `reuse_tag` inexistente | o workflow falha antes de mover qualquer etiqueta |
| C8 | Conferir os *secrets* e os workflows de todos os repositórios | nenhuma credencial da AWS em nenhum deles e nenhum workflow de ECR restante |
| C9 | `infra up` de um ambiente novo | os nós baixam as imagens sem fazer login e as stacks sobem (as dos serviços ligados) |
| C10 | Abrir um PR com `manager_count = 2` em `envs/dev` | o `ci-infra.yml` falha com a mensagem de T5 |
| C11 | Executar o `ci-infra.yml` | passa sem nenhuma credencial da AWS |
| C12 | Dois deploys simultâneos para o mesmo repositório e ambiente | o segundo espera o primeiro terminar |
| C13 | Depois do C5, rodar `infra down` e `infra up` do ambiente com a etiqueta ainda apontando para a imagem ruim | em até cerca de 10 min depois do deploy, `converge.json` = `degraded` com a mensagem acionável para o serviço afetado; os demais serviços ficam saudáveis; o `infra up` imprime a mensagem e termina com código `3` |
| C14 | Com o ambiente em `degraded` por C13 (ou `failed_tag` por C5), rodar o deploy corrigido ou `reuse_tag=sha-<anterior>` | em até 3 min o serviço roda o novo *digest* e `converge.json` = `ready` (serviço `ok`), sem recriar o ambiente |
| C15 | Rodar o deploy do frontend com uma variável `VITE_*` obrigatória (um `ARG` sem valor padrão) ausente ou vazia | o workflow falha antes do build, com a mensagem de 4.4 citando a variável; nada é construído nem publicado |
| C16 | Rodar o deploy do frontend com todas as variáveis cadastradas | os `VITE_*` e os valores aparecem no resumo da execução; o JavaScript da imagem construída contém o valor de `VITE_CNPJ`; o mesmo conjunto de valores vale para `env=dev` e `env=prod` |
| C17 | Em cada imagem publicada (frontend e backend), executar `docker run --rm --entrypoint sh <imagem> -c 'command -v wget \|\| command -v curl'` | imprime o caminho de uma das duas ferramentas |
| C18 | Rodar o deploy com `env=prod` escolhendo uma branch que não é a `main` (por exemplo `feat/x`), com e sem `reuse_tag` | o workflow falha no primeiro passo com a mensagem de 4.5; nada é construído nem publicado e nenhuma etiqueta é movida |
| C19 | Rodar o deploy com `env=prod` a partir da `main`, e depois a partir de uma tag do Git; e com `env=dev` a partir de uma branch qualquer | os três seguem normalmente |

## 8. Credenciais e permissões (resumo)
Ver tabela da seção 4.3. O token do Docker Hub deve ser o de **menor permissão** que permita escrever nos repositórios de imagem.

## 9. Mudanças em outros specs (aplicadas na consolidação de 09/10/2026)
| Spec | Mudança |
|---|---|
| 03 | `dockerhub_username`/`dockerhub_token` removidos; `image_tags` = primeira subida; testes de contrato como `terraform test`; `db_schema_*` |
| 04, seção 7 | Convergência com resolução e atualização por *digest*; `converge.json` com o *digest* por serviço; `status/deploy-failed.json`; falha "repositório privado" removida |
| 05 | Credenciais do Docker Hub fora dos segredos manuais e dos nós |
| 06 | Sem `--with-registry-auth` nem `--resolve-image`; imagens fixadas por *digest* no arquivo efetivo; (10/10/2026) verificação de saúde com `wget` e `curl` de reserva (6.1, 6.2, E14) |
| 08 | `ci-infra.yml`, `tests/` e `templates/deploy.yml` na estrutura; (10/10/2026) exigir o CI verde nos PRs é regra de conduta, e a pendência sobre o plano do GitHub deixa de bloquear (seções 7 e 11); (11/10/2026) `scripts/check-traceability.sh` e `make trace`, parte do `make check` e do CI (seções 7 e 8, G10) |
| 09 | Etapa E5 (CI das imagens); imagem `dev` de cada stack antes da primeira subida real; (10/10/2026) valores `VITE_*` e Dockerfiles nas entradas, C15 a C19 na E5 |

## 10. Decisões
| # | Decisão | Situação |
|---|---|---|
| F1 | Repositórios do Docker Hub públicos | **Decidido** (autor) |
| F2 | Deploy manual por ambiente, em cada repositório da aplicação, escolhendo ambiente e branch; build feito no próprio deploy | **Decidido** (autor) |
| F3 | Tags: `dev`/`prod` mutáveis por stack e `sha-<7>` imutável por build; *labels* de branch e commit | **Decidido** (09/10/2026) |
| F4 | O Swarm percebe a mudança da etiqueta sozinho e atualiza por *digest* (modelo *pull*) | **Decidido** (autor, 09/10/2026) |
| F5 | Sem credenciais da AWS no GitHub | **Decidido** (autor, 09/10/2026) |
| F6 | `ci-infra.yml` com `terraform test` do contrato, sem AWS; (11/10/2026) também roda a verificação de rastreabilidade dos testes (`make trace`, 08 H18) | **Decidido** (09/10/2026; ampliado em 11/10/2026, opção A da auditoria item 20) |
| F7 | Terraform pelo GitHub Actions | **Adiado** (fora do escopo) |
| F8 | Workflows antigos de ECR apagados; só o Docker Hub recebe imagens | **Decidido** (10/10/2026) |
| F9 | Etiqueta apontando para imagem que falhou: a infra torna visível (`failed_tag`, mensagem acionável, `degraded` em ambiente novo) e a correção é pelo workflow; sem memória do último digest bom entre recriações | **Decidido** (10/10/2026, opção A da auditoria item 8) |
| F10 | `VITE_*` do frontend vêm de variáveis do repositório (`vars`, não *secrets*), iguais para dev e prod; a lista de obrigatórias é derivada dos `ARG VITE_*` sem padrão do Dockerfile e o workflow falha antes do build se faltar uma; `Dockerfile` na raiz de cada repositório de aplicação; imagem com `wget` ou `curl`, conferida na E5 (C15 a C17); valor por ambiente fica fora do escopo | **Decidido** (10/10/2026, opção A da auditoria item 14) |
| F11 | Trava de prod dentro do workflow: `env=prod` só aceita a branch `main` ou uma tag do Git (também com `reuse_tag`); `dev` aceita qualquer uma; o job declara `environment: <env>`, e a aprovação por revisor é um reforço opcional que depende do plano do GitHub; o CI verde nos PRs de infra é regra de conduta; nada depende da visibilidade dos repositórios (C18, C19) | **Decidido** (10/10/2026, opção A da auditoria item 15) |

## 11. Pendências (dados de entrada)
- Nome do usuário/organização do Docker Hub (`dockerhub_namespace`).
- Os repositórios de aplicação têm **testes automatizados** que possam rodar no workflow (por exemplo `mvn test` no backend)? Define o passo 2 de 4.2.
- **Valores dos `VITE_*`** (`VITE_CNPJ` e `VITE_API_URL`, e outros que o Dockerfile declarar) para cadastrar como variáveis do repositório do frontend, e confirmação de que os Dockerfiles dos três repositórios existem na raiz e declaram os `ARG` (4.4).
- *Opcional, não bloqueia:* ligar ou não a aprovação por revisor em `prod` (*GitHub Environments*), se o seu plano permitir (4.5).
- Caminho do script SQL dentro de `TEM-NA-FESTA-database` (variável `db_schema_path`).
- Validar na implementação se as consultas de cabeçalho ao Docker Hub não consomem a cota de baixadas.
- A configuração do microsserviço (imagem `tnf-messaging`, repositório `TEM-NA-FESTA-microservice`) continua **PENDENTE**; a mensageria fica desligada até a E8 (03, seção 3.4).
