"""Glue job (PySpark): SOR (CSVs da CVM) -> SOT em Apache Iceberg.

- Lê cada demonstrativo separadamente (BPA, BPP e DRE têm colunas diferentes).
- Padroniza nomes e tipos e converte os valores para reais (ESCALA_MOEDA).
- Mantém só a versão mais recente de cada linha (a CVM publica reapresentações).
- Grava com MERGE na tabela Iceberg cvm_sot.demonstracoes, então pode rodar
  quantas vezes for preciso sem duplicar.

As funções no topo do arquivo não dependem do Spark, para poderem ser testadas
com pytest. O Spark só é importado dentro de main().

Parâmetros do job: --BUCKET
"""

from __future__ import annotations

DEMONSTRATIVOS = ("BPA_con", "BPP_con", "DRE_con")
TABELA_SOT = "glue_catalog.cvm_sot.demonstracoes"
ENCODING_CVM = "ISO-8859-1"

MULTIPLICADOR_ESCALA = {"UNIDADE": 1, "MIL": 1000}

# Colunas que identificam uma linha de um demonstrativo.
CHAVE_NEGOCIO = (
    "cnpj_cia",
    "dt_refer",
    "demonstrativo",
    "cd_conta",
    "ordem_exerc",
    "dt_ini_exerc",
    "dt_fim_exerc",
)

COLUNAS_SOT = (
    "cnpj_cia",
    "cd_cvm",
    "denom_cia",
    "dt_refer",
    "versao",
    "demonstrativo",
    "grupo_dfp",
    "ordem_exerc",
    "dt_ini_exerc",
    "dt_fim_exerc",
    "cd_conta",
    "ds_conta",
    "st_conta_fixa",
    "vl_conta",
    "ingerido_em",
)


def multiplicador(escala: str | None) -> int:
    """Fator para converter VL_CONTA em reais. Escala desconhecida é erro, não chute."""
    chave = (escala or "").strip().upper()
    if chave not in MULTIPLICADOR_ESCALA:
        raise ValueError(f"ESCALA_MOEDA desconhecida: {escala!r}")
    return MULTIPLICADOR_ESCALA[chave]


def caminho_demonstrativo(bucket: str, demonstrativo: str) -> str:
    return f"s3://{bucket}/sor/cvm_itr/demonstrativo={demonstrativo}/"


def condicao_merge(chave: tuple[str, ...] = CHAVE_NEGOCIO) -> str:
    """ON do MERGE com comparação null-safe (<=>).

    dt_ini_exerc é nulo nos balanços (BPA/BPP). Com '=', NULL = NULL é falso
    e cada execução inseriria tudo de novo.
    """
    return " AND ".join(f"t.{coluna} <=> s.{coluna}" for coluna in chave)


def sql_merge(origem: str, destino: str = TABELA_SOT) -> str:
    atualiza = ", ".join(f"t.{c} = s.{c}" for c in COLUNAS_SOT if c not in CHAVE_NEGOCIO)
    return (
        f"MERGE INTO {destino} t USING {origem} s ON {condicao_merge()} "
        f"WHEN MATCHED AND s.versao >= t.versao THEN UPDATE SET {atualiza} "
        f"WHEN NOT MATCHED THEN INSERT *"
    )


def sql_cria_tabela(bucket: str, destino: str = TABELA_SOT) -> str:
    return f"""
        CREATE TABLE IF NOT EXISTS {destino} (
            cnpj_cia string, cd_cvm string, denom_cia string,
            dt_refer date, versao int, demonstrativo string, grupo_dfp string,
            ordem_exerc string, dt_ini_exerc date, dt_fim_exerc date,
            cd_conta string, ds_conta string, st_conta_fixa string,
            vl_conta decimal(38,2), ingerido_em timestamp_ntz
        )
        USING iceberg
        PARTITIONED BY (years(dt_refer))
        LOCATION 's3://{bucket}/sot/cvm_demonstracoes/'
        TBLPROPERTIES ('format-version'='2', 'write.parquet.compression-codec'='snappy')
    """


