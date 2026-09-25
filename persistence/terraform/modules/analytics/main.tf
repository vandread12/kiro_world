# ---------------------------------------------------------------------------
# Pipeline CDC -> Lakehouse
#
# Regla no negociable del diseno: el entorno analitico NUNCA lee la tabla
# operativa. Sin Scan, sin jobs de Spark contra DynamoDB. El acoplamiento por
# lectura es lo que degrada la latencia p99 del juego cuando alguien lanza una
# consulta pesada. La cadena completa es push: DynamoDB -> Kinesis -> Firehose -> S3.
# ---------------------------------------------------------------------------

locals {
  stream_name   = "${var.name_prefix}-cdc"
  firehose_name = "${var.name_prefix}-cdc-bronze"
  glue_db       = replace("${var.name_prefix}_lake", "-", "_")
  glue_table    = "cdc_bronze"

  entity_partitions = join(",", [
    "PROFILE",
    "PLAYER_STATS",
    "ITEM",
    "CURRENCY",
    "SQUAD",
    "SQUAD_STATS_SHARD",
    "MEMBER",
    "MATCH",
    "TRADE",
    "UNKNOWN",
  ])
}

# ---------------------------------------------------------------------------
# Kinesis Data Stream (fan-out del CDC)
# ---------------------------------------------------------------------------

resource "aws_kinesis_stream" "cdc" {
  name             = local.stream_name
  retention_period = var.kinesis_retention_hours

  stream_mode_details {
    stream_mode = var.kinesis_stream_mode
  }

  # Con ON_DEMAND el shard_count debe quedar sin definir.
  shard_count = var.kinesis_stream_mode == "PROVISIONED" ? var.kinesis_shard_count : null

  encryption_type = "KMS"
  kms_key_id      = coalesce(var.kms_key_arn, "alias/aws/kinesis")

  shard_level_metrics = [
    "IncomingBytes",
    "IncomingRecords",
    "IteratorAgeMilliseconds",
    "WriteProvisionedThroughputExceeded",
  ]
}

# ---------------------------------------------------------------------------
# S3 Data Lake
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "lake" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_versioning" "lake" {
  bucket = aws_s3_bucket.lake.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    # Reduce drasticamente las llamadas a KMS al escribir muchos objetos pequenos.
    bucket_key_enabled = var.kms_key_arn != null
  }
}

resource "aws_s3_bucket_public_access_block" "lake" {
  bucket                  = aws_s3_bucket.lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id

  # Bronze es append-only e inmutable. Tras el procesado a silver su lectura es
  # excepcional, asi que Glacier IR mantiene la recuperacion en milisegundos a una
  # fraccion del coste de Standard.
  rule {
    id     = "bronze-to-glacier-ir"
    status = "Enabled"

    filter {
      prefix = "bronze/"
    }

    transition {
      days          = var.bronze_glacier_transition_days
      storage_class = "GLACIER_IR"
    }
  }

  # Los multipart abortados son almacenamiento facturado e invisible en la consola.
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  # Los registros que fallan la conversion son reprocesables, pero conservarlos
  # indefinidamente convierte un bug puntual en coste permanente.
  rule {
    id     = "expire-conversion-errors"
    status = "Enabled"

    filter {
      prefix = "bronze_errors/"
    }

    expiration {
      days = 90
    }
  }
}

# ---------------------------------------------------------------------------
# Glue Data Catalog
# ---------------------------------------------------------------------------

resource "aws_glue_catalog_database" "lake" {
  name        = local.glue_db
  description = "Catalogo del Lakehouse de PixelRift (${var.environment})."
}

