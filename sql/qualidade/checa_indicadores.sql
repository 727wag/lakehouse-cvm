-- Checagem de qualidade lida pela Step Function: só segue se o resultado for 'OK'.
-- 1. A SPEC precisa ter dados recentes.
-- 2. Não pode haver mais de uma linha por empresa e trimestre.
-- 3. Ativo total não pode faltar para a maioria das empresas (sinal de mudança na fonte).
WITH recentes AS (
  SELECT *
  FROM cvm_spec.indicadores_trimestrais
  WHERE data_ref >= date_add('month', -15, current_date)
),
duplicadas AS (
  SELECT count(*) AS qtd
  FROM (
    SELECT cnpj_cia, data_ref
    FROM cvm_spec.indicadores_trimestrais
    GROUP BY cnpj_cia, data_ref
    HAVING count(*) > 1
  )
)
SELECT
  CASE
    WHEN (SELECT count(*) FROM recentes) = 0 THEN 'SEM_DADOS_RECENTES'
    WHEN (SELECT qtd FROM duplicadas) > 0 THEN 'CHAVE_DUPLICADA'
    WHEN (SELECT avg(CASE WHEN ativo_total IS NULL THEN 1.0 ELSE 0.0 END) FROM recentes) > 0.5
      THEN 'ATIVO_TOTAL_AUSENTE'
    ELSE 'OK'
  END AS status
