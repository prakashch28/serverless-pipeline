resource "aws_s3_bucket" "raw" {
  bucket        = "${var.project}-${local.env}-raw-${local.suffix}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket" "processed" {
  bucket        = "${var.project}-${local.env}-processed-${local.suffix}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "raw_block" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "processed_block" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "raw_ver" {
  bucket = aws_s3_bucket.raw.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "processed_ver" {
  bucket = aws_s3_bucket.processed.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw_enc" {
  bucket = aws_s3_bucket.raw.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "processed_enc" {
  bucket = aws_s3_bucket.processed.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}