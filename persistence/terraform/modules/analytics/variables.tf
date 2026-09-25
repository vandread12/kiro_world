variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "bucket_name" {
  type = string
}

variable "kms_key_arn" {
  type    = string
  default = null
}

variable "kinesis_stream_mode" {
  type = string
}

variable "kinesis_shard_count" {
  type = number
}

variable "kinesis_retention_hours" {
  type = number
}

variable "firehose_buffer_mb" {
  type = number
}

variable "firehose_buffer_seconds" {
  type = number
}

variable "bronze_glacier_transition_days" {
  type = number
}

variable "projection_date_start" {
  type = string
}

variable "sns_topic_arn" {
  type = string
}

variable "iterator_age_alarm_hours" {
  description = <<-EOT
    Umbral de GetRecords.IteratorAgeMilliseconds.

    Debe dispararse MUY por debajo de kinesis_retention_hours: si el consumidor se
    retrasa mas que la retencion, los datos se pierden de forma irrecuperable. Con
    retencion de 24 h, alarmar a las 4 h deja 20 h de margen para reaccionar.
  EOT
  type        = number
  default     = 4
}
