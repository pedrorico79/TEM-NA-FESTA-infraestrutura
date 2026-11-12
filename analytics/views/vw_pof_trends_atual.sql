-- Base da EBD: a coleta mais recente (maior data_coleta), uma linha por produto.
CREATE OR REPLACE VIEW vw_pof_trends_atual AS
SELECT *
FROM pof_trends_resumo
WHERE data_coleta = (SELECT max(data_coleta) FROM pof_trends_resumo)