# El esquema de esta tabla es el contrato de la conversion a Parquet de Firehose.
# Debe coincidir en nombre y tipo con persistence/schemas/cdc-envelope.json; una
# divergencia rompe la conversion en silencio y todo aterriza en bronze_errors/.
resource "aws_glue_catalog_table" "bronze" {
  name          = local.glue_table
  database_name = aws_glue_catalog_database.lake.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL       = "TRUE"
    classification = "parquet"

    # Proyeccion de particiones en lugar de crawler: sin coste por ejecucion, sin
    # latencia de descubrimiento y sin particiones fantasma.
    "projection.enabled"          = "true"
    "projection.entity.type"      = "enum"
    "projection.entity.values"    = local.entity_partitions
    "projection.dt.type"          = "date"
    "projection.dt.format"        = "yyyy-MM-dd"
    "projection.dt.range"         = "${var.projection_date_start},NOW"
    "projection.dt.interval"      = "1"
    "projection.dt.interval.unit" = "DAYS"

    # $${...} escapa la interpolacion de Terraform: Athena debe recibir los
    # marcadores literales.
    "storage.location.template" = "s3://${aws_s3_bucket.lake.bucket}/bronze/entity=$${entity}/dt=$${dt}/"
  }

  # entity va primero porque las consultas analiticas casi siempre acotan un tipo
  # de entidad; asi calcular retencion no obliga a escanear el inventario.
  partition_keys {
    name = "entity"
    type = "string"
  }

  partition_keys {
    name = "dt"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.lake.bucket}/bronze/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "event_id"
      type = "string"
    }
    columns {
      name = "event_name"
      type = "string"
    }
    columns {
      name = "event_ts"
      type = "bigint"
    }
    columns {
      name = "table_name"
      type = "string"
    }
    columns {
      name = "pk"
      type = "string"
    }
    columns {
      name = "sk"
      type = "string"
    }
    columns {
      name = "entity_type"
      type = "string"
    }
    columns {
      name    = "new_image"
      type    = "string"
      comment = "Documento posterior al cambio, JSON serializado. Se parsea en silver, no aqui."
    }
    columns {
      name    = "old_image"
      type    = "string"
      comment = "Documento anterior. Imprescindible para calcular el delta de un trade y auditar duplicaciones."
    }
    columns {
      name = "sequence_number"
      type = "string"
    }
    columns {
      name = "size_bytes"
      type = "bigint"
    }
  }
}

# ---------------------------------------------------------------------------
# Lambda de transformacion
# ---------------------------------------------------------------------------

data "archive_file" "transform" {
  type        = "zip"
  source_file = "${path.module}/lambda/firehose_transform.py"
  output_path = "${path.module}/.build/firehose_transform.zip"
}

resource "aws_iam_role" "transform" {
  name = "${var.name_prefix}-cdc-transform"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "transform_logs" {
  role       = aws_iam_role.transform.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "transform" {
  name              = "/aws/lambda/${var.name_prefix}-cdc-transform"
  retention_in_days = 14
}

resource "aws_lambda_function" "transform" {
  function_name = "${var.name_prefix}-cdc-transform"
  role          = aws_iam_role.transform.arn
  handler       = "firehose_transform.handler"
  runtime       = "python3.12"

  filename         = data.archive_file.transform.output_path
  source_code_hash = data.archive_file.transform.output_base64sha256

  # Firehose corta la invocacion a los 5 min; agotar el timeout de Lambda antes
  # produce un error claro en lugar de un corte opaco del lado de Firehose.
  timeout     = 120
  memory_size = 512

  environment {
    variables = {
      DROP_ENTITIES   = "IDEM"
      MAX_IMAGE_BYTES = "400000"
    }
  }

  depends_on = [aws_cloudwatch_log_group.transform]
}

# ---------------------------------------------------------------------------
# Firehose -> S3 (Parquet)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${local.firehose_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_stream" "firehose_s3" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

resource "aws_iam_role" "firehose" {
  name = "${var.name_prefix}-firehose"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "sts:ExternalId" = var.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "firehose" {
  name = "${var.name_prefix}-firehose"
  role = aws_iam_role.firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "S3Write"
          Effect = "Allow"
          Action = [
            "s3:AbortMultipartUpload",
            "s3:GetBucketLocation",
            "s3:GetObject",
            "s3:ListBucket",
            "s3:ListBucketMultipartUploads",
            "s3:PutObject",
          ]
          Resource = [
            aws_s3_bucket.lake.arn,
            "${aws_s3_bucket.lake.arn}/*",
          ]
        },
        {
          Sid      = "KinesisRead"
          Effect   = "Allow"
          Action   = ["kinesis:DescribeStream", "kinesis:DescribeStreamSummary", "kinesis:GetShardIterator", "kinesis:GetRecords", "kinesis:ListShards"]
          Resource = aws_kinesis_stream.cdc.arn
        },
        {
          Sid    = "GlueSchemaForParquetConversion"
          Effect = "Allow"
          Action = ["glue:GetDatabase", "glue:GetTable", "glue:GetTableVersion", "glue:GetTableVersions"]
          Resource = [
            "arn:aws:glue:${var.region}:${var.account_id}:catalog",
            aws_glue_catalog_database.lake.arn,
            aws_glue_catalog_table.bronze.arn,
          ]
        },
        {
          Sid      = "InvokeTransform"
          Effect   = "Allow"
          Action   = ["lambda:InvokeFunction", "lambda:GetFunctionConfiguration"]
          Resource = "${aws_lambda_function.transform.arn}:*"
        },
        {
          Sid      = "Logs"
          Effect   = "Allow"
          Action   = ["logs:PutLogEvents", "logs:CreateLogStream"]
          Resource = "${aws_cloudwatch_log_group.firehose.arn}:*"
        },
      ],
      var.kms_key_arn == null ? [] : [
        {
          Sid      = "Kms"
          Effect   = "Allow"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
          Resource = var.kms_key_arn
        }
      ]
    )
  })
}

