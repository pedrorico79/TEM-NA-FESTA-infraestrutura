# `analytics/`

Camada persistente de dados analíticos (spec 10, DA5): a Lambda semanal da base da "Especificação de Base de Dados" (POF/IBGE + Google Trends), o banco `tnf_bronze` do Glue com as tabelas declaradas e *partition projection*, o workgroup `tnf` do Athena e a configuração do bucket de resultados. Fica no ar com ou sem ambiente; o `infra down` não a toca.

- `./infra analytics plan` e `./infra analytics up`: empacotam a Lambda na tag `dataset_ref`, criam o bucket de resultados (AWS CLI) e aplicam. O `up` também cria no Athena as visões de `views/`.
- `./infra dataset run pof-trends`: roda a coleta da base da EBD agora, sem esperar a segunda-feira.
- Consultas: no console do Athena, workgroup `tnf`, banco `tnf_bronze`. A coluna `date` das tabelas de logs precisa de aspas (`"date"`).
