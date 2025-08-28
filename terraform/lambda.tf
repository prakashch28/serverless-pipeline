data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "ingest" {
  function_name = "${local.name}-ingest"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.11"
  handler       = "ingest_lambda.handler"
  memory_size   = 2048 #~ 2cpus
  timeout       = 900
  filename      = data.archive_file.lambda_zip.output_path

  environment {
    variables = {
      RAW_BUCKET   = aws_s3_bucket.raw.bucket
      RAW_PREFIX   = var.raw_prefix
      LOG_SAMPLE_K = "3"
      RECORD_BYTES = tostring(var.record_bytes)
    }
  }
  tags = local.tags
}