resource "aws_sqs_queue" "document_processing_dlq" {
  name                      = "${var.project_name}-${var.environment}-document-processing-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "document_processing_queue" {
  name = "${var.project_name}-${var.environment}-document-processing-queue"

  # AWS recommends the visibility timeout be at least 6x the consuming
  # function's timeout. The consumer is 45s (Textract is a synchronous network
  # call), so 300s. Too low and SQS redelivers a message the Lambda is still
  # working on, which shows up as duplicate Textract charges.
  visibility_timeout_seconds = 300
  message_retention_seconds  = 345600

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.document_processing_dlq.arn
    maxReceiveCount     = 3
  })
}

# ---------------------------------------------------------------------------
# Phase 10 — let S3 publish to this queue
#
# The SourceArn/SourceAccount conditions matter: without them any S3 bucket in
# any account could push messages here. This is the same confused-deputy
# pattern as the CloudFront bucket policy in frontend.tf.
# ---------------------------------------------------------------------------

resource "aws_sqs_queue_policy" "allow_s3_notifications" {
  queue_url = aws_sqs_queue.document_processing_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRawBucketNotifications"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.document_processing_queue.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = aws_s3_bucket.raw_documents.arn
          }
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}