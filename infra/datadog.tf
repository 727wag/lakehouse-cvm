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

resource "datadog_dashboard_json" "pipeline" {
  count = local.dd_count
  dashboard = jsonencode({
    title       = "Lakehouse CVM: saúde do pipeline"
    description = "Execuções, falhas e duração das etapas. Gerenciado pelo Terraform."
    layout_type = "ordered"
    widgets = [
      {
        definition = {
          type  = "timeseries"
          title = "Execuções da Step Function"
          requests = [
            { q = "sum:aws.states.executions_succeeded{${local.dd_tag_pipeline}}.as_count()", display_type = "bars" },
            { q = "sum:aws.states.executions_failed{${local.dd_tag_pipeline}}.as_count()", display_type = "bars" }
          ]
        }
      },
      {
        definition = {
          type     = "timeseries"
          title    = "Duração da execução (ms)"
          requests = [{ q = "avg:aws.states.execution_time{${local.dd_tag_pipeline}}", display_type = "line" }]
        }
      },
      {
        definition = {
          type     = "timeseries"
          title    = "Duração da ingestão (ms)"
          requests = [{ q = "avg:aws.lambda.duration{${local.dd_tag_ingestao}}", display_type = "line" }]
        }
      },
      {
        definition = {
          type         = "manage_status"
          title        = "Monitores do projeto"
          query        = "tag:(projeto:${var.projeto})"
          sort         = "status,asc"
          summary_type = "monitors"
        }
      }
    ]
  })
}
