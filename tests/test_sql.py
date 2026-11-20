"""Testes estáticos dos arquivos SQL: pegam erros comuns antes do deploy."""

import json
import re
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
SQL = RAIZ / "sql"
COLUNAS_SPEC = (
    "data_ref",
    "cnpj_cia",
    "cd_cvm",
    "empresa",
    "ativo_total",
    "patrimonio_liquido",
    "lucro_liquido_trimestre",
    "roe_trimestral",
    "calculado_em",
)
SQLS_STEP_FUNCTION = (
    "spec/01_cria_indicadores_trimestrais.sql",
    "spec/02_merge_indicadores_trimestrais.sql",
    "qualidade/checa_indicadores.sql",
)


def _ler(caminho: str) -> str:
    return (SQL / caminho).read_text(encoding="utf-8")


def test_merge_preenche_todas_as_colunas_da_spec():
    ddl = _ler("spec/01_cria_indicadores_trimestrais.sql")
    merge = _ler("spec/02_merge_indicadores_trimestrais.sql")
    insert = re.search(r"INSERT\s*\((.*?)\)", merge, re.S).group(1)
    colunas_insert = [c.strip() for c in insert.split(",")]
    assert colunas_insert == list(COLUNAS_SPEC)
    for coluna in COLUNAS_SPEC:
        assert re.search(rf"^\s*{coluna}\s", ddl, re.M), coluna


def test_merge_usa_chave_da_spec():
    merge = _ler("spec/02_merge_indicadores_trimestrais.sql")
    assert "ON t.cnpj_cia = s.cnpj_cia AND t.data_ref = s.data_ref" in merge


def test_ddl_spec_e_iceberg_e_usa_variavel_do_bucket():
    ddl = _ler("spec/01_cria_indicadores_trimestrais.sql")
    assert "'table_type'        = 'ICEBERG'" in ddl
    assert "${bucket}" in ddl


def test_sqls_da_step_function_nao_tem_ponto_e_virgula():
    # O Athena aceita uma instrução por chamada; ';' no fim quebra a execução.
    for caminho in SQLS_STEP_FUNCTION:
        assert ";" not in _ler(caminho), caminho


def test_qualidade_retorna_ok_como_sucesso():
    assert "ELSE 'OK'" in _ler("qualidade/checa_indicadores.sql")


def test_definicao_da_step_function_vira_json_valido():
    modelo = (RAIZ / "orquestracao" / "pipeline.asl.json.tftpl").read_text(encoding="utf-8")
    valores = {
        "lambda_ingestao": "arn:aws:lambda:us-east-1:123:function:x",
        "glue_job": "job",
        "workgroup": "wg",
        "sns_topico": "arn:aws:sns:us-east-1:123:t",
        "sql_cria_spec": json.dumps(_ler("spec/01_cria_indicadores_trimestrais.sql")),
        "sql_merge_spec": json.dumps(_ler("spec/02_merge_indicadores_trimestrais.sql")),
        "sql_qualidade": json.dumps(_ler("qualidade/checa_indicadores.sql")),
    }
    renderizado = re.sub(r"\$\{(\w+)\}", lambda m: valores[m.group(1)], modelo)
    definicao = json.loads(renderizado)

    estados = definicao["States"]
    for nome, estado in estados.items():
        for proximo in (estado.get("Next"), estado.get("Default")):
            assert proximo is None or proximo in estados, f"{nome} aponta para {proximo}"
    assert definicao["StartAt"] in estados
    assert definicao["QueryLanguage"] == "JSONPath"
