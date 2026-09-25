variable "table_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "billing_mode" {
  type = string
}

variable "capacity" {
  type = object({
    table_read_min  = number
    table_read_max  = number
    table_write_min = number
    table_write_max = number
    index_read_min  = number
    index_read_max  = number
    index_write_min = number
    index_write_max = number
    target_pct      = number
  })
}

variable "deletion_protection" {
  type = bool
}

variable "point_in_time_recovery" {
  type = bool
}

variable "kms_key_arn" {
  description = "CMK para el cifrado en reposo. Null usa la clave gestionada por AWS para DynamoDB."
  type        = string
  default     = null
}

variable "kinesis_stream_arn" {
  description = "Stream de Kinesis destino del CDC. Null desactiva la exportacion (util en dev para no pagar el stream)."
  type        = string
  default     = null
}

variable "sns_topic_arn" {
  description = "Topic de alarmas."
  type        = string
}

variable "conditional_check_alarm_threshold" {
  description = <<-EOT
    Umbral de ConditionalCheckFailedRequests en 5 minutos.

    No es una alarma de error: un cierto volumen de fallos condicionales es el
    funcionamiento normal del bloqueo optimista. Lo que se vigila es el PICO, que
    indica un bug de concurrencia o un intento de exploit de duplicacion. Conviene
    recalibrarlo con trafico real; arrancar demasiado bajo genera ruido y entrena
    al equipo a ignorar la alarma.
  EOT
  type        = number
  default     = 50
}
