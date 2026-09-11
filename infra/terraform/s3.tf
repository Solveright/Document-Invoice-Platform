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

# ---------------------------------------------------------------------------
# Phase 7 — browser uploads
#
# The presigned PUT is issued by Lambda but executed by the browser, which
# means S3 sees a cross-origin request and will preflight it. Without this
# rule the OPTIONS preflight fails and the PUT never fires.
#
# The bucket stays private: the CORS rule governs which origins the *browser*
# may talk to, it grants no permission of its own. Access still comes entirely
# from the signature on the URL.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket_cors_configuration" "raw_documents" {
  bucket = aws_s3_bucket.raw_documents.id

  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = local.frontend_origins
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_public_access_block" "raw_documents" {
  bucket = aws_s3_bucket.raw_documents.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "processed_documents" {
  bucket = aws_s3_bucket.processed_documents.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# Phase 10 — the processing trigger
#
# This is what makes the pipeline correct. The API used to enqueue at presign
# time, before the bytes existed. ObjectCreated fires only once the object is
# durably stored, so there is no race to lose.
#
# Filters keep the queue clean: only the uploads/ prefix, only .pdf. Note that
# S3 allows just one notification configuration per bucket — adding a second
# aws_s3_bucket_notification resource silently replaces this one rather than
# merging with it.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket_notification" "raw_documents" {
  bucket = aws_s3_bucket.raw_documents.id

  queue {
    queue_arn     = aws_sqs_queue.document_processing_queue.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "uploads/"
    filter_suffix = ".pdf"
  }

  # S3 validates it can publish before accepting the configuration, so the
  # queue policy has to exist first.
  depends_on = [aws_sqs_queue_policy.allow_s3_notifications]
}

# Multipart uploads that the browser abandons (tab closed mid-PUT) leave
# billable parts behind forever otherwise.
resource "aws_s3_bucket_lifecycle_configuration" "raw_documents" {
  bucket = aws_s3_bucket.raw_documents.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}