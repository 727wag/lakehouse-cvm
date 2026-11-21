# Lakehouse CVM: indicadores trimestrais de empresas abertas na AWS

[![CI](https://github.com/727wag/lakehouse-cvm/actions/workflows/ci.yml/badge.svg)](https://github.com/727wag/lakehouse-cvm/actions/workflows/ci.yml)
![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)
![PySpark](https://img.shields.io/badge/PySpark-Glue%205.0-E25A1C?logo=apachespark&logoColor=white)
![Iceberg](https://img.shields.io/badge/Apache%20Iceberg-tabelas-4E8EE9)
![Terraform](https://img.shields.io/badge/Terraform-IaC-844FBA?logo=terraform&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-Lambda%20%7C%20Glue%20%7C%20Athena%20%7C%20Step%20Functions-FF9900?logo=amazonwebservices&logoColor=white)
![Datadog](https://img.shields.io/badge/Datadog-monitoramento-632CA6?logo=datadog&logoColor=white)

Pipeline de dados de ponta a ponta com **dados públicos da CVM**: baixa as Informações
Trimestrais (ITR) das companhias abertas, organiza em camadas **SOR → SOT → SPEC** sobre
**Apache Iceberg** e entrega indicadores prontos (ativo total, patrimônio líquido, lucro
do trimestre e ROE) para consulta no Athena.

Toda a infraestrutura é criada com **Terraform**, a orquestração roda sozinha toda semana
com **Step Functions + EventBridge Scheduler** e a saúde do pipeline é monitorada no
**Datadog**.

![Dashboard do Datadog com a saúde do pipeline](docs/img/datadog-dashboard.png)

## Arquitetura

```mermaid
flowchart LR
    CVM[(Portal de Dados<br/>Abertos da CVM)] -->|ZIP anual ITR| L[Lambda<br/>ingestão]
    L -->|CSVs crus| SOR[(S3: SOR)]
    SOR --> G[Glue job<br/>PySpark]
    G -->|MERGE Iceberg| SOT[(cvm_sot.demonstracoes)]
    SOT --> A[Athena<br/>MERGE SQL]
    A --> SPEC[(cvm_spec.indicadores_trimestrais)]
    SPEC --> Q{Checagem de<br/>qualidade}

    EB[EventBridge Scheduler<br/>toda segunda 7h] --> SF[Step Functions]
    SF -.orquestra.-> L & G & A & Q
    SF -->|falha| SNS[SNS: e-mail]
    SF -.métricas.-> DD[Datadog:<br/>monitores e dashboard]
```

| Camada | Onde fica | O que tem |
|---|---|---|
| **SOR** | `s3://<bucket>/sor/cvm_itr/demonstrativo=*/ano=*/` | CSVs da CVM como vieram (BPA, BPP e DRE consolidados) |
| **SOT** | `cvm_sot.demonstracoes` (Iceberg) | Dados tipados, em reais, só a versão mais recente de cada linha |
| **SPEC** | `cvm_spec.indicadores_trimestrais` (Iceberg) | Uma linha por empresa e trimestre, com os indicadores calculados |

## Resultado

Indicadores do 3º trimestre de 2026 calculados pelo pipeline (valores em R$ bilhões):

| Empresa | Lucro do trimestre | Patrimônio líquido | ROE trimestral |
|---|---:|---:|---:|
| Itaú Unibanco Holding | 12,27 | 239,26 | 5,13% |
| Bradesco | 7,44 | 196,59 | 3,78% |
| Santander Brasil | 2,84 | 130,33 | 2,18% |
| Banco do Brasil | 1,77 | 191,90 | 0,92% |

<details>
<summary>Ver a query e o resultado no Athena</summary>

![Query na camada SPEC](docs/img/athena-spec-query.png)
![Lucro, patrimônio líquido e ROE trimestral dos bancos](docs/img/athena-spec-resultado.png)

A consulta leu só 55 KB: a SPEC já guarda os indicadores prontos, em Parquet particionado por ano.

</details>

## O pipeline em funcionamento

**Orquestração.** A Step Function encadeia ingestão, transformação, SPEC e checagem de
qualidade. Qualquer erro cai no `AvisaFalha`, que manda e-mail pelo SNS.

![Grafo da Step Function com todas as etapas concluídas](docs/img/step-functions-grafo.png)

Uma execução completa leva cerca de 6 minutos, e a maior parte é o job do Glue:

![Duração de cada etapa da execução](docs/img/step-functions-etapas.png)

<details>
<summary>Agendamento e execuções do Glue</summary>

O EventBridge Scheduler dispara o pipeline toda segunda às 7h (horário de Brasília):

![Agenda semanal no EventBridge Scheduler](docs/img/eventbridge-agenda.png)

O job PySpark roda com 2 DPUs em cerca de 2 minutos:

![Execuções do job do Glue](docs/img/glue-execucoes.png)

</details>

## Decisões de engenharia

- **Idempotência em todas as etapas.** A ingestão sobrescreve os mesmos arquivos, a SOT e a
  SPEC usam `MERGE`. Rodar o pipeline duas vezes não duplica nada.
- **Reapresentações da CVM.** Empresas republicam demonstrativos. A SOT guarda só a maior
  `VERSAO` de cada linha (window function com `row_number()`), e a SPEC reprocessa os
  últimos 15 meses a cada execução.
- **MERGE null-safe.** Balanços não têm data de início de exercício. O `MERGE` da SOT compara
  a chave com `<=>`, porque `NULL = NULL` é falso e inseriria tudo de novo a cada execução.
- **Planos de contas diferentes.** Bancos e empresas comerciais descrevem o lucro de formas
  diferentes na DRE. Encontrei isso explorando os dados, e a SPEC aceita as duas descrições.
- **Falhar alto em vez de errar em silêncio.** Escala de moeda desconhecida, demonstrativo
  faltando no ZIP ou SPEC sem dados recentes interrompem o pipeline e disparam alerta.
- **Métricas em SQL, não em Python.** A regra de negócio fica na SPEC, consultável por
  qualquer pessoa no Athena.
- **Custo sob controle.** Glue com o mínimo de workers, workgroup do Athena com limite de bytes
  por query, resultados temporários apagados em 7 dias e alerta de orçamento mensal.
- **Permissões mínimas.** Cada serviço tem sua role: a Lambda só grava na SOR, o Glue só grava
  na SOT, o Scheduler só inicia a Step Function.
- **Observabilidade como código.** Monitores e dashboard do Datadog ficam no Terraform, junto
  com o resto da infraestrutura.

## Estrutura

```
infra/            Terraform (AWS + Datadog)
orquestracao/     definição da Step Function (template)
src/ingestao/     Lambda: CVM -> SOR
src/transformacao Glue job PySpark: SOR -> SOT
sql/spec/         DDL e MERGE da camada SPEC
sql/qualidade/    checagem lida pela Step Function
sql/analises/     queries de exploração e validação
tests/            pytest (funções de ingestão e transformação, SQL e Step Function)
docs/img/         prints usados neste README
```

## Como rodar

**Pré-requisitos:** conta AWS com o AWS CLI configurado, Terraform ≥ 1.6, Python ≥ 3.11 e,
para o Datadog, a integração AWS já ativa na conta.

```bash
# 1. Testes locais
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
ruff check . && pytest

# 2. Infraestrutura
cd infra
cp terraform.tfvars.example terraform.tfvars   # ajuste o e-mail e o site do Datadog
source ~/.datadog-env                          # exporta DD_API_KEY e DD_APP_KEY (ou datadog_habilitado = false)
terraform init
terraform plan
terraform apply

# 3. Confirme a assinatura do SNS no e-mail e rode a primeira carga
aws stepfunctions start-execution --state-machine-arn "$(terraform output -raw state_machine_arn)"
```

Para carregar anos específicos, inicie a execução com `--input '{"anos": [2023, 2024, 2025]}'`.

## Custos

Uma execução custa por volta de **US$ 0,05**: o Glue usa cerca de 0,07 DPU-hora, o Athena lê
poucos MB e Lambda, Step Functions e Scheduler ficam dentro do nível gratuito. Rodando uma vez
por semana, fica abaixo de US$ 0,30 por mês. O orçamento configurado avisa por e-mail ao passar
de 80% do limite.

Para desligar tudo:

```bash
aws s3 rm s3://$(terraform output -raw bucket) --recursive   # o bucket precisa estar vazio
terraform destroy
```

## Limitações e próximos passos

- O 4º trimestre não está no ITR, só na DFP anual. Próximo passo: ingerir a DFP.
- Os indicadores dependem das descrições padronizadas de conta da CVM. Um plano de contas novo
  exige rodar `sql/analises/descobrir_contas.sql` e ajustar a SPEC.
- Métricas de negócio no Datadog (linhas ingeridas, empresas por trimestre) para detectar
  queda de volume, além de falhas técnicas.
- Deploy pelo GitHub Actions com OIDC, sem chaves de acesso guardadas.

## Fonte dos dados

[Portal de Dados Abertos da CVM: Formulário de Informações Trimestrais (ITR)](https://dados.cvm.gov.br/dataset/cia_aberta-doc-itr),
atualizado semanalmente.

---

Feito por [Wagner Bastos](https://www.linkedin.com/in/wabastos) · [GitHub](https://github.com/727wag)
