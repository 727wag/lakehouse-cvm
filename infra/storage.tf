locals {
  nome_bucket = "${var.projeto}-${data.aws_caller_identity.atual.account_id}"
}

resource "aws_s3_bucket" "lakehouse" {
  bucket = local.nome_bucket
}

resource "aws_s3_bucket_public_access_block" "lakehouse" {
  bucket                  = aws_s3_bucket.lakehouse.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lakehouse" {
  bucket = aws_s3_bucket.lakehouse.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "lakehouse" {
  bucket = aws_s3_bucket.lakehouse.id

  rule {
    id     = "limpa-resultados-athena"
    status = "Enabled"
    filter {
      prefix = "athena-results/"
    }
    expiration {
      days = 7
    }
  }
}

# Databases do Glue Catalog com prefixo do projeto, para não colidir com outros
# projetos na mesma conta. A SOR fica só como arquivos crus lidos pelo Spark.
resource "aws_glue_catalog_database" "sot" {
  name         = "cvm_sot"
  location_uri = "s3://${aws_s3_bucket.lakehouse.bucket}/sot/"
}

resource "aws_glue_catalog_database" "spec" {
  name         = "cvm_spec"
  location_uri = "s3://${aws_s3_bucket.lakehouse.bucket}/spec/"
}

resource "aws_athena_workgroup" "lakehouse" {
  name          = var.projeto
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.athena_limite_bytes_por_query

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = "s3://${aws_s3_bucket.lakehouse.bucket}/athena-results/"
    }
  }
}
