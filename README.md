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

> **Situação atual:** etapa **E2** do plano ([09](specs/09-plano-de-implementacao.md)): `infra doctor`, `infra session` e `infra bootstrap` funcionam; os outros comandos dizem em que etapa chegam.

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
