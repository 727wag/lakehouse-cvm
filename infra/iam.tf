locals {
  arn_bucket       = aws_s3_bucket.lakehouse.arn
  arn_objetos      = "${aws_s3_bucket.lakehouse.arn}/*"
  arn_catalogo     = "arn:aws:glue:${var.regiao}:${data.aws_caller_identity.atual.account_id}:catalog"
  arn_databases    = [for db in [aws_glue_catalog_database.sot, aws_glue_catalog_database.spec] : db.arn]
  arn_tabelas      = [for db in [aws_glue_catalog_database.sot, aws_glue_catalog_database.spec] : "arn:aws:glue:${var.regiao}:${data.aws_caller_identity.atual.account_id}:table/${db.name}/*"]
  acoes_catalogo   = ["glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables", "glue:CreateTable", "glue:UpdateTable", "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition"]
  acoes_s3_leitura = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
  acoes_s3_escrita = ["s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
}

# ---------- Lambda: grava só na SOR ----------
resource "aws_iam_role" "lambda" {
  name = "${var.projeto}-lambda"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_s3" {
  name = "grava-sor"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
      Resource = "${local.arn_bucket}/sor/*"
    }]
  })
}

# ---------- Glue: lê a SOR e grava a SOT ----------
resource "aws_iam_role" "glue" {
  name = "${var.projeto}-glue"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "glue.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_servico" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_dados" {
  name = "lakehouse"
  role = aws_iam_role.glue.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = local.acoes_s3_leitura, Resource = [local.arn_bucket, local.arn_objetos] },
      { Effect = "Allow", Action = local.acoes_s3_escrita, Resource = "${local.arn_bucket}/sot/*" },
      { Effect = "Allow", Action = local.acoes_catalogo, Resource = concat([local.arn_catalogo], local.arn_databases, local.arn_tabelas) }
    ]
  })
}

# ---------- Step Functions: orquestra tudo ----------
resource "aws_iam_role" "step_functions" {
  name = "${var.projeto}-step-functions"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "states.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "step_functions" {
  name = "orquestracao"
  role = aws_iam_role.step_functions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.ingestao.arn },
      {
        Effect   = "Allow"
        Action   = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns", "glue:BatchStopJobRun"]
        Resource = aws_glue_job.sot.arn
      },
      {
        Effect   = "Allow"
        Action   = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults", "athena:StopQueryExecution", "athena:GetWorkGroup"]
        Resource = aws_athena_workgroup.lakehouse.arn
      },
      # O Athena usa as permissões de quem chama para ler o catálogo e o S3.
      { Effect = "Allow", Action = local.acoes_catalogo, Resource = concat([local.arn_catalogo], local.arn_databases, local.arn_tabelas) },
      { Effect = "Allow", Action = local.acoes_s3_leitura, Resource = [local.arn_bucket, local.arn_objetos] },
      {
        Effect   = "Allow"
        Action   = local.acoes_s3_escrita
        Resource = ["${local.arn_bucket}/spec/*", "${local.arn_bucket}/athena-results/*"]
      },
      { Effect = "Allow", Action = "sns:Publish", Resource = aws_sns_topic.alertas.arn }
    ]
  })
}

# ---------- EventBridge Scheduler: só inicia a Step Function ----------
resource "aws_iam_role" "scheduler" {
  name = "${var.projeto}-scheduler"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "scheduler.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "inicia-pipeline"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "states:StartExecution", Resource = aws_sfn_state_machine.pipeline.arn }]
  })
}
