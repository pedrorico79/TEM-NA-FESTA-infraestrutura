-- Discretização da EBD, seção 3.2: tercis do fator de sazonalidade da coleta
-- atual, recalculados a cada coleta.
CREATE OR REPLACE VIEW vw_pof_trends_sazonalidade AS
WITH cortes AS (
  SELECT
    approx_percentile(fator_sazonalidade, 0.33) AS p33,
    approx_percentile(fator_sazonalidade, 0.66) AS p66
  FROM vw_pof_trends_atual
)
SELECT
  a.*,
  CASE
    WHEN a.fator_sazonalidade <= c.p33 THEN 'Baixa sazonalidade'
    WHEN a.fator_sazonalidade <= c.p66 THEN 'Sazonalidade moderada'
    ELSE 'Alta sazonalidade'
  END AS faixa_sazonalidade
FROM vw_pof_trends_atual a
CROSS JOIN cortes c
