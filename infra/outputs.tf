output "bucket" {
  value = aws_s3_bucket.lakehouse.bucket
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.pipeline.arn
}

output "athena_workgroup" {
  value = aws_athena_workgroup.lakehouse.name
}

output "comando_executar_agora" {
  description = "Dispara o pipeline manualmente (útil para o primeiro teste)."
  value       = "aws stepfunctions start-execution --state-machine-arn ${aws_sfn_state_machine.pipeline.arn} --input '{}'"
}
