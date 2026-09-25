# ---------------------------------------------------------------------------
# Contrato de configuracion para el backend autoritativo.
#
# Estos outputs son la fuente unica de verdad: el servidor los consume como
# variables de entorno en lugar de llevar los nombres y parametros hardcodeados.
# ---------------------------------------------------------------------------

output "table_name" {
  value = module.dynamodb.table_name
}

output "table_arn" {
  value = module.dynamodb.table_arn
}

output "gsi_name" {
  description = "Indice esparso para la auditoria item_def -> propietarios."
  value       = module.dynamodb.gsi_name
}

output "billing_mode" {
  value = module.dynamodb.billing_mode
}

output "game_server_role_arn" {
  description = "Anotar en el ServiceAccount del GameServer de Agones."
  value       = module.iam.game_server_role_arn
}

output "analytics_role_arn" {
  value = module.iam.analytics_role_arn
}

output "kinesis_stream_name" {
  value = module.analytics.kinesis_stream_name
}

output "lake_bucket" {
  value = module.analytics.lake_bucket
}

output "athena_bronze_table" {
  value = module.analytics.athena_bronze_reference
}

output "alarm_topic_arn" {
  value = aws_sns_topic.alarms.arn
}

output "app_config" {
  description = "Bloque listo para inyectar como configuracion del servidor de juego."
  value = {
    DDB_TABLE_NAME          = module.dynamodb.table_name
    DDB_GSI_NAME            = module.dynamodb.gsi_name
    AWS_REGION              = var.region
    MATCH_HISTORY_TTL_DAYS  = var.match_history_ttl_days
    SQUAD_STATS_SHARD_COUNT = var.squad_stats_shard_count
    # 25 items y 4 MB son limites duros de TransactWriteItems. El servidor debe
    # particionar la liquidacion de MATCH_END al alcanzarlo, no descubrirlo con
    # una excepcion en produccion.
    TRANSACT_MAX_ITEMS = 25
    # 48 h. Debe cubrir con holgura la ventana de reintentos de Agones.
    IDEMPOTENCY_TTL_HOURS = 48
    # Lease de sesion: garantiza un unico escritor logico del inventario.
    SESSION_LEASE_MINUTES = 15
    # Reintentos del bloqueo optimista: 50/150/400 ms con jitter.
    OPTIMISTIC_LOCK_MAX_RETRIES = 3
  }
}
