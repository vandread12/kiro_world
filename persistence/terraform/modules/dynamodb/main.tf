# ---------------------------------------------------------------------------
# Tabla unica pixelft-core (single-table design)
#
# Solo se declaran los atributos que participan en claves. El resto del
# documento es schemaless para DynamoDB: la forma se valida en el repository
# layer contra los esquemas de persistence/schemas/.
# ---------------------------------------------------------------------------

locals {
  provisioned = var.billing_mode == "PROVISIONED"

  # Un unico GSI con claves sobrecargadas, y ESPARSO: solo los documentos ITEM
  # escriben gsi1pk/gsi1sk, por lo que el indice contiene inventario y nada mas.
  # Eso acota la amplificacion de escritura a las mutaciones de item en lugar de
  # aplicarla a cada escritura de la tabla.
  gsi_name = "GSI1"

  autoscale_targets = local.provisioned ? {
    table_read = {
      resource_id = "table/${aws_dynamodb_table.core.name}"
      dimension   = "dynamodb:table:ReadCapacityUnits"
      metric      = "DynamoDBReadCapacityUtilization"
      min         = var.capacity.table_read_min
      max         = var.capacity.table_read_max
    }
    table_write = {
      resource_id = "table/${aws_dynamodb_table.core.name}"
      dimension   = "dynamodb:table:WriteCapacityUnits"
      metric      = "DynamoDBWriteCapacityUtilization"
      min         = var.capacity.table_write_min
      max         = var.capacity.table_write_max
    }
    index_read = {
      resource_id = "table/${aws_dynamodb_table.core.name}/index/${local.gsi_name}"
      dimension   = "dynamodb:index:ReadCapacityUnits"
      metric      = "DynamoDBReadCapacityUtilization"
      min         = var.capacity.index_read_min
      max         = var.capacity.index_read_max
    }
    index_write = {
      resource_id = "table/${aws_dynamodb_table.core.name}/index/${local.gsi_name}"
      dimension   = "dynamodb:index:WriteCapacityUnits"
      metric      = "DynamoDBWriteCapacityUtilization"
      min         = var.capacity.index_write_min
      max         = var.capacity.index_write_max
    }
  } : {}
}

resource "aws_dynamodb_table" "core" {
  name         = var.table_name
  billing_mode = var.billing_mode
  hash_key     = "PK"
  range_key    = "SK"

  read_capacity  = local.provisioned ? var.capacity.table_read_min : null
  write_capacity = local.provisioned ? var.capacity.table_write_min : null

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  attribute {
    name = "gsi1pk"
    type = "S"
  }

  attribute {
    name = "gsi1sk"
    type = "S"
  }

  # Auditoria inversa item_def -> propietarios. Alimenta el job diario de
  # deteccion de duplicados: dos propietarios para un mismo instance_id no
  # apilable es, por definicion, corrupcion.
  #
  # Proyeccion KEYS_ONLY deliberada. Con ALL, cada mutacion de un item (consumir
  # una pocion, cambiar durabilidad) duplicaria su coste de escritura al replicar
  # el documento completo al indice. KEYS_ONLY devuelve PK/SK, que es todo lo que
  # la auditoria necesita.
  global_secondary_index {
    name            = local.gsi_name
    hash_key        = "gsi1pk"
    range_key       = "gsi1sk"
    projection_type = "KEYS_ONLY"

    read_capacity  = local.provisioned ? var.capacity.index_read_min : null
    write_capacity = local.provisioned ? var.capacity.index_write_min : null
  }

  # El valor lo escribe la aplicacion en SEGUNDOS. DynamoDB ignora en silencio
  # los TTL expresados en milisegundos y el borrado nunca se produce.
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  deletion_protection_enabled = var.deletion_protection

  # El CDC sale por "Kinesis Data Streams for DynamoDB"
  # (aws_dynamodb_kinesis_streaming_destination), no por un DynamoDB Stream
  # clasico. Motivo: Kinesis admite N consumidores independientes (Firehose hacia
  # el lake, proyeccion a Redis, futuro antifraude) sin que un consumidor lento
  # bloquee a los demas. Habilitar ademas stream_enabled duplicaria el coste de
  # CDC sin aportar nada.
  stream_enabled = false

  lifecycle {
    # Con Auto Scaling activo, la capacidad real divergira de la declarada. Sin
    # este ignore, cada plan mostraria un diff espurio y el equipo aprenderia a
    # ignorar los planes.
    #
    # Contrapartida asumida: incluir global_secondary_index bloquea tambien los
    # cambios legitimos de indice. Se acepta porque anadir o quitar un GSI en
    # DynamoDB ya exige un procedimiento deliberado (operacion online, de uno en
    # uno); no es algo que deba colarse en un apply rutinario.
    ignore_changes = [read_capacity, write_capacity, global_secondary_index]
  }
}

