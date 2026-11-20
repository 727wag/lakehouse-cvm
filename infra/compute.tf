# ---------- Lambda de ingestão (CVM -> SOR) ----------
data "archive_file" "ingestao" {
  type        = "zip"
  source_dir  = "${path.module}/../src/ingestao"
  output_path = "${path.module}/build/ingestao.zip"
}

resource "aws_cloudwatch_log_group" "ingestao" {
  name              = "/aws/lambda/${var.projeto}-ingestao"
  retention_in_days = 14
}

resource "aws_lambda_function" "ingestao" {
  function_name    = "${var.projeto}-ingestao"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.ingestao.output_path
  source_code_hash = data.archive_file.ingestao.output_base64sha256
  timeout          = 600
  memory_size      = 1024

  ephemeral_storage {
    size = 2048 # MB em /tmp: o ZIP anual da CVM tem ~30 MB
  }

  environment {
    variables = {
      BUCKET      = aws_s3_bucket.lakehouse.bucket
      PREFIXO_SOR = "sor/cvm_itr"
    }
  }

  depends_on = [aws_cloudwatch_log_group.ingestao]
}

# ---------- Glue job PySpark (SOR -> SOT em Iceberg) ----------
resource "aws_s3_object" "script_sot" {
  bucket = aws_s3_bucket.lakehouse.id
  key    = "scripts/sot_demonstracoes.py"
  source = "${path.module}/../src/transformacao/sot_demonstracoes.py"
  etag   = filemd5("${path.module}/../src/transformacao/sot_demonstracoes.py")
}

resource "aws_glue_job" "sot" {
  name              = "${var.projeto}-sot"
  role_arn          = aws_iam_role.glue.arn
  glue_version      = "5.0"
  worker_type       = "G.1X"
  number_of_workers = 2 # mínimo, para manter o custo baixo
  timeout           = 30

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${aws_s3_bucket.lakehouse.bucket}/${aws_s3_object.script_sot.key}"
  }

  execution_property {
    max_concurrent_runs = 1
  }

  default_arguments = {
    "--BUCKET"                           = aws_s3_bucket.lakehouse.bucket
    "--datalake-formats"                 = "iceberg"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--job-language"                     = "python"
  }
}
