output "kinesis_stream_arn" {
  value = aws_kinesis_stream.cdc.arn
}

output "kinesis_stream_name" {
  value = aws_kinesis_stream.cdc.name
}

output "lake_bucket" {
  value = aws_s3_bucket.lake.bucket
}

output "lake_bucket_arn" {
  value = aws_s3_bucket.lake.arn
}

output "glue_database" {
  value = aws_glue_catalog_database.lake.name
}

output "glue_bronze_table" {
  value = aws_glue_catalog_table.bronze.name
}

output "firehose_name" {
  value = aws_kinesis_firehose_delivery_stream.bronze.name
}

output "athena_bronze_reference" {
  description = "Referencia lista para consultar en Athena. Acotar siempre por entity y dt: sin filtro de particion la consulta escanea el lake completo."
  value       = "${aws_glue_catalog_database.lake.name}.${aws_glue_catalog_table.bronze.name}"
}
