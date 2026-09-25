output "game_server_role_arn" {
  description = "Anotar en el ServiceAccount del GameServer: eks.amazonaws.com/role-arn"
  value       = aws_iam_role.game_server.arn
}

output "game_server_role_name" {
  value = aws_iam_role.game_server.name
}

output "analytics_role_arn" {
  value = aws_iam_role.analytics.arn
}
