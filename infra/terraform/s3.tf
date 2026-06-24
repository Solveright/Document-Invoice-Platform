resource "aws_s3_bucket" "raw_documents" {
  bucket = "${var.project_name}-${var.environment}-raw-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "processed_documents" {
  bucket = "${var.project_name}-${var.environment}-processed-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "raw_documents" {
  bucket = aws_s3_bucket.raw_documents.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw_documents" {
  bucket = aws_s3_bucket.raw_documents.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}