import re

import pytest

from transformacao import sot_demonstracoes as sot


@pytest.mark.parametrize(("escala", "fator"), [("MIL", 1000), ("UNIDADE", 1), (" mil ", 1000)])
def test_multiplicador_converte_escala(escala, fator):
    assert sot.multiplicador(escala) == fator


@pytest.mark.parametrize("escala", ["MILHAO", "", None])
def test_multiplicador_rejeita_escala_desconhecida(escala):
    with pytest.raises(ValueError):
        sot.multiplicador(escala)


def test_caminho_demonstrativo():
    assert sot.caminho_demonstrativo("meu-bucket", "DRE_con") == (
        "s3://meu-bucket/sor/cvm_itr/demonstrativo=DRE_con/"
    )


def test_condicao_merge_e_null_safe_em_todas_as_colunas():
    condicao = sot.condicao_merge()
    # dt_ini_exerc é nulo nos balanços: precisa de <=>, senão o MERGE duplica.
    assert "t.dt_ini_exerc <=> s.dt_ini_exerc" in condicao
    assert condicao.count("<=>") == len(sot.CHAVE_NEGOCIO)
    assert " = " not in condicao


def test_sql_merge_nao_atualiza_colunas_da_chave():
    sql = sot.sql_merge("origem")
    trecho_update = re.search(r"UPDATE SET (.*) WHEN NOT MATCHED", sql).group(1)
    for coluna in sot.CHAVE_NEGOCIO:
        assert f"t.{coluna} =" not in trecho_update


def test_sql_merge_so_aceita_versao_igual_ou_mais_nova():
    assert "WHEN MATCHED AND s.versao >= t.versao" in sot.sql_merge("origem")


def test_colunas_da_tabela_batem_com_as_do_merge():
    ddl = sot.sql_cria_tabela("bucket")
    for coluna in sot.COLUNAS_SOT:
        assert re.search(rf"\b{coluna}\b", ddl), coluna
