"""Ingestão: dados abertos da CVM (ITR) -> camada SOR no S3.

Baixa o ZIP anual de Informações Trimestrais (ITR) das companhias abertas,
extrai só os demonstrativos consolidados de interesse e grava os CSVs crus
no S3, particionados por demonstrativo e ano. Reexecutar sobrescreve os
mesmos arquivos, então a ingestão é idempotente.

Variáveis de ambiente:
    BUCKET       bucket do lakehouse
    PREFIXO_SOR  prefixo da SOR (padrão: sor/cvm_itr)
"""

from __future__ import annotations

import json
import logging
import os
import re
import shutil
import tempfile
import urllib.error
import urllib.request
import zipfile
from datetime import date

logger = logging.getLogger()
logger.setLevel(logging.INFO)

URL_BASE = "https://dados.cvm.gov.br/dados/CIA_ABERTA/DOC/ITR/DADOS"
DEMONSTRATIVOS = ("BPA_con", "BPP_con", "DRE_con")
PADRAO_ARQUIVO = re.compile(
    r"^itr_cia_aberta_(?P<demonstrativo>[A-Za-z]+_(?:con|ind))_(?P<ano>\d{4})\.csv$",
    re.IGNORECASE,
)


def montar_url(ano: int) -> str:
    """URL do ZIP anual de ITR da CVM."""
    return f"{URL_BASE}/itr_cia_aberta_{ano}.zip"


def anos_padrao(hoje: date) -> list[int]:
    """Ano anterior e ano atual: cobre reapresentações recentes."""
    return [hoje.year - 1, hoje.year]


def demonstrativo_do_arquivo(nome: str) -> str | None:
    """Extrai o demonstrativo do nome do CSV, ou None se não for de interesse."""
    encontrado = PADRAO_ARQUIVO.match(os.path.basename(nome))
    if not encontrado:
        return None
    bruto = encontrado.group("demonstrativo")
    for desejado in DEMONSTRATIVOS:
        if bruto.lower() == desejado.lower():
            return desejado
    return None


def chave_s3(prefixo: str, demonstrativo: str, ano: int, nome_arquivo: str) -> str:
    """Caminho no S3 no padrão de partições Hive (chave=valor)."""
    return f"{prefixo.strip('/')}/demonstrativo={demonstrativo}/ano={ano}/{nome_arquivo}"


def baixar(url: str, destino: str) -> bool:
    """Baixa o arquivo em streaming. Retorna False se o ano ainda não existe (404)."""
    try:
        with urllib.request.urlopen(url, timeout=120) as resposta, open(destino, "wb") as arquivo:
            shutil.copyfileobj(resposta, arquivo)
        return True
    except urllib.error.HTTPError as erro:
        if erro.code == 404:
            return False
        raise


def ingerir_ano(s3, bucket: str, prefixo: str, ano: int) -> list[str]:
    """Baixa o ZIP de um ano e sobe os demonstrativos de interesse. Retorna as chaves gravadas."""
    gravadas: list[str] = []
    with tempfile.TemporaryDirectory() as pasta:
        caminho_zip = os.path.join(pasta, f"itr_{ano}.zip")
        if not baixar(montar_url(ano), caminho_zip):
            logger.info(json.dumps({"evento": "ano_indisponivel", "ano": ano}))
            return gravadas

        with zipfile.ZipFile(caminho_zip) as pacote:
            nomes = pacote.namelist()
            logger.info(json.dumps({"evento": "zip_aberto", "ano": ano, "arquivos": nomes}))
            for nome in nomes:
                demonstrativo = demonstrativo_do_arquivo(nome)
                if demonstrativo is None:
                    continue
                chave = chave_s3(prefixo, demonstrativo, ano, os.path.basename(nome))
                with pacote.open(nome) as conteudo:
                    s3.upload_fileobj(conteudo, bucket, chave)
                gravadas.append(chave)

    if len(gravadas) < len(DEMONSTRATIVOS):
        raise RuntimeError(
            f"Ano {ano}: esperava {len(DEMONSTRATIVOS)} demonstrativos e encontrei {len(gravadas)}. "
            "Confira no log 'zip_aberto' se a CVM mudou o nome dos arquivos."
        )
    return gravadas


def lambda_handler(event, context):
    import boto3  # disponível no runtime da Lambda

    bucket = os.environ["BUCKET"]
    prefixo = os.environ.get("PREFIXO_SOR", "sor/cvm_itr")
    anos = (event or {}).get("anos") or anos_padrao(date.today())

    s3 = boto3.client("s3")
    gravadas: list[str] = []
    for ano in anos:
        gravadas += ingerir_ano(s3, bucket, prefixo, int(ano))

    resumo = {"evento": "ingestao_concluida", "anos": anos, "qtd_arquivos": len(gravadas)}
    logger.info(json.dumps(resumo))
    return {"anos": anos, "arquivos": gravadas}
