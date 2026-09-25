variable "name_prefix" {
  type = string
}

variable "table_arn" {
  type = string
}

variable "index_arns" {
  type = list(string)
}

variable "lake_bucket_arn" {
  type = string
}

variable "glue_database_arn" {
  type = string
}

variable "glue_table_arns" {
  type = list(string)
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "kms_key_arn" {
  type    = string
  default = null
}

variable "eks_oidc_provider_arn" {
  description = "Vacio -> el rol del servidor de juego confia en ec2.amazonaws.com (rol de nodo). Aceptable solo en dev."
  type        = string
  default     = ""
}

variable "game_server_service_account" {
  description = "namespace:serviceaccount para el trust de IRSA."
  type        = string
  default     = "default:pixelft-game-server"
}

variable "analytics_principal_arns" {
  type    = list(string)
  default = []
}
