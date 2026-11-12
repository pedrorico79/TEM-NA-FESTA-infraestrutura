# TEM-NA-FESTA-infraestrutura

Infraestrutura do **Tem Na Festa** na AWS (AWS Academy Learner Lab): Terraform em duas camadas, Docker Swarm em EC2 e um único comando, o `infra`, para criar, acompanhar e destruir os ambientes `dev` e `prod`.

A branch **`main`** traz só o que é preciso para usar a infraestrutura. As specs, os testes e as ferramentas de desenvolvimento ficam na branch **[`develop`](https://github.com/pedrorico79/TEM-NA-FESTA-infraestrutura/tree/develop/)**; as referências deste guia no formato "(07, seção 4)" apontam para as [specs](https://github.com/pedrorico79/TEM-NA-FESTA-infraestrutura/tree/develop/specs) de lá.

## Como começar

No Windows, prepare antes o WSL e as ferramentas com o guia [`docs/primeiros-passos-windows.md`](docs/primeiros-passos-windows.md). O `infra` roda no terminal do Ubuntu (WSL), **nunca no PowerShell**.

```bash
./infra doctor        # confere ferramentas, credenciais do laboratório e região
./infra bootstrap     # uma vez por conta: buckets de state e bronze
./infra up dev        # cria o ambiente dev e espera ele ficar pronto
```

Para destruir: `./infra down dev`. Todos os comandos estão em `./infra --help` e em [08, seção 5](https://github.com/pedrorico79/TEM-NA-FESTA-infraestrutura/blob/develop/specs/08-estrutura-do-repositorio.md).

## Guia de uso

### Um ciclo de trabalho

1. Inicie a sessão no Learner Lab e atualize as credenciais no WSL (guia de primeiros passos, passo das credenciais).
2. `./infra doctor` deve terminar sem avisos de sobras na conta.
3. `./infra up dev` cria o ambiente e espera até 25 minutos. Ao fim, ele imprime o endereço do sistema (`Sistema: http://...`) e o acesso ao bastion.
4. Trabalhe. `./infra status dev` mostra a qualquer hora os nós, a convergência e, por serviço, as réplicas e a imagem em execução.
5. `./infra down dev` antes de a sessão acabar. O banco é guardado num snapshot final e volta sozinho no próximo `up`.

Esquecer um ambiente no ar é o maior risco de custo: o dev custa perto de US$ 0,14 por hora e o prod perto de US$ 0,25.

### Publicar uma versão da aplicação

O deploy é feito no GitHub, no repositório da aplicação (frontend, backend ou microsserviço): Actions → Deploy → Run workflow, com a branch ou tag em "Use workflow from" e o ambiente em `env` (07, seção 4).

- `env=dev` aceita qualquer branch; `env=prod` só aceita a `main` ou uma tag.
- Em até 3 minutos o líder do Swarm percebe a etiqueta nova e atualiza só aquele serviço; confira com `./infra status <env>`.
- **Voltar atrás:** rode o Deploy de novo com `reuse_tag=sha-<anterior>`. O resumo de cada execução mostra o `sha-` anterior.
- Se a versão nova não ficar saudável, o Swarm reverte sozinho e o `infra status` mostra o serviço como `failed_tag`, com o commit e o que fazer. A correção é sempre um novo deploy, com a branch corrigida ou com `reuse_tag`.

### Mensageria e o token da Whapi

A mensageria está ligada nos dois ambientes (`service_replicas.messaging = 1`). Ela precisa do token da Whapi, que fica só na sua máquina:

```bash
./infra init-secrets   # pergunta o token sem mostrar e grava o secrets.env (600, fora do Git)
```

Sem o `secrets.env`, `infra plan` e `infra up` param antes de mudar qualquer coisa. Para desligar a mensageria, troque `messaging = 1` por `0` em `envs/<env>/terraform.tfvars` e rode `./infra up <env>`. Use no dev um número de teste da Whapi.

### Banco

- `./infra snapshot dev` guarda um snapshot manual; `./infra snapshots dev` lista os do ambiente.
- `./infra up dev --snapshot <id>` sobe um ambiente novo a partir de um snapshot escolhido.
- Para mexer no banco à mão: `./infra ssh dev app-1` e, no nó, `tnf-db-shell`. São dois schemas: `tem_na_festa` (backend) e `temnafesta_notificacao` (microsserviço).

### Teste de carga e bloqueio de login

O backend bloqueia o login por 15 minutos depois de 5 falhas da mesma conta ou de 20 falhas de um mesmo IP (resposta 429). Numa carga que sai de uma máquina só, todos os usuários de teste têm o mesmo IP, então 20 senhas erradas bloqueiam todos. Para o ambiente de teste, ajuste os limites em `envs/<env>/terraform.tfvars` e rode `./infra up <env>` (o backend é reiniciado com os valores novos):

```hcl
login_limits = { max_por_ip = 0 }   # 0 desliga a regra por IP; os outros limites ficam nos padrões
```

Os campos são `max_por_conta` (5), `max_por_ip` (20), `janela_minutos` (15) e `bloqueio_minutos` (15). Depois do teste, apague a linha para voltar aos padrões.

### Quando algo dá errado

| Sintoma | O que fazer |
|---|---|
| `infra` diz que as credenciais venceram | renove a sessão no Learner Lab, atualize as credenciais no WSL e repita o comando, que é idempotente |
| `infra up` termina com código 3 e `failed_tag` | publique uma versão corrigida ou use `reuse_tag` no Deploy; o ambiente se corrige sem ser recriado |
| `infra up` termina com código 3 e erro do banco | leia a mensagem: em geral é a tag do script do schema; corrija no `terraform.tfvars` e rode `infra up` de novo |
| um nó não chega a `joined` | `./infra ssh <env> <nó>` e veja `/var/log/tnf-bootstrap.log` |
| `infra doctor` aponta sobras | apague à mão os recursos listados antes do próximo `up` |
| SSH recusado de outra rede | `./infra access <env>` atualiza o IP autorizado no bastion |

## Primeiro administrador do sistema (banco novo)

O script do schema é público e não traz nenhum usuário (05, B5). Num banco que nasceu vazio, depois de o `infra up` terminar, crie o primeiro admin uma vez; os snapshots o preservam nos ciclos seguintes.

1. Na sua máquina (WSL), gere o hash BCrypt da senha. O `htpasswd` pede a senha sem mostrá-la e sem deixá-la no histórico:

   ```bash
   sudo apt install -y apache2-utils     # uma vez
   htpasswd -nBC 10 admin | cut -d: -f2 | sed 's/^\$2y/$2a/'
   ```

2. Entre num nó app e abra o banco:

   ```bash
   ./infra ssh dev app-1
   tnf-db-shell
   ```

3. No cliente MySQL, crie o usuário. Troque `HASH_DO_PASSO_1` pelo hash inteiro do passo 1 (começa com `$2a$10$`), sem nenhum outro caractere em volta, e troque o nome e o e-mail:

   ```sql
   USE tem_na_festa;
   INSERT INTO usuario (nome, email, senha, is_ativo, is_deletado, data_criacao, perfil_id)
     SELECT 'Administrador', 'admin@exemplo.com', 'HASH_DO_PASSO_1', TRUE, FALSE, NOW(), id
     FROM perfil WHERE nome = 'ADMIN';
   ```

Os perfis (`ADMIN`, `ATENDENTE`, `CONFEITEIRO`) e os métodos de pagamento (`PIX`, `Cartão de Crédito`, `Dinheiro`) já vêm no script do banco a partir da tag `v1.0.1`. Se o `SELECT` acima não inserir nenhuma linha, o banco foi criado com uma tag mais antiga: confira com `SELECT * FROM perfil;`. O backend compara a senha com o hash BCrypt (`ROLE_ADMIN` vem do perfil `ADMIN`). Não guarde a senha nem o hash no repositório.

## Para quem desenvolve

O desenvolvimento acontece na branch [`develop`](https://github.com/pedrorico79/TEM-NA-FESTA-infraestrutura/tree/develop/), que tem tudo o que a `main` tem e mais as specs (`specs/`, a fonte da verdade: comece por [`00-indice.md`](https://github.com/pedrorico79/TEM-NA-FESTA-infraestrutura/blob/develop/specs/00-indice.md)), os testes (`tests/`, com a rastreabilidade em [`tests/TRACEABILITY.md`](https://github.com/pedrorico79/TEM-NA-FESTA-infraestrutura/blob/develop/tests/TRACEABILITY.md)), o `Makefile` e o CI.

```bash
git switch develop
make check                  # formatação, lint, testes e rastreabilidade, como no CI
scripts/publish-main.sh     # monta a main limpa a partir da develop, na branch release/main
```

Toda mudança entra por *pull request* na `develop`. A `main` nunca recebe commits diretos: ela é gerada pelo `scripts/publish-main.sh`, que copia a `develop` sem os caminhos listados em `.main-ignore`, e atualizada por um *pull request* da `release/main` (08, seção 7).

## Estrutura

A árvore completa está em [08, seção 2](https://github.com/pedrorico79/TEM-NA-FESTA-infraestrutura/blob/develop/specs/08-estrutura-do-repositorio.md).

## Conteúdo antigo

O conteúdo anterior às specs foi removido na E0 e está preservado na tag **`legacy-pre-specs`** (`git checkout legacy-pre-specs`). Essa tag nunca é movida (08, seção 7).

## Versões entregues

| Versão | Etapa | Observação |
|---|---|---|
| – | E0 | estrutura do repositório, ainda sem versão marcada |