resource "aws_kinesis_firehose_delivery_stream" "bronze" {
  name        = local.firehose_name
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.cdc.arn
    role_arn           = aws_iam_role.firehose.arn
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = aws_s3_bucket.lake.arn

    # 128 MB / 300 s: ~5 min de latencia analitica a cambio de ficheros Parquet de
    # tamano sano. El small-files problem degrada las consultas de Spark mas que
    # cualquier optimizacion posterior. Todo lo que exija tiempo real (leaderboard)
    # sale por un consumidor propio del stream, no por esta rama.
    buffering_size     = var.firehose_buffer_mb
    buffering_interval = var.firehose_buffer_seconds

    # Obligatorio UNCOMPRESSED cuando la conversion de formato esta activa: la
    # compresion la aplica el SerDe de Parquet (Snappy), no S3.
    compression_format = "UNCOMPRESSED"

    prefix              = "bronze/entity=!{partitionKeyFromLambda:entity}/dt=!{partitionKeyFromLambda:dt}/"
    error_output_prefix = "bronze_errors/result=!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd}/"

    kms_key_arn = var.kms_key_arn

    dynamic_partitioning_configuration {
      enabled = true
    }

    processing_configuration {
      enabled = true

      processors {
        type = "Lambda"

        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = "${aws_lambda_function.transform.arn}:$LATEST"
        }

        parameters {
          parameter_name  = "BufferSizeInMBs"
          parameter_value = "3"
        }

        parameters {
          parameter_name  = "BufferIntervalInSeconds"
          parameter_value = "60"
        }
      }
    }

    data_format_conversion_configuration {
      input_format_configuration {
        deserializer {
          open_x_json_ser_de {}
        }
      }

      output_format_configuration {
        serializer {
          parquet_ser_de {
            compression = "SNAPPY"
          }
        }
      }

      schema_configuration {
        role_arn      = aws_iam_role.firehose.arn
        database_name = aws_glue_catalog_database.lake.name
        table_name    = aws_glue_catalog_table.bronze.name
        region        = var.region
      }
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose_s3.name
    }
  }
}

# ---------------------------------------------------------------------------
# Alarmas del pipeline
# ---------------------------------------------------------------------------

# La mas importante del modulo: si el consumidor se retrasa mas que la retencion
# del stream, la perdida de datos es irrecuperable.
resource "aws_cloudwatch_metric_alarm" "iterator_age" {
  alarm_name          = "${local.stream_name}-iterator-age"
  alarm_description   = "El consumidor va por detras. Con retencion de ${var.kinesis_retention_hours} h, rebasarla implica perdida definitiva de CDC."
  namespace           = "AWS/Kinesis"
  metric_name         = "GetRecords.IteratorAgeMilliseconds"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.iterator_age_alarm_hours * 3600 * 1000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { StreamName = aws_kinesis_stream.cdc.name }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "delivery_freshness" {
  alarm_name          = "${local.firehose_name}-freshness"
  alarm_description   = "Antiguedad del dato mas viejo sin entregar a S3. Incumple el SLA de <10 min de latencia CDC."
  namespace           = "AWS/Firehose"
  metric_name         = "DeliveryToS3.DataFreshness"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 900
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { DeliveryStreamName = aws_kinesis_firehose_delivery_stream.bronze.name }

  alarm_actions = [var.sns_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "transform_errors" {
  alarm_name          = "${var.name_prefix}-cdc-transform-errors"
  alarm_description   = "Fallos del transform. Los registros afectados van a bronze_errors/ y son reprocesables, pero un error sostenido implica hueco en el lake."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { FunctionName = aws_lambda_function.transform.function_name }

  alarm_actions = [var.sns_topic_arn]
}
