# TEM-NA-FESTA-infraestrutura

Infraestrutura do **Tem Na Festa** na AWS (AWS Academy Learner Lab): Terraform em duas camadas, Docker Swarm em EC2 e um único comando, o `infra`, para criar, acompanhar e destruir os ambientes `dev` e `prod`.

As **specs em [`specs/`](specs/)** são a fonte da verdade: comece por [`00-indice.md`](specs/00-indice.md). Toda mudança de comportamento entra primeiro no spec, no mesmo PR (08, seção 7).

## Como começar

No Windows, prepare antes o WSL e as ferramentas com o guia [`docs/primeiros-passos-windows.md`](docs/primeiros-passos-windows.md). O `infra` roda no terminal do Ubuntu (WSL), **nunca no PowerShell**.

```bash
./infra doctor        # confere ferramentas, credenciais do laboratório e região
./infra bootstrap     # uma vez por conta: buckets de state e bronze
./infra up dev        # cria o ambiente dev e espera ele ficar pronto
```

Para destruir: `./infra down dev`. Todos os comandos estão em `./infra --help` e em [08, seção 5](specs/08-estrutura-do-repositorio.md).

> **Situação atual:** código das etapas **E0 a E8** do plano ([09](specs/09-plano-de-implementacao.md)) pronto: rede, nós, Swarm, banco com snapshots, ALB, as quatro stacks (RabbitMQ, backend, microsserviço de notificações e frontend) e o deploy contínuo pelo Docker Hub. Os testes ao vivo de E6, E7 e E8 e o aceite final (E9) ainda vão ser rodados no laboratório; a situação de cada teste está em [`tests/TRACEABILITY.md`](tests/TRACEABILITY.md).

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

3. No cliente MySQL, crie o perfil e o usuário, colando o hash do passo 1 (troque nome e e-mail):

   ```sql
   INSERT INTO perfil (nome, descricao) SELECT 'ADMIN', 'Administrador'
     WHERE NOT EXISTS (SELECT 1 FROM perfil WHERE nome = 'ADMIN');
   INSERT INTO usuario (nome, email, senha, is_ativo, is_deletado, data_criacao, perfil_id)
     SELECT 'Administrador', 'admin@exemplo.com', '<hash do passo 1>', TRUE, FALSE, NOW(), id
     FROM perfil WHERE nome = 'ADMIN';
   ```

O backend compara a senha com o hash BCrypt (`ROLE_ADMIN` vem do perfil `ADMIN`). Não guarde a senha nem o hash no repositório.

## Para quem desenvolve

```bash
make check            # formatação, lint, testes e rastreabilidade, como no CI
make trace            # só a rastreabilidade dos testes (make trace STRICT=1 na E9)
```

O `make check` não usa credenciais da AWS e é o mesmo que roda no [`ci-infra.yml`](.github/workflows/ci-infra.yml). A tabela [`tests/TRACEABILITY.md`](tests/TRACEABILITY.md) liga cada ID de teste dos specs à etapa e ao verificador.

## Estrutura

A árvore completa está em [08, seção 2](specs/08-estrutura-do-repositorio.md). Pastas ainda sem conteúdo têm um `README.md` dizendo em que etapa são preenchidas.

## Conteúdo antigo

O conteúdo anterior às specs foi removido na E0 e está preservado na tag **`legacy-pre-specs`** (`git checkout legacy-pre-specs`). Essa tag nunca é movida (08, seção 7).

## Versões entregues

| Versão | Etapa | Observação |
|---|---|---|
| – | E0 | estrutura do repositório, ainda sem versão marcada |