def main() -> None:
    import sys

    from awsglue.utils import getResolvedOptions
    from pyspark.conf import SparkConf
    from pyspark.sql import SparkSession, Window
    from pyspark.sql import functions as F

    args = getResolvedOptions(sys.argv, ["JOB_NAME", "BUCKET"])
    bucket = args["BUCKET"]

    conf = (
        SparkConf()
        .set("spark.sql.extensions", "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions")
        .set("spark.sql.catalog.glue_catalog", "org.apache.iceberg.spark.SparkCatalog")
        .set("spark.sql.catalog.glue_catalog.warehouse", f"s3://{bucket}/sot/")
        .set("spark.sql.catalog.glue_catalog.catalog-impl", "org.apache.iceberg.aws.glue.GlueCatalog")
        .set("spark.sql.catalog.glue_catalog.io-impl", "org.apache.iceberg.aws.s3.S3FileIO")
    )
    spark = SparkSession.builder.config(conf=conf).getOrCreate()

    partes = []
    for demonstrativo in DEMONSTRATIVOS:
        bruto = (
            spark.read.option("header", True)
            .option("sep", ";")
            .option("encoding", ENCODING_CVM)
            .csv(caminho_demonstrativo(bucket, demonstrativo))
        )
        if "DT_INI_EXERC" not in bruto.columns:  # balanços não têm início de exercício
            bruto = bruto.withColumn("DT_INI_EXERC", F.lit(None).cast("string"))

        # Valida as escalas presentes no arquivo: uma escala nova quebra o job
        # em vez de gravar valores errados em silêncio.
        escalas = [linha[0] for linha in bruto.select("ESCALA_MOEDA").distinct().collect()]
        expr_multiplicador = F.lit(None).cast("int")
        for escala in escalas:
            expr_multiplicador = F.when(
                F.col("ESCALA_MOEDA") == escala, F.lit(multiplicador(escala))
            ).otherwise(expr_multiplicador)

        partes.append(
            bruto.select(
                F.col("CNPJ_CIA").alias("cnpj_cia"),
                F.col("CD_CVM").alias("cd_cvm"),
                F.col("DENOM_CIA").alias("denom_cia"),
                F.to_date("DT_REFER").alias("dt_refer"),
                F.col("VERSAO").cast("int").alias("versao"),
                F.lit(demonstrativo).alias("demonstrativo"),
                F.col("GRUPO_DFP").alias("grupo_dfp"),
                F.col("ORDEM_EXERC").alias("ordem_exerc"),
                F.to_date("DT_INI_EXERC").alias("dt_ini_exerc"),
                F.to_date("DT_FIM_EXERC").alias("dt_fim_exerc"),
                F.col("CD_CONTA").alias("cd_conta"),
                F.col("DS_CONTA").alias("ds_conta"),
                F.col("ST_CONTA_FIXA").alias("st_conta_fixa"),
                (F.col("VL_CONTA").cast("decimal(38,2)") * expr_multiplicador)
                .cast("decimal(38,2)")
                .alias("vl_conta"),
                F.current_timestamp().cast("timestamp_ntz").alias("ingerido_em"),
            )
        )

    unido = partes[0]
    for parte in partes[1:]:
        unido = unido.unionByName(parte)

    ultima_versao = Window.partitionBy(*CHAVE_NEGOCIO).orderBy(F.col("versao").desc())
    deduplicado = (
        unido.withColumn("_rn", F.row_number().over(ultima_versao))
        .filter("_rn = 1")
        .drop("_rn")
        .select(*COLUNAS_SOT)
    )

    spark.sql(sql_cria_tabela(bucket))  # o database "cvm_sot" é criado pelo Terraform
    deduplicado.createOrReplaceTempView("origem_sot")
    spark.sql(sql_merge("origem_sot"))

    total = spark.table(TABELA_SOT).count()
    print(f"SOT atualizada: {total} linhas em {TABELA_SOT}", flush=True)


if __name__ == "__main__":
    main()
