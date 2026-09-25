variable "region" {
  description = "Region AWS. Debe coincidir con la region del cluster de Agones para no pagar trafico inter-region en cada liquidacion."
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = "Entorno (dev | qa | prod)."
  type        = string

  validation {
    condition     = contains(["dev", "qa", "prod"], var.environment)
    error_message = "environment debe ser dev, qa o prod."
  }
}

variable "table_name_prefix" {
  description = "Prefijo del nombre de la tabla. El nombre final es <prefix>-<environment>."
  type        = string
  default     = "pixelft-core"
}

# ---------------------------------------------------------------------------
# Capacidad y FinOps
# ---------------------------------------------------------------------------

variable "billing_mode" {
  description = <<-EOT
    PAY_PER_REQUEST o PROVISIONED.

    Politica del spec: On-Demand en dev/qa y durante las primeras 4-6 semanas de
    produccion (sin historico no se puede dimensionar y On-Demand absorbe el pico
    de lanzamiento sin throttling). Provisioned + Auto Scaling cuando el patron
    diario ya se conoce.
  EOT
  type        = string
  default     = "PAY_PER_REQUEST"

  validation {
    condition     = contains(["PAY_PER_REQUEST", "PROVISIONED"], var.billing_mode)
    error_message = "billing_mode debe ser PAY_PER_REQUEST o PROVISIONED."
  }
}

variable "capacity" {
  description = <<-EOT
    Limites de autoscaling, solo aplicables con billing_mode = PROVISIONED.

    min      -> p50 del valle, no del pico.
    max      -> 3x el pico observado. Actua como cortacircuitos de gasto: si un bug
                dispara las escrituras, el techo convierte una factura desbocada en
                throttling visible y alarmado.
    target   -> 70%. Deja margen para la rampa, porque el escalado de DynamoDB no es
                instantaneo.
  EOT
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
  default = {
    table_read_min  = 25
    table_read_max  = 4000
    table_write_min = 25
    table_write_max = 4000
    index_read_min  = 10
    index_read_max  = 2000
    index_write_min = 10
    index_write_max = 2000
    target_pct      = 70
  }
}

variable "deletion_protection" {
  description = "Proteccion contra borrado de la tabla. Obligatoria en prod."
  type        = bool
  default     = true
}

variable "point_in_time_recovery" {
  description = "PITR (35 dias). Tiene coste por GB pero es la unica via de recuperacion ante un bug de escritura masiva; sin el, una migracion defectuosa es irreversible."
  type        = bool
  default     = true
}

variable "create_kms_key" {
  description = "Crear una CMK propia. Si es false se usa el cifrado gestionado por AWS, que es gratuito pero no permite politicas de acceso a nivel de clave ni rotacion controlada."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Modelo de datos
# ---------------------------------------------------------------------------

variable "match_history_ttl_days" {
  description = "Retencion de los documentos MATCH# en la tabla operativa. El borrado por TTL no consume WCU; el historico largo vive en S3. Informativo para Terraform (el valor de ttl lo escribe la aplicacion), se expone como output para que el backend lo consuma como configuracion y no como constante hardcodeada."
  type        = number
  default     = 30
}

variable "squad_stats_shard_count" {
  description = "Shards de escritura de las stats agregadas de escuadron. Igual que el anterior: lo aplica la aplicacion, Terraform es la fuente unica del valor."
  type        = number
  default     = 10
}

# ---------------------------------------------------------------------------
# Pipeline analitico
# ---------------------------------------------------------------------------

variable "kinesis_stream_mode" {
  description = "ON_DEMAND o PROVISIONED. ON_DEMAND hasta tener throughput medido."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "PROVISIONED"], var.kinesis_stream_mode)
    error_message = "kinesis_stream_mode debe ser ON_DEMAND o PROVISIONED."
  }
}

variable "kinesis_shard_count" {
  description = "Shards fijos. Solo se aplica con kinesis_stream_mode = PROVISIONED."
  type        = number
  default     = 2
}

variable "kinesis_retention_hours" {
  description = "Retencion del stream CDC. 24 h es el minimo y el default; ampliarlo a 168 h da margen real para reprocesar tras una caida prolongada del pipeline, a cambio de coste de retencion extendida."
  type        = number
  default     = 24

  validation {
    condition     = var.kinesis_retention_hours >= 24 && var.kinesis_retention_hours <= 8760
    error_message = "kinesis_retention_hours debe estar entre 24 y 8760."
  }
}

variable "firehose_buffer_mb" {
  description = "Buffer de Firehose. El particionado dinamico exige un minimo de 64 MB. 128 MB produce ficheros Parquet de tamano sano: el small-files problem degrada las consultas de Spark mas que cualquier optimizacion posterior."
  type        = number
  default     = 128

  validation {
    condition     = var.firehose_buffer_mb >= 64 && var.firehose_buffer_mb <= 128
    error_message = "firehose_buffer_mb debe estar entre 64 y 128 (minimo impuesto por el particionado dinamico)."
  }
}

variable "firehose_buffer_seconds" {
  description = "Intervalo maximo de buffer. Junto al tamano define la latencia analitica (~5 min)."
  type        = number
  default     = 300
}

variable "lake_bucket_name" {
  description = "Nombre del bucket del Data Lake. Si queda vacio se genera <prefix>-lake-<environment>-<account_id>."
  type        = string
  default     = ""
}

variable "bronze_glacier_transition_days" {
  description = "Dias antes de mover bronze a Glacier Instant Retrieval. Bronze es append-only y su lectura tras el procesado de silver es excepcional."
  type        = number
  default     = 90
}

variable "projection_date_start" {
  description = "Fecha inicial de la particion proyectada de la tabla Glue (formato yyyy-MM-dd). La proyeccion de particiones evita el coste y la latencia de un crawler."
  type        = string
  default     = "2026-01-01"
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

variable "eks_oidc_provider_arn" {
  description = "ARN del proveedor OIDC del cluster EKS/Agones. Si se define, el rol del servidor de juego se asume por IRSA (credenciales de corta vida por pod). Si queda vacio se recurre al rol de nodo, que es menos granular y solo aceptable en dev."
  type        = string
  default     = ""
}

variable "game_server_service_account" {
  description = "namespace:serviceaccount del GameServer para el trust de IRSA."
  type        = string
  default     = "default:pixelft-game-server"
}

variable "analytics_principal_arns" {
  description = "Principals que podran asumir el rol de analitica. Ese rol lleva un Deny explicito sobre la tabla operativa: es el mecanismo que hace cumplir el aislamiento, y no depende de que nadie recuerde la convencion."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Observabilidad y presupuesto
# ---------------------------------------------------------------------------

variable "alarm_email" {
  description = "Email para las alarmas operativas. Si queda vacio se crea el topic SNS sin suscripcion."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Presupuesto mensual del modulo. 0 desactiva el presupuesto. Alerta al 80% del gasto previsto."
  type        = number
  default     = 0
}
