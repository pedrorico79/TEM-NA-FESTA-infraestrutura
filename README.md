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

> **Situação atual:** etapa **E4b** do plano ([09](specs/09-plano-de-implementacao.md)): `infra up` cria a rede, os nós, o Swarm e o banco (RDS com o schema da tag fixada e snapshots); `infra snapshot` e `infra snapshots` funcionam. As stacks chegam na E6.

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
