-- Rode no Athena depois da primeira carga para conferir quais descrições de conta
-- existem e ajustar os filtros de 02_merge_indicadores_trimestrais.sql se precisar.
-- Bancos usam um plano de contas diferente das empresas não financeiras.
SELECT
  demonstrativo,
  cd_conta,
  ds_conta,
  count(DISTINCT cnpj_cia) AS empresas
FROM cvm_sot.demonstracoes
WHERE ordem_exerc = 'ÚLTIMO'
  AND st_conta_fixa = 'S'
  AND (
    regexp_like(lower(ds_conta), 'patrim[oô]nio l[ií]quido')
    OR regexp_like(lower(ds_conta), 'lucro.*per[ií]odo')
    OR cd_conta = '1'
  )
GROUP BY demonstrativo, cd_conta, ds_conta
ORDER BY empresas DESC
LIMIT 50;

-- Conferência dos bancos: troque o filtro pelo nome que quiser analisar.
SELECT data_ref, empresa, ativo_total, patrimonio_liquido, lucro_liquido_trimestre, roe_trimestral
FROM cvm_spec.indicadores_trimestrais
WHERE regexp_like(upper(empresa), 'ITAU|BRADESCO|BANCO DO BRASIL|SANTANDER|BTG')
ORDER BY empresa, data_ref DESC;
