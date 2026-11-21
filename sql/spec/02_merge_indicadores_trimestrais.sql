-- Recalcula os últimos 15 meses (pega reapresentações da CVM) e aplica com MERGE.
-- Rodar de novo não duplica: a chave é (cnpj_cia, data_ref).
--
-- As contas são identificadas pela descrição padronizada da CVM (contas fixas).
-- Antes de confiar nos números, valide com sql/analises/descobrir_contas.sql.
-- O 4º trimestre não existe no ITR (vem na DFP anual), por isso não aparece aqui.
MERGE INTO cvm_spec.indicadores_trimestrais t
USING (
  WITH base AS (
    SELECT *
    FROM cvm_sot.demonstracoes
    WHERE dt_refer >= date_add('month', -15, current_date)
      AND ordem_exerc = 'ÚLTIMO'
  ),
  empresas AS (
    SELECT cnpj_cia, dt_refer, max(cd_cvm) AS cd_cvm, max(denom_cia) AS empresa
    FROM base
    GROUP BY cnpj_cia, dt_refer
  ),
  ativo AS (
    SELECT cnpj_cia, dt_refer, max(vl_conta) AS valor
    FROM base
    WHERE demonstrativo = 'BPA_con' AND cd_conta = '1'
    GROUP BY cnpj_cia, dt_refer
  ),
  patrimonio AS (
    SELECT cnpj_cia, dt_refer, max(vl_conta) AS valor
    FROM base
    WHERE demonstrativo = 'BPP_con'
      AND lower(trim(ds_conta)) = 'patrimônio líquido consolidado'
    GROUP BY cnpj_cia, dt_refer
  ),
  lucro AS (
    -- O ITR traz o valor do trimestre e o acumulado do ano. O trimestre tem até 3 meses.
    SELECT cnpj_cia, dt_refer, max(vl_conta) AS valor
    FROM base
    WHERE demonstrativo = 'DRE_con'
      AND lower(trim(ds_conta)) IN ('lucro/prejuízo consolidado do período', 'lucro ou prejuízo líquido consolidado do período')
      AND date_diff('month', dt_ini_exerc, dt_fim_exerc) < 3
    GROUP BY cnpj_cia, dt_refer
  )
  SELECT
    e.dt_refer AS data_ref,
    e.cnpj_cia,
    e.cd_cvm,
    e.empresa,
    a.valor AS ativo_total,
    p.valor AS patrimonio_liquido,
    l.valor AS lucro_liquido_trimestre,
    CASE WHEN p.valor > 0 THEN CAST(l.valor AS double) / CAST(p.valor AS double) END AS roe_trimestral,
    CAST(current_timestamp AS timestamp(6)) AS calculado_em
  FROM empresas e
  LEFT JOIN ativo      a ON a.cnpj_cia = e.cnpj_cia AND a.dt_refer = e.dt_refer
  LEFT JOIN patrimonio p ON p.cnpj_cia = e.cnpj_cia AND p.dt_refer = e.dt_refer
  LEFT JOIN lucro      l ON l.cnpj_cia = e.cnpj_cia AND l.dt_refer = e.dt_refer
) s
ON t.cnpj_cia = s.cnpj_cia AND t.data_ref = s.data_ref
WHEN MATCHED THEN UPDATE SET
  cd_cvm = s.cd_cvm,
  empresa = s.empresa,
  ativo_total = s.ativo_total,
  patrimonio_liquido = s.patrimonio_liquido,
  lucro_liquido_trimestre = s.lucro_liquido_trimestre,
  roe_trimestral = s.roe_trimestral,
  calculado_em = s.calculado_em
WHEN NOT MATCHED THEN INSERT
  (data_ref, cnpj_cia, cd_cvm, empresa, ativo_total, patrimonio_liquido, lucro_liquido_trimestre, roe_trimestral, calculado_em)
  VALUES
  (s.data_ref, s.cnpj_cia, s.cd_cvm, s.empresa, s.ativo_total, s.patrimonio_liquido, s.lucro_liquido_trimestre, s.roe_trimestral, s.calculado_em)
