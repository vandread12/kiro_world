output "table_name" {
  value = aws_dynamodb_table.core.name
}

output "table_arn" {
  value = aws_dynamodb_table.core.arn
}

output "index_arns" {
  description = "ARNs de los indices. Necesarios en las policies IAM: un permiso sobre la tabla no cubre sus GSI."
  value       = ["${aws_dynamodb_table.core.arn}/index/*"]
}

output "gsi_name" {
  value = local.gsi_name
}

output "billing_mode" {
  value = aws_dynamodb_table.core.billing_mode
}
