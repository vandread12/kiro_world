environment = "prod"
region      = "eu-west-1"

# ---------------------------------------------------------------------------
# LANZAMIENTO: dejar PAY_PER_REQUEST durante 4-6 semanas.
#
# Sin historico no se puede dimensionar, y On-Demand absorbe el pico de
# lanzamiento sin throttling. Pasar a PROVISIONED antes de tener el patron diario
# medido es adivinar, y el coste del error es throttling en la hora punta.
#
# Al migrar: cambiar billing_mode a "PROVISIONED", ajustar `capacity` con
# min = p50 del valle y max = 3x el pico observado, y aplicar. El cambio es online.
# ---------------------------------------------------------------------------
billing_mode = "PAY_PER_REQUEST"

capacity = {
  table_read_min  = 100
  table_read_max  = 8000
  table_write_min = 100
  table_write_max = 8000
  index_read_min  = 25
  index_read_max  = 2000
  index_write_min = 25
  index_write_max = 2000
  target_pct      = 70
}

deletion_protection    = true
point_in_time_recovery = true
create_kms_key         = true

kinesis_stream_mode = "ON_DEMAND"

# 72 h en lugar del minimo de 24: si el pipeline cae un viernes por la noche, 24 h
# no bastan para reaccionar antes de que el CDC expire de forma irrecuperable.
kinesis_retention_hours = 72

firehose_buffer_mb      = 128
firehose_buffer_seconds = 300

bronze_glacier_transition_days = 90
projection_date_start          = "2026-01-01"

# Rellenar con el OIDC del cluster de Agones para habilitar IRSA.
eks_oidc_provider_arn       = ""
game_server_service_account = "pixelft:game-server"

analytics_principal_arns = []

alarm_email        = ""
monthly_budget_usd = 1500