# ---------------------------------------------------------------------------
# Auto Scaling (solo PROVISIONED)
# ---------------------------------------------------------------------------

resource "aws_appautoscaling_target" "this" {
  for_each = local.autoscale_targets

  service_namespace  = "dynamodb"
  resource_id        = each.value.resource_id
  scalable_dimension = each.value.dimension
  min_capacity       = each.value.min
  max_capacity       = each.value.max
}

resource "aws_appautoscaling_policy" "this" {
  for_each = local.autoscale_targets

  name               = "${var.table_name}-${each.key}"
  service_namespace  = aws_appautoscaling_target.this[each.key].service_namespace
  resource_id        = aws_appautoscaling_target.this[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.this[each.key].scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    target_value = var.capacity.target_pct

    predefined_metric_specification {
      predefined_metric_type = each.value.metric
    }

    # Subir rapido, bajar despacio: un scale-in agresivo ante un valle
    # momentaneo deja la tabla corta cuando el trafico vuelve, y el rearranque
    # se paga en throttling.
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# ---------------------------------------------------------------------------
# CDC hacia Kinesis
# ---------------------------------------------------------------------------

resource "aws_dynamodb_kinesis_streaming_destination" "cdc" {
  count = var.kinesis_stream_arn == null ? 0 : 1

  table_name = aws_dynamodb_table.core.name
  stream_arn = var.kinesis_stream_arn
}

# ---------------------------------------------------------------------------
# Alarmas
# ---------------------------------------------------------------------------

# Throttling sostenido en produccion es un incidente, no un ajuste de coste.
resource "aws_cloudwatch_metric_alarm" "read_throttle" {
  alarm_name          = "${var.table_name}-read-throttle"
  alarm_description   = "Lecturas rechazadas por falta de capacidad. Degrada la latencia de MATCH_JOIN."
  namespace           = "AWS/DynamoDB"
  metric_name         = "ReadThrottleEvents"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { TableName = aws_dynamodb_table.core.name }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "write_throttle" {
  alarm_name          = "${var.table_name}-write-throttle"
  alarm_description   = "Escrituras rechazadas. Con MATCH_END transaccional implica progreso de partida perdido."
  namespace           = "AWS/DynamoDB"
  metric_name         = "WriteThrottleEvents"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { TableName = aws_dynamodb_table.core.name }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]
}

# Senal de conflicto de concurrencia o de intento de exploit de inventario.
resource "aws_cloudwatch_metric_alarm" "conditional_check_failures" {
  alarm_name          = "${var.table_name}-conditional-check-spike"
  alarm_description   = "Pico de fallos de ConditionExpression. Revisar reintentos de bloqueo optimista y patrones de trade antes de descartarlo como ruido."
  namespace           = "AWS/DynamoDB"
  metric_name         = "ConditionalCheckFailedRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.conditional_check_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { TableName = aws_dynamodb_table.core.name }

  alarm_actions = [var.sns_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "system_errors" {
  alarm_name          = "${var.table_name}-system-errors"
  alarm_description   = "Errores 5xx del servicio. No son responsabilidad de la aplicacion, pero obligan a verificar que los reintentos del SDK esten activos."
  namespace           = "AWS/DynamoDB"
  metric_name         = "SystemErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { TableName = aws_dynamodb_table.core.name }

  alarm_actions = [var.sns_topic_arn]
}
