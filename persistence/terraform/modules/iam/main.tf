locals {
  use_irsa = var.eks_oidc_provider_arn != ""

  oidc_issuer = local.use_irsa ? replace(
    element(split("oidc-provider/", var.eks_oidc_provider_arn), 1),
    "https://",
    ""
  ) : ""

  sa_parts     = split(":", var.game_server_service_account)
  sa_namespace = local.sa_parts[0]
  sa_name      = length(local.sa_parts) > 1 ? local.sa_parts[1] : "default"
}

# ---------------------------------------------------------------------------
# Rol del servidor de juego (pods de Agones)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "game_server_trust" {
  dynamic "statement" {
    # IRSA: credenciales de corta vida por pod y alcance limitado a un
    # ServiceAccount concreto.
    for_each = local.use_irsa ? [1] : []

    content {
      effect  = "Allow"
      actions = ["sts:AssumeRoleWithWebIdentity"]

      principals {
        type        = "Federated"
        identifiers = [var.eks_oidc_provider_arn]
      }

      condition {
        test     = "StringEquals"
        variable = "${local.oidc_issuer}:sub"
        values   = ["system:serviceaccount:${local.sa_namespace}:${local.sa_name}"]
      }

      condition {
        test     = "StringEquals"
        variable = "${local.oidc_issuer}:aud"
        values   = ["sts.amazonaws.com"]
      }
    }
  }

  dynamic "statement" {
    # Sin OIDC se recurre al rol de nodo: cualquier pod del nodo hereda estos
    # permisos. Es una degradacion real de la seguridad, admisible solo en dev.
    for_each = local.use_irsa ? [] : [1]

    content {
      effect  = "Allow"
      actions = ["sts:AssumeRole"]

      principals {
        type        = "Service"
        identifiers = ["ec2.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role" "game_server" {
  name               = "${var.name_prefix}-game-server"
  description        = "Rol del backend autoritativo. Acceso a la tabla operativa por clave; Scan denegado explicitamente."
  assume_role_policy = data.aws_iam_policy_document.game_server_trust.json
}

data "aws_iam_policy_document" "game_server" {
  statement {
    sid    = "ItemLevelAccess"
    effect = "Allow"

    actions = [
      "dynamodb:GetItem",
      "dynamodb:BatchGetItem",
      "dynamodb:Query",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:ConditionCheckItem",
      "dynamodb:TransactGetItems",
      "dynamodb:TransactWriteItems",
      "dynamodb:DescribeTable",
    ]

    resources = concat([var.table_arn], var.index_arns)
  }

  # Scan es la operacion que convierte un bug de codigo en una factura y en una
  # subida de la latencia p99 para todos los jugadores. No hay ningun patron de
  # acceso legitimo del servidor que lo necesite: todos se resuelven por clave.
  statement {
    sid       = "DenyScan"
    effect    = "Deny"
    actions   = ["dynamodb:Scan"]
    resources = concat([var.table_arn], var.index_arns)
  }

  # El servidor de juego no administra infraestructura. Sin este Deny, unas
  # credenciales filtradas podrian borrar la tabla o desactivar el PITR.
  statement {
    sid    = "DenyControlPlane"
    effect = "Deny"

    actions = [
      "dynamodb:DeleteTable",
      "dynamodb:CreateTable",
      "dynamodb:UpdateTable",
      "dynamodb:UpdateTimeToLive",
      "dynamodb:UpdateContinuousBackups",
      "dynamodb:DisableKinesisStreamingDestination",
      "dynamodb:PutResourcePolicy",
      "dynamodb:DeleteResourcePolicy",
    ]

    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.kms_key_arn == null ? [] : [1]

    content {
      sid       = "KmsForTable"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
      resources = [var.kms_key_arn]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["dynamodb.${var.region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_policy" "game_server" {
  name   = "${var.name_prefix}-game-server"
  policy = data.aws_iam_policy_document.game_server.json
}

resource "aws_iam_role_policy_attachment" "game_server" {
  role       = aws_iam_role.game_server.name
  policy_arn = aws_iam_policy.game_server.arn
}

# ---------------------------------------------------------------------------
# Rol de analitica
#
# Este rol es el mecanismo que HACE CUMPLIR el aislamiento entre el juego y la
# analitica. La regla "la analitica nunca lee la tabla operativa" no puede
# depender de que todo el mundo recuerde la convencion: se codifica como un Deny
# explicito, que en IAM prevalece sobre cualquier Allow que alguien adjunte
# despues.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "analytics_trust" {
  dynamic "statement" {
    for_each = length(var.analytics_principal_arns) > 0 ? [1] : []

    content {
      effect  = "Allow"
      actions = ["sts:AssumeRole"]

      principals {
        type        = "AWS"
        identifiers = var.analytics_principal_arns
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.analytics_principal_arns) > 0 ? [] : [1]

    content {
      effect  = "Allow"
      actions = ["sts:AssumeRole"]

      principals {
        type        = "Service"
        identifiers = ["glue.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role" "analytics" {
  name               = "${var.name_prefix}-analytics"
  description        = "Rol de analitica: lectura del Data Lake, acceso a la tabla operativa denegado explicitamente."
  assume_role_policy = data.aws_iam_policy_document.analytics_trust.json
}

data "aws_iam_policy_document" "analytics" {
  statement {
    sid    = "DenyOperationalTable"
    effect = "Deny"

    actions   = ["dynamodb:*"]
    resources = concat([var.table_arn], var.index_arns)
  }

  statement {
    sid    = "LakeRead"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]

    resources = [
      var.lake_bucket_arn,
      "${var.lake_bucket_arn}/*",
    ]
  }

  # Athena necesita escribir sus resultados. Se acota a un unico prefijo para que
  # el rol no pueda sobrescribir bronze ni silver.
  statement {
    sid       = "AthenaResultsWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${var.lake_bucket_arn}/athena-results/*"]
  }

  statement {
    sid    = "GlueCatalogRead"
    effect = "Allow"

    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
    ]

    resources = concat(
      ["arn:aws:glue:${var.region}:${var.account_id}:catalog", var.glue_database_arn],
      var.glue_table_arns
    )
  }

  statement {
    sid    = "AthenaQuery"
    effect = "Allow"

    actions = [
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetWorkGroup",
      "athena:StopQueryExecution",
      "athena:ListWorkGroups",
    ]

    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.kms_key_arn == null ? [] : [1]

    content {
      sid       = "KmsForLake"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
      resources = [var.kms_key_arn]
    }
  }
}

resource "aws_iam_policy" "analytics" {
  name   = "${var.name_prefix}-analytics"
  policy = data.aws_iam_policy_document.analytics.json
}

resource "aws_iam_role_policy_attachment" "analytics" {
  role       = aws_iam_role.analytics.name
  policy_arn = aws_iam_policy.analytics.arn
}
