# Monitores e dashboard do pipeline no Datadog.
# Pré-requisito: integração AWS do Datadog ativa na conta (a mesma usada para o EC2),
# com Lambda e Step Functions habilitados na coleta de métricas.
#
# Confira os nomes das tags no Metrics Explorer depois da primeira execução: o
# Datadog costuma deixar os valores em minúsculas.

locals {
  dd_count          = var.datadog_habilitado ? 1 : 0
  dd_tag_pipeline   = "statemachinearn:${lower(aws_sfn_state_machine.pipeline.arn)}"
  dd_tag_ingestao   = "functionname:${lower(aws_lambda_function.ingestao.function_name)}"
  dd_notificacao    = var.datadog_notificar
  dd_tags_monitores = ["projeto:${var.projeto}", "camada:orquestracao"]
}

resource "datadog_monitor" "pipeline_falhou" {
  count   = local.dd_count
  name    = "[${var.projeto}] Execução do pipeline falhou"
  type    = "query alert"
  query   = "sum(last_1h):sum:aws.states.executions_failed{${local.dd_tag_pipeline}}.as_count() > 0"
  message = <<-EOT
    Uma execução da Step Function terminou em falha.
    Abra o histórico da execução no console para ver em qual etapa parou.
    ${local.dd_notificacao}
  EOT

  monitor_thresholds {
    critical = 0
  }
  notify_no_data = false
  tags           = local.dd_tags_monitores
}

# Frescor do dado: se nenhuma execução terminar com sucesso em 8 dias,
# o dashboard está desatualizado mesmo sem nenhum erro aparente.
resource "datadog_monitor" "pipeline_sem_sucesso" {
  count   = local.dd_count
  name    = "[${var.projeto}] Nenhuma execução com sucesso em 7 dias"
  type    = "query alert"
  query   = "sum(last_1w):default_zero(sum:aws.states.executions_succeeded{${local.dd_tag_pipeline}}.as_count()) < 1"
  message = <<-EOT
    O pipeline não conclui com sucesso há mais de uma semana.
    Verifique o agendamento no EventBridge Scheduler e as últimas execuções.
    ${local.dd_notificacao}
  EOT

  monitor_thresholds {
    critical = 1
  }
  # Sem execuções, a métrica fica sem dados. O default_zero() trata a ausência
  # como 0, então o próprio alerta "< 1" dispara, sem depender de no_data
  # (o Datadog limita o no_data_timeframe a 3 dias, menos que o ciclo semanal).
  notify_no_data = false
  tags           = local.dd_tags_monitores
}

resource "datadog_monitor" "ingestao_erros" {
  count   = local.dd_count
  name    = "[${var.projeto}] Erros na Lambda de ingestão"
  type    = "query alert"
  query   = "sum(last_1h):sum:aws.lambda.errors{${local.dd_tag_ingestao}}.as_count() > 0"
  message = <<-EOT
    A Lambda de ingestão da CVM retornou erro. Veja os logs em /aws/lambda/${aws_lambda_function.ingestao.function_name}.
    ${local.dd_notificacao}
  EOT

  monitor_thresholds {
    critical = 0
  }
  tags = local.dd_tags_monitores
}

