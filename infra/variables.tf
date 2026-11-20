variable "projeto" {
  description = "Prefixo usado nos nomes dos recursos."
  type        = string
  default     = "lakehouse-cvm"
}

variable "regiao" {
  description = "Região da AWS."
  type        = string
  default     = "us-east-1"
}

variable "email_alertas" {
  description = "E-mail que recebe os alertas de falha (confirme a assinatura que chega por e-mail)."
  type        = string
}

variable "orcamento_mensal_usd" {
  description = "Limite do alerta de custo mensal da conta, em dólares."
  type        = number
  default     = 5
}

variable "agenda_cron" {
  description = "Quando o pipeline roda. A CVM atualiza os dados semanalmente."
  type        = string
  default     = "cron(0 7 ? * MON *)"
}

variable "fuso_horario" {
  type    = string
  default = "America/Sao_Paulo"
}

variable "athena_limite_bytes_por_query" {
  description = "Trava de custo: o Athena cancela queries que leiam mais que isso."
  type        = number
  default     = 2147483648 # 2 GB
}

variable "datadog_api_url" {
  description = "Endpoint da API do Datadog do seu site (US1, US5, EU...)."
  type        = string
  default     = "https://api.datadoghq.com/"
}

variable "datadog_habilitado" {
  description = "Cria monitores e dashboard no Datadog. Requer a integração AWS já configurada."
  type        = bool
  default     = true
}

variable "datadog_notificar" {
  description = "Destino das notificações do Datadog, ex.: @seu-email@exemplo.com"
  type        = string
  default     = ""
}
