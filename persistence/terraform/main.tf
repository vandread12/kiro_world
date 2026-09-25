data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.table_name_prefix}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id

  lake_bucket = var.lake_bucket_name != "" ? var.lake_bucket_name : "${var.table_name_prefix}-lake-${var.environment}-${local.account_id}"

  kms_key_arn = var.create_kms_key ? aws_kms_key.data[0].arn : null
}

# ---------------------------------------------------------------------------
# Cifrado
# ---------------------------------------------------------------------------

resource "aws_kms_key" "data" {
  count = var.create_kms_key ? 1 : 0

  description             = "CMK de persistencia PixelRift (${var.environment}): DynamoDB, Kinesis, S3 lake."
  enable_key_rotation     = true
  deletion_window_in_days = var.environment == "prod" ? 30 : 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # Los servicios acceden a la clave solo a traves del servicio propietario
        # del dato. Sin la condicion ViaService, un principal con permiso de KMS
        # podria descifrar objetos fuera del contexto previsto.
        Sid       = "AllowServiceUse"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = local.account_id
          }
          StringLike = {
            "kms:ViaService" = [
              "dynamodb.${var.region}.amazonaws.com",
              "kinesis.${var.region}.amazonaws.com",
              "s3.${var.region}.amazonaws.com",
              "firehose.${var.region}.amazonaws.com",
              "lambda.${var.region}.amazonaws.com",
            ]
          }
        }
      },
    ]
  })
}

resource "aws_kms_alias" "data" {
  count = var.create_kms_key ? 1 : 0

  name          = "alias/${local.name_prefix}"
  target_key_id = aws_kms_key.data[0].key_id
}

# ---------------------------------------------------------------------------
# Notificaciones
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alarms" {
  name              = "${local.name_prefix}-alarms"
  kms_master_key_id = var.create_kms_key ? aws_kms_key.data[0].id : "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "alarms_email" {
  count = var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ---------------------------------------------------------------------------
# Pipeline analitico
#
# Se crea antes que la tabla porque el modulo dynamodb necesita el ARN del stream
# para configurar la exportacion CDC.
# ---------------------------------------------------------------------------

module "analytics" {
  source = "./modules/analytics"

  name_prefix = local.name_prefix
  environment = var.environment
  region      = var.region
  account_id  = local.account_id
  bucket_name = local.lake_bucket
  kms_key_arn = local.kms_key_arn

  kinesis_stream_mode     = var.kinesis_stream_mode
  kinesis_shard_count     = var.kinesis_shard_count
  kinesis_retention_hours = var.kinesis_retention_hours

  firehose_buffer_mb      = var.firehose_buffer_mb
  firehose_buffer_seconds = var.firehose_buffer_seconds

  bronze_glacier_transition_days = var.bronze_glacier_transition_days
  projection_date_start          = var.projection_date_start

  sns_topic_arn = aws_sns_topic.alarms.arn
}

# ---------------------------------------------------------------------------
# Tabla operativa
# ---------------------------------------------------------------------------

module "dynamodb" {
  source = "./modules/dynamodb"

  table_name  = local.name_prefix
  environment = var.environment

  billing_mode = var.billing_mode
  capacity     = var.capacity

  deletion_protection    = var.deletion_protection
  point_in_time_recovery = var.point_in_time_recovery
  kms_key_arn            = local.kms_key_arn

  kinesis_stream_arn = module.analytics.kinesis_stream_arn
  sns_topic_arn      = aws_sns_topic.alarms.arn
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

module "iam" {
  source = "./modules/iam"

  name_prefix = local.name_prefix
  region      = var.region
  account_id  = local.account_id
  kms_key_arn = local.kms_key_arn

  table_arn  = module.dynamodb.table_arn
  index_arns = module.dynamodb.index_arns

  lake_bucket_arn   = module.analytics.lake_bucket_arn
  glue_database_arn = "arn:aws:glue:${var.region}:${local.account_id}:database/${module.analytics.glue_database}"
  glue_table_arns   = ["arn:aws:glue:${var.region}:${local.account_id}:table/${module.analytics.glue_database}/*"]

  eks_oidc_provider_arn       = var.eks_oidc_provider_arn
  game_server_service_account = var.game_server_service_account
  analytics_principal_arns    = var.analytics_principal_arns
}

# ---------------------------------------------------------------------------
# Guardarrail de gasto
#
# El techo de autoscaling limita el throughput, no la factura acumulada. El
# presupuesto es la red que detecta una fuga sostenida y de bajo caudal, que es
# la que se cuela sin disparar ninguna alarma tecnica.
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "persistence" {
  count = var.monthly_budget_usd > 0 ? 1 : 0

  name         = "${local.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Module$persistence"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.alarms.arn]
    subscriber_email_addresses = var.alarm_email != "" ? [var.alarm_email] : []
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.alarms.arn]
    subscriber_email_addresses = var.alarm_email != "" ? [var.alarm_email] : []
  }
}
