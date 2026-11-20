import zipfile
from datetime import date

import pytest

from ingestao import handler


def test_montar_url_usa_o_ano():
    assert handler.montar_url(2025).endswith("/ITR/DADOS/itr_cia_aberta_2025.zip")


def test_anos_padrao_cobre_ano_anterior_e_atual():
    assert handler.anos_padrao(date(2026, 11, 20)) == [2025, 2026]


@pytest.mark.parametrize(
    ("nome", "esperado"),
    [
        ("itr_cia_aberta_DRE_con_2025.csv", "DRE_con"),
        ("itr_cia_aberta_BPA_con_2025.csv", "BPA_con"),
        ("pasta/itr_cia_aberta_bpp_con_2024.csv", "BPP_con"),
    ],
)
def test_demonstrativo_do_arquivo_reconhece_os_desejados(nome, esperado):
    assert handler.demonstrativo_do_arquivo(nome) == esperado


@pytest.mark.parametrize(
    "nome",
    [
        "itr_cia_aberta_DRE_ind_2025.csv",  # individual, não consolidado
        "itr_cia_aberta_DFC_MD_con_2025.csv",  # demonstrativo fora do escopo
        "itr_cia_aberta_2025.csv",  # cadastro, não demonstrativo
        "leia-me.txt",
    ],
)
def test_demonstrativo_do_arquivo_ignora_o_resto(nome):
    assert handler.demonstrativo_do_arquivo(nome) is None


def test_chave_s3_segue_padrao_de_particao():
    chave = handler.chave_s3("/sor/cvm_itr/", "DRE_con", 2025, "itr_cia_aberta_DRE_con_2025.csv")
    assert chave == "sor/cvm_itr/demonstrativo=DRE_con/ano=2025/itr_cia_aberta_DRE_con_2025.csv"


class S3Falso:
    def __init__(self):
        self.gravados = {}

    def upload_fileobj(self, arquivo, bucket, chave):
        self.gravados[(bucket, chave)] = arquivo.read()


def _zip_falso(destino, nomes):
    with zipfile.ZipFile(destino, "w") as pacote:
        for nome in nomes:
            pacote.writestr(nome, "CNPJ_CIA;VL_CONTA\n00.000.000/0001-00;1.0\n")


def test_ingerir_ano_sobe_so_os_consolidados(monkeypatch):
    nomes = [
        "itr_cia_aberta_2025.csv",
        "itr_cia_aberta_BPA_con_2025.csv",
        "itr_cia_aberta_BPP_con_2025.csv",
        "itr_cia_aberta_DRE_con_2025.csv",
        "itr_cia_aberta_DRE_ind_2025.csv",
    ]
    monkeypatch.setattr(handler, "baixar", lambda url, destino: _zip_falso(destino, nomes) or True)
    s3 = S3Falso()

    chaves = handler.ingerir_ano(s3, "bucket", "sor/cvm_itr", 2025)

    assert sorted(chaves) == [
        "sor/cvm_itr/demonstrativo=BPA_con/ano=2025/itr_cia_aberta_BPA_con_2025.csv",
        "sor/cvm_itr/demonstrativo=BPP_con/ano=2025/itr_cia_aberta_BPP_con_2025.csv",
        "sor/cvm_itr/demonstrativo=DRE_con/ano=2025/itr_cia_aberta_DRE_con_2025.csv",
    ]
    assert all(bucket == "bucket" for bucket, _ in s3.gravados)


def test_ingerir_ano_falha_se_faltar_demonstrativo(monkeypatch):
    nomes = ["itr_cia_aberta_DRE_con_2025.csv"]
    monkeypatch.setattr(handler, "baixar", lambda url, destino: _zip_falso(destino, nomes) or True)

    with pytest.raises(RuntimeError, match="esperava 3 demonstrativos"):
        handler.ingerir_ano(S3Falso(), "bucket", "sor/cvm_itr", 2025)


def test_ingerir_ano_ignora_ano_ainda_nao_publicado(monkeypatch):
    monkeypatch.setattr(handler, "baixar", lambda url, destino: False)
    assert handler.ingerir_ano(S3Falso(), "bucket", "sor/cvm_itr", 2027) == []
