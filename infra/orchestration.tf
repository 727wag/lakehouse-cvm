locals {
  sql = {
    cria_spec  = templatefile("${path.module}/../sql/spec/01_cria_indicadores_trimestrais.sql", { bucket = aws_s3_bucket.lakehouse.bucket })
    merge_spec = file("${path.module}/../sql/spec/02_merge_indicadores_trimestrais.sql")
    qualidade  = file("${path.module}/../sql/qualidade/checa_indicadores.sql")
  }
}

resource "aws_sns_topic" "alertas" {
  name = "${var.projeto}-alertas"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alertas.arn
  protocol  = "email"
  endpoint  = var.email_alertas
}

resource "aws_sfn_state_machine" "pipeline" {
  name     = "${var.projeto}-pipeline"
  role_arn = aws_iam_role.step_functions.arn

  definition = templatefile("${path.module}/../orquestracao/pipeline.asl.json.tftpl", {
    lambda_ingestao = aws_lambda_function.ingestao.arn
    glue_job        = aws_glue_job.sot.name
    workgroup       = aws_athena_workgroup.lakehouse.name
    sns_topico      = aws_sns_topic.alertas.arn
    sql_cria_spec   = jsonencode(local.sql.cria_spec)
    sql_merge_spec  = jsonencode(local.sql.merge_spec)
    sql_qualidade   = jsonencode(local.sql.qualidade)
  })
}

resource "aws_scheduler_schedule" "semanal" {
  name                         = "${var.projeto}-semanal"
  schedule_expression          = var.agenda_cron
  schedule_expression_timezone = var.fuso_horario

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sfn_state_machine.pipeline.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({})
  }
}

# Alerta de custo da conta: avisa ao passar de 80% do orçamento.
resource "aws_budgets_budget" "mensal" {
  name         = "${var.projeto}-orcamento"
  budget_type  = "COST"
  limit_amount = tostring(var.orcamento_mensal_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.email_alertas]
  }
}
