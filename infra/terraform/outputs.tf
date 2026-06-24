output "raw_documents_bucket" {
  value = aws_s3_bucket.raw_documents.bucket
}

output "processed_documents_bucket" {
  value = aws_s3_bucket.processed_documents.bucket
}

output "documents_table_name" {
  value = aws_dynamodb_table.documents.name
}

output "processing_queue_url" {
  value = aws_sqs_queue.document_processing_queue.url
}

output "dlq_url" {
  value = aws_sqs_queue.document_processing_dlq.url
}