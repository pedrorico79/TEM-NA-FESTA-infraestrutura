-- Pergunta 3 da EBD (seção 1.2): o consumo real ao lado da estabilidade da
-- demanda digital (faixa de sazonalidade).
CREATE OR REPLACE VIEW vw_pof_trends_consumo_x_estabilidade AS
SELECT
  produto_id,
  produto_ibge,
  consumo_kg_sp,
  fator_sazonalidade,
  faixa_sazonalidade,
  mes_pico,
  evento_associado,
  data_coleta
FROM vw_pof_trends_sazonalidade
