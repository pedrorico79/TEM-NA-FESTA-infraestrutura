# Rastreabilidade dos testes

Cada ID de teste das tabelas "Critérios de aceite" dos specs 03 a 09 tem aqui uma linha com a **etapa** de 09 em que é verificado, o **verificador** e a **situação** (08, seção 7; 09, seção 1). A conferência é automática: `make trace` (parte do `make check` e do CI) roda o `scripts/check-traceability.sh`; na E9 roda `make trace STRICT=1`.

- **Etapa:** E0 a E9, com a E4 dividida em E4a e E4b, como nas listas "Pronto quando" de 09. Um ID citado em mais de uma etapa fica na última em que é citado, onde a verificação fecha.
- **Verificador:** um arquivo `terraform test`, um teste `bats` ou "manual: <procedimento>". As conferências manuais no laboratório e no GitHub são executadas pelo autor, que traz a evidência; só então a linha passa a `verificado`.
- **Situação:** `pendente`, `verificado` ou `não aplicável nesta entrega: <motivo>`.
- Ao incluir ou mover um ID de teste, atualize esta tabela e a etapa de 09 no mesmo PR. Não use o caractere `|` dentro das células.

| ID | Etapa | Verificador | Situação |
|---|---|---|---|
| T1 | E1 | tests/contract/T1.tftest.hcl | pendente |
| T2 | E1 | tests/contract/T2.tftest.hcl | pendente |
| T3 | E1 | tests/contract/T3.tftest.hcl | pendente |
| T4 | E1 | tests/contract/T4.tftest.hcl | pendente |
| T5 | E1 | tests/contract/T5.tftest.hcl | pendente |
| T6 | E1 | tests/contract/T6.tftest.hcl | pendente |
| T7 | E1 | tests/contract/T7.tftest.hcl | pendente |
| T8 | E1 | tests/contract/T8.tftest.hcl | pendente |
| T9 | E1 | tests/contract/T9.tftest.hcl | pendente |
| T10 | E1 | tests/contract/T10.tftest.hcl | pendente |
| T11 | E1 | tests/contract/T11.tftest.hcl | pendente |
| T12 | E1 | tests/contract/T12.tftest.hcl | pendente |
| T13 | E4a | manual: no laboratório, ami_id de outra região dá erro do provedor (limitação documentada, não automatizada) | pendente |
| T14 | E1 | tests/contract/T14.tftest.hcl | pendente |
| T15 | E1 | tests/contract/T15.tftest.hcl | pendente |
| T16 | E1 | tests/contract/T16.tftest.hcl | pendente |
| T17 | E6 | tests/contract/T17.tftest.hcl | pendente |
| S1 | E6 | manual: no laboratório, infra up dev do zero até o ALB responder 200, com o tempo medido | pendente |
| S2 | E6 | manual: no laboratório, infra up repetido sem mudanças não altera nada | pendente |
| S3 | E6 | manual: no laboratório, backend de 1 para 2 réplicas com infra up | pendente |
| S4 | E4a | manual: no laboratório, parar o líder com manager_count = 3 | pendente |
| S5 | E9 | manual: no laboratório, infra down e infra up com o banco restaurado do snapshot final | pendente |
| S6 | E4a | manual: no laboratório, remover a rota da NAT durante a subida | pendente |
| S7 | E1 | tests/contract/T4.tftest.hcl (mesmo verificador de T4) | pendente |
| S8 | E7 | manual: no laboratório, mover a etiqueta do ambiente para uma imagem nova | pendente |
| S9 | E4b | manual: no laboratório, reiniciar o timer de convergência ou trocar o líder sem repetir o db-init | pendente |
| S10 | E4b | manual: no laboratório, primeira subida sem snapshot com o db-init | pendente |
| S11 | E7 | manual: no laboratório, primeira subida com a etiqueta do backend numa imagem que não fica saudável | pendente |
| S12 | E3 | manual: no laboratório, interromper o infra up com kill -9 e recuperar o lock | pendente |
| S13 | E6 | manual: no laboratório, aumentar e reduzir nós web com o ambiente no ar | pendente |
| S14 | E6 | manual: no laboratório, manager_count recusado e worker esperado parado vira degraded | pendente |
| Q1 | E4a | manual: no laboratório, conferência descrita em 05, Q1 | pendente |
| Q2 | E6 | manual: no laboratório, conferência descrita em 05, Q2 | pendente |
| Q3 | E9 | manual: no laboratório, conferência descrita em 05, Q3 | pendente |
| Q4 | E4b | manual: no laboratório, conferência descrita em 05, Q4 | pendente |
| Q5 | E4b | manual: no laboratório, conferência descrita em 05, Q5 | pendente |
| Q6 | E9 | manual: no laboratório, conferência descrita em 05, Q6 | pendente |
| Q7 | E4b | manual: no laboratório, conferência descrita em 05, Q7 | pendente |
| Q8 | E8 | bats: tests/shell/secrets-env.bats (Q8) e manual: no laboratório, infra up com e sem secrets.env | pendente |
| Q9 | E2 | manual: no laboratório, inspecionar os buckets de state e bronze | pendente |
| Q10 | E6 | manual: no laboratório, conferência descrita em 05, Q10 | pendente |
| Q11 | E4b | manual: no laboratório, conferência descrita em 05, Q11 | pendente |
| Q12 | E7 | manual: no laboratório, conferência descrita em 05, Q12 | pendente |
| Q13 | E4b | manual: no laboratório, conferência descrita em 05, Q13 | pendente |
| Q14 | E6 | manual: no laboratório, conferência descrita em 05, Q14 | pendente |
| Q15 | E4b | manual: no laboratório, conferência descrita em 05, Q15 | pendente |
| Q16 | E6 | manual: no laboratório, conferência descrita em 05, Q16 | pendente |
| Q17 | E4a | manual: no laboratório, conferência descrita em 05, Q17 | pendente |
| Q18 | E6 | manual: no laboratório, conferência descrita em 05, Q18 | pendente |
| Q19 | E4b | manual: no laboratório, conferência descrita em 05, Q19 | pendente |
| Q20 | E4b | manual: no laboratório, conferência descrita em 05, Q20 | pendente |
| Q21 | E4b | manual: no laboratório, conferência descrita em 05, Q21 | pendente |
| Q22 | E6 | manual: no laboratório, conferência descrita em 05, Q22 | pendente |
| Q23 | E8 | manual: no laboratório, conferência descrita em 05, Q23 | pendente |
| Q24 | E4b | manual: no laboratório, conferência descrita em 05, Q24 | pendente |
| R1 | E6 | manual: no laboratório, conferência descrita em 06, R1 | pendente |
| R2 | E6 | manual: no laboratório, conferência descrita em 06, R2 | pendente |
| R3 | E6 | manual: no laboratório, conferência descrita em 06, R3 | pendente |
| R4 | E6 | manual: no laboratório, conferência descrita em 06, R4 | pendente |
| R5 | E8 | manual: no laboratório, conferência descrita em 06, R5 | pendente |
| R6 | E6 | manual: no laboratório, conferência descrita em 06, R6 | pendente |
| R7 | E7 | manual: no laboratório, conferência descrita em 06, R7 | pendente |
| R8 | E7 | manual: no laboratório, conferência descrita em 06, R8 | pendente |
| R9 | E6 | tests/contract/T14.tftest.hcl (mesmo verificador de T14) | pendente |
| R10 | E6 | manual: no laboratório, conferência descrita em 06, R10 | pendente |
| R11 | E6 | manual: no laboratório, conferência descrita em 06, R11 | pendente |
| R12 | E8 | manual: no laboratório, conferência descrita em 06, R12 | pendente |
| R13 | E7 | manual: no laboratório, conferência descrita em 06, R13 | pendente |
| R14 | E8 | manual: no laboratório, conferência descrita em 06, R14 | pendente |
| R15 | E6 | tests/contract/T17.tftest.hcl (mesmo verificador de T17) | pendente |
| R16 | E6 | manual: no laboratório, conferência descrita em 06, R16 | pendente |
| R17 | E8 | manual: no laboratório, conferência descrita em 06, R17 | pendente |
| C1 | E5 | manual: no GitHub Actions, conferência descrita em 07, C1 | pendente |
| C2 | E7 | manual: no laboratório, infra status depois do deploy do C1 | pendente |
| C3 | E5 | manual: no GitHub Actions, conferência descrita em 07, C3 | pendente |
| C4 | E5 | manual: no GitHub Actions, conferência descrita em 07, C4 | pendente |
| C5 | E7 | manual: no GitHub Actions, deploy de imagem que não fica saudável; manual: no laboratório, infra status com failed_tag | pendente |
| C6 | E5 | manual: no GitHub Actions, conferência descrita em 07, C6 | pendente |
| C7 | E5 | manual: no GitHub Actions, conferência descrita em 07, C7 | pendente |
| C8 | E5 | manual: conferir workflows e secrets dos repositórios (na E0, só o de infra: nenhum workflow de ECR) | pendente |
| C9 | E8 | manual: no laboratório, infra up de ambiente novo baixa as imagens sem login | pendente |
| C10 | E1 | manual: no GitHub Actions, PR de teste com manager_count = 2 em envs/dev | pendente |
| C11 | E0 | manual: no GitHub Actions, execução do ci-infra.yml sem credenciais da AWS | pendente |
| C12 | E5 | manual: no GitHub Actions, conferência descrita em 07, C12 | pendente |
| C13 | E7 | manual: no laboratório, infra down e infra up com a etiqueta ainda na imagem ruim | pendente |
| C14 | E7 | manual: no GitHub Actions, deploy corrigido ou reuse_tag; manual: no laboratório, converge.json volta a ready | pendente |
| C15 | E5 | manual: no GitHub Actions, conferência descrita em 07, C15 | pendente |
| C16 | E5 | manual: no GitHub Actions, conferência descrita em 07, C16 | pendente |
| C17 | E5 | manual: docker run com --entrypoint sh nas imagens publicadas | pendente |
| C18 | E5 | manual: no GitHub Actions, conferência descrita em 07, C18 | pendente |
| C19 | E5 | manual: no GitHub Actions, conferência descrita em 07, C19 | pendente |
| G1 | E0 | bats: tests/shell/infra-doctor.bats (G1) e manual: infra doctor num clone novo, com as credenciais do laboratório | verificado |
| G2 | E0 | make check sem credenciais da AWS (local e no ci-infra.yml) | verificado |
| G3 | E0 | bats: tests/shell/repo-hygiene.bats (G3) e gitleaks no ci-infra.yml | pendente |
| G4 | E1 | bats: tests/shell/envs.bats (G4) | pendente |
| G5 | E2 | manual: no laboratório, infra bootstrap duas vezes | pendente |
| G6 | E2 | manual: no laboratório, tentar destruir o bootstrap com objetos nos buckets | pendente |
| G7 | E2 | bats: tests/shell/infra.bats (G7) | pendente |
| G8 | E3 | bats: tests/shell/infra.bats (G8) | pendente |
| G9 | E4a | manual: no laboratório, web_node_count de 2 para 3 no plan | pendente |
| G10 | E9 | bats: tests/shell/check-traceability.bats (G10a a G10h) e make trace (STRICT=1 na E9) | pendente |
| G11 | E4a | manual: no laboratório, infra ssh dev app-1 | pendente |
| G12 | E0 | bats: tests/shell/repo-hygiene.bats (G12) e make check (check-lock) | verificado |
| G13 | E0 | bats: tests/shell/infra-doctor.bats (G13) | verificado |
| G14 | E0 | bats: tests/shell/repo-hygiene.bats (G14) e make check (check-eol) | verificado |
| G15 | E0 | manual: um colega, ou você numa máquina Windows limpa, segue docs/primeiros-passos-windows.md até o infra doctor rodar | pendente |
| G16 | E2 | bats: tests/shell/bootstrap.bats (G16) e manual: no laboratório, infra bootstrap com o bronze existente | pendente |
| G17 | E2 | bats: tests/shell/infra-doctor.bats (G17) e manual: no laboratório, infra doctor lista as sobras | pendente |
| G18 | E0 | manual: conferir a árvore de 08 seção 2, nenhum workflow de ECR e a tag legacy-pre-specs | verificado |
| G19 | E2 | bats: tests/shell/preflight.bats (G19) e manual: no laboratório, errored.tfstate | pendente |
| G20 | E3 | manual: no laboratório, interromper um apply com kill -9 e recuperar o lock | pendente |
| G21 | E2 | bats: tests/shell/preflight.bats (G21) | pendente |
| G22 | E4a | bats: tests/shell/preflight.bats (G22) e manual: no laboratório, mudar manager_count com o ambiente no ar | pendente |
| G23 | E4b | bats: tests/shell/snapshots.bats (G23) | pendente |
| G24 | E4a | bats: tests/shell/access.bats (G24) | pendente |
| G25 | E4a | manual: no laboratório, infra ssh de outra máquina e outra rede | pendente |
| P1 | E0 | manual: revisão de 09 (cada etapa tem entrega, Pronto quando e IDs existentes) | verificado |
| P2 | E0 | make trace (scripts/check-traceability.sh) | verificado |
| P3 | E9 | manual: registros de cada etapa ao vivo nesta tabela e infra doctor sem avisos | pendente |
| P4 | E0 | manual: revisão de 09, seção 2 (cada pré-requisito tem etapa de consumo) | verificado |
