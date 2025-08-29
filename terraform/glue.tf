resource "aws_glue_catalog_database" "db" {
  name = replace("${local.name}_db", "-", "_")
}

# Store the ETL script in S3 so the Glue job can load it
resource "aws_s3_object" "glue_script" {
  bucket  = aws_s3_bucket.raw.id
  key     = "scripts/glue_job.py"
  content = file("${path.module}/glue/glue_job.py") 
  etag    = filemd5("${path.module}/glue/glue_job.py")
}

# Crawler (kept for catalog; do NOT run every 5 minutes)
resource "aws_glue_crawler" "raw_crawler" {
  name          = "${local.name}-crawler"
  role          = aws_iam_role.glue_role.arn
  database_name = aws_glue_catalog_database.db.name
  table_prefix  = "raw_"

  s3_target { path = "s3://${aws_s3_bucket.raw.bucket}/${var.raw_prefix}" }

  schema_change_policy {
    delete_behavior = "DEPRECATE_IN_DATABASE"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  tags = local.tags
}

resource "aws_glue_job" "etl" {
  name              = "${local.name}-etl"
  role_arn          = aws_iam_role.glue_role.arn
  glue_version      = "4.0"
  number_of_workers = 2
  worker_type       = "G.1X"

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${aws_s3_bucket.raw.bucket}/${aws_s3_object.glue_script.key}"
  }

  # Arguments that are always present (Step Functions will ADD --RAW_DATE at runtime)
  default_arguments = {
    "--job-language"                     = "python"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
    "--job-bookmark-option"              = "job-bookmark-enable"

    "--RAW_BUCKET"       = aws_s3_bucket.raw.bucket
    "--RAW_PREFIX"       = var.raw_prefix # e.g. "raw/"
    "--PROCESSED_BUCKET" = aws_s3_bucket.processed.bucket
    "--PROCESSED_PREFIX" = var.processed_prefix # e.g. "processed/"

    # (Optional) Spark tuning; keep simple for now. If you want multiple --conf entries,
    # you can pack them into one string like below.
    "--conf" = "spark.sql.shuffle.partitions=48 --conf spark.default.parallelism=48 --conf spark.sql.files.maxPartitionBytes=134217728 --conf spark.sql.files.openCostInBytes=134217728"
  }

  tags = local.tags
}

resource "aws_glue_catalog_table" "processed_table" {
  name          = "${local.name}_processed"
  database_name = aws_glue_catalog_database.db.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification = "parquet"
    EXTERNAL       = "TRUE"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.processed.bucket}/${var.processed_prefix}"
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
      name = "timestamp_ts"
      type = "timestamp"
    }
    columns {
      name = "service"
      type = "string"
    }
    columns {
      name = "level"
      type = "string"
    }
    columns {
      name = "latency_ms"
      type = "bigint"
    }
    columns {
      name = "message"
      type = "string"
    }
  }

  # <-- Use a BLOCK, not a list
  partition_keys {
    name = "ingest_date"
    type = "date"
  }
}


