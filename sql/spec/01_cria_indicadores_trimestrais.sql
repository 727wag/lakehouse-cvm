-- Camada SPEC: indicadores trimestrais por empresa, prontos para o dashboard.
-- Executado pela Step Function antes do MERGE. IF NOT EXISTS torna o passo idempotente.
CREATE TABLE IF NOT EXISTS cvm_spec.indicadores_trimestrais (
  data_ref                date,
  cnpj_cia                string,
  cd_cvm                  string,
  empresa                 string,
  ativo_total             decimal(38,2),
  patrimonio_liquido      decimal(38,2),
  lucro_liquido_trimestre decimal(38,2),
  roe_trimestral          double,
  calculado_em            timestamp
)
PARTITIONED BY (year(data_ref))
LOCATION 's3://${bucket}/spec/indicadores_trimestrais/'
TBLPROPERTIES (
  'table_type'        = 'ICEBERG',
  'format'            = 'parquet',
  'write_compression' = 'snappy'
)
