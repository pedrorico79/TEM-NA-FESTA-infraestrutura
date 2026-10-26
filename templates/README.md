# `templates/`

`deploy.yml` é o modelo do workflow de deploy dos repositórios de aplicação (07, seção 4): constrói a imagem da branch ou tag escolhida, publica `<namespace>/tnf-<stack>:sha-<7>` no Docker Hub e aponta a etiqueta do ambiente (`dev` ou `prod`) para ela. Inclui a trava de prod (4.5), a conferência dos `VITE_*` (4.4) e o `reuse_tag` para voltar atrás (4.1).

## Como usar num repositório de aplicação
1. Copie o arquivo para `.github/workflows/deploy.yml` do repositório, no lugar do workflow antigo de ECR (C8).
2. Ajuste só o bloco `env` do job:

| Repositório | `STACK` | `TEST_IMAGE` | `TEST_CMD` |
|---|---|---|---|
| `TEM-NA-FESTA-frontend` | `frontend` | – | vazio (sem testes automatizados) |
| `TEM-NA-FESTA-backend` | `backend` | `maven:3.9.6-eclipse-temurin-21` | `mvn -B -q test` |
| `TEM-NA-FESTA-microservice` | `messaging` | – | vazio (sem testes automatizados) |

   `DOCKERHUB_NAMESPACE` tem de ser igual a `dockerhub_namespace` de `envs/<env>/terraform.tfvars`.
3. Cadastre no GitHub (Settings → Secrets and variables → Actions) os *secrets* `DOCKERHUB_USERNAME` e `DOCKERHUB_TOKEN` (token com escrita) e, no frontend, uma **variável** (aba Variables) para cada `ARG VITE_*` do Dockerfile, com o mesmo nome.

## Comportamento que vale saber
- Se a imagem `sha-<7>` do commit já existe, nada é construído: só a etiqueta do ambiente muda, e o digest fica o mesmo (C3). Para embutir valores novos de `VITE_*`, faça um commit.
- A etiqueta do ambiente é movida por cópia do manifesto no registro (`crane tag`), então `:<env>` e `:sha-<7>` têm o mesmo digest.
- As consultas ao registro são só de manifesto e não consomem a cota de baixadas.

Os passos da trava de prod e dos `VITE_*` são testados fora do GitHub em `tests/shell/deploy-template.bats`.