# Layout fixo (grade de 12 colunas): cada widget tem posição e tamanho
# definidos em "layout", então dá pra redimensionar e arrastar na interface.
locals {
  dd_ultima_semana = { live_span = "1w" }
  dd_cabecalho     = <<-EOT
    ## Lakehouse CVM 🏦
    Pipeline de dados com as demonstrações trimestrais das empresas abertas (CVM).

    **Fluxo:** Lambda (ingestão) → Glue PySpark (SOT em Iceberg) → Athena (SPEC) → checagem de qualidade

    **Agenda:** toda segunda, 7h (EventBridge + Step Functions) · [Repositório no GitHub](https://github.com/727wag/lakehouse-cvm)
  EOT
}

resource "datadog_dashboard_json" "pipeline" {
  count = local.dd_count
  dashboard = jsonencode({
    title       = "Lakehouse CVM: saúde do pipeline"
    description = "Execuções, falhas e duração das etapas. Gerenciado pelo Terraform."
    layout_type = "ordered"
    reflow_type = "fixed"
    widgets = [
      {
        definition = {
          type             = "note"
          content          = local.dd_cabecalho
          background_color = "blue"
          font_size        = "14"
          text_align       = "left"
          vertical_align   = "top"
          has_padding      = true
          show_tick        = false
        }
        layout = { x = 0, y = 0, width = 12, height = 2 }
      },
      {
        definition = {
          type      = "query_value"
          title     = "Execuções com sucesso (7 dias)"
          time      = local.dd_ultima_semana
          precision = 0
          requests  = [{ q = "sum:aws.states.executions_succeeded{${local.dd_tag_pipeline}}.as_count()", aggregator = "sum" }]
        }
        layout = { x = 0, y = 2, width = 3, height = 2 }
      },
      {
        definition = {
          type      = "query_value"
          title     = "Falhas (7 dias)"
          time      = local.dd_ultima_semana
          precision = 0
          requests = [{
            q          = "sum:aws.states.executions_failed{${local.dd_tag_pipeline}}.as_count()"
            aggregator = "sum"
            conditional_formats = [
              { comparator = ">", value = 0, palette = "white_on_red" },
              { comparator = "<=", value = 0, palette = "white_on_green" }
            ]
          }]
        }
        layout = { x = 3, y = 2, width = 3, height = 2 }
      },
      {
        definition = {
          type      = "query_value"
          title     = "Duração média do pipeline"
          time      = local.dd_ultima_semana
          precision = 1
          autoscale = true
          requests  = [{ q = "avg:aws.states.execution_time{${local.dd_tag_pipeline}}", aggregator = "avg" }]
        }
        layout = { x = 6, y = 2, width = 3, height = 2 }
      },
      {
        definition = {
          type      = "query_value"
          title     = "Duração média da ingestão"
          time      = local.dd_ultima_semana
          precision = 1
          autoscale = true
          requests  = [{ q = "avg:aws.lambda.duration{${local.dd_tag_ingestao}}", aggregator = "avg" }]
        }
        layout = { x = 9, y = 2, width = 3, height = 2 }
      },
      {
        definition = {
          type  = "timeseries"
          title = "Execuções por dia"
          time  = local.dd_ultima_semana
          requests = [
            {
              q            = "sum:aws.states.executions_succeeded{${local.dd_tag_pipeline}}.as_count().rollup(sum, 86400)"
              display_type = "bars"
              style        = { palette = "cool" }
            },
            {
              q            = "sum:aws.states.executions_failed{${local.dd_tag_pipeline}}.as_count().rollup(sum, 86400)"
              display_type = "bars"
              style        = { palette = "warm" }
            }
          ]
        }
        layout = { x = 0, y = 4, width = 6, height = 3 }
      },
      {
        definition = {
          type  = "timeseries"
          title = "Duração das etapas"
          time  = local.dd_ultima_semana
          requests = [
            { q = "avg:aws.states.execution_time{${local.dd_tag_pipeline}}", display_type = "line", style = { palette = "purple" } },
            { q = "avg:aws.lambda.duration{${local.dd_tag_ingestao}}", display_type = "line", style = { palette = "orange" } }
          ]
        }
        layout = { x = 6, y = 4, width = 6, height = 3 }
      },
      {
        definition = {
          type           = "manage_status"
          title          = "Monitores do projeto"
          query          = "tag:(projeto:${var.projeto})"
          sort           = "status,asc"
          summary_type   = "monitors"
          display_format = "countsAndList"
        }
        layout = { x = 0, y = 7, width = 12, height = 3 }
      }
    ]
  })
}