environment = "dev"
region      = "eu-west-1"

# Trafico esporadico: pagar capacidad reservada aqui es puro desperdicio.
billing_mode = "PAY_PER_REQUEST"

# En dev interesa poder destruir y recrear el entorno sin fricción.
deletion_protection    = false
point_in_time_recovery = false
create_kms_key         = false

kinesis_stream_mode     = "ON_DEMAND"
kinesis_retention_hours = 24

# Buffer al minimo permitido por el particionado dinamico: se acepta peor tamano
# de fichero a cambio de ver los datos en el lake en minutos al depurar.
firehose_buffer_mb      = 64
firehose_buffer_seconds = 60

bronze_glacier_transition_days = 30
projection_date_start          = "2026-01-01"

# Sin OIDC: el rol se asume por el rol de nodo. Solo admisible en dev.
eks_oidc_provider_arn = ""

monthly_budget_usd = 50
