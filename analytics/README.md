# Camada Glue e Athena

Esta camada cataloga no Glue os arquivos bronze dos produtos ativos do sistema e dos logs, cria o workgroup `tnf` do Athena e instala as visões de consulta. Ela é compartilhada entre os ambientes e não executa coletas.

- `infra analytics plan` mostra o plano do catálogo e do workgroup.
- `infra analytics up` aplica a camada, remove as tabelas e visões POF antigas e cria `vw_tendencias_produtos_atual` no Athena. Os objetos históricos no S3 não são apagados.
- `infra dataset run dev` ou `infra dataset run prod` aciona a Lambda de produtos do ambiente.

A Lambda `tnf-<env>-tendencias` é provisionada junto do ambiente em `modules/datasets`. Ela consulta a API do backend e grava `datasets/tendencias_produtos/{bruto,resumo,serie,rejeicoes}/` no bronze. A origem POF não faz parte desta camada.

Consultas: workgroup `tnf`, banco `tnf_bronze`. A coluna `date` das tabelas de logs precisa de aspas (`"date"`).
