-- Produtos do sistema: a coleta mais recente de cada ambiente. Os produtos sem
-- dados no Google Trends aparecem como "Sem dados suficientes" (EBD, seção 5).
CREATE OR REPLACE VIEW vw_tendencias_produtos_atual AS
WITH ultima AS (
  SELECT env, max(data_coleta) AS data_coleta
  FROM tendencias_produtos_resumo
  GROUP BY env
)
SELECT
  r.env, r.data_coleta, r.produto_id, r.produto_nome, r.preco_venda,
  r.popularidade_media, r.popularidade_pico, r.mes_pico, r.fator_sazonalidade,
  r.tipo_feriado_pico, r.evento_associado,
  'Com dados' AS situacao
FROM tendencias_produtos_resumo r
JOIN ultima u ON r.env = u.env AND r.data_coleta = u.data_coleta
UNION ALL
SELECT
  j.env, j.data_coleta, j.produto_id, j.produto AS produto_nome, CAST(NULL AS double),
  CAST(NULL AS double), CAST(NULL AS double), CAST(NULL AS integer), CAST(NULL AS double),
  CAST(NULL AS varchar), CAST(NULL AS varchar),
  'Sem dados suficientes' AS situacao
FROM tendencias_produtos_rejeicoes j
JOIN ultima u ON j.env = u.env AND j.data_coleta = u.data_coleta
WHERE j.severidade = 'aviso'
