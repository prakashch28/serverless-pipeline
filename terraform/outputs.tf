output "raw_bucket" { value = aws_s3_bucket.raw.bucket }
output "processed_bucket" { value = aws_s3_bucket.processed.bucket }
output "lambda_name" { value = aws_lambda_function.ingest.function_name }
output "glue_job_name" { value = aws_glue_job.etl.name }
output "glue_database" { value = aws_glue_catalog_database.db.name }
output "state_machine_arn" { value = aws_sfn_state_machine.pipeline.arn }
