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

output "api_gateway_url" {
  value = aws_apigatewayv2_api.http_api.api_endpoint
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "cognito_app_client_id" {
  value = aws_cognito_user_pool_client.app_client.id
}

# --------------------------------------------------------------- Phase 7

output "frontend_bucket" {
  value = aws_s3_bucket.frontend.bucket
}

# --------------------------------------------------------------- Phase 8

output "website_url" {
  description = "The site. Custom domain once var.domain_name is set, otherwise the default CloudFront hostname."
  value = local.use_custom_domain ? "https://${var.domain_name}" : "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

# --------------------------------------------------------------- Phase 9

# Route 53 delegation mode: add these as NS records at PChome, with the name
# set to the subdomain label only — "test", not the full hostname.
output "route53_nameservers" {
  description = "Nameservers to delegate the subdomain to from PChome. Empty unless manage_dns_in_route53 and create_hosted_zone are both true."
  value       = try(aws_route53_zone.subdomain[0].name_servers, [])
}

# PChome-only mode: add these two by hand at PChome.
output "acm_validation_records" {
  description = "CNAME records proving domain ownership to ACM. Terraform creates these for you in Route 53 mode; in PChome-only mode you must add them yourself before the apply will finish."
  value = try([
    for dvo in aws_acm_certificate.frontend[0].domain_validation_options : {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  ], [])
}

output "site_cname_target" {
  description = "PChome-only mode: point a CNAME for your subdomain at this hostname."
  value       = aws_cloudfront_distribution.frontend.domain_name
}

output "acm_certificate_arn" {
  description = "The us-east-1 certificate CloudFront is using. Empty on the default certificate."
  value       = try(aws_acm_certificate.frontend[0].arn, "")
}

output "cloudfront_distribution_id" {
  description = "Needed for manual invalidations: aws cloudfront create-invalidation --distribution-id <id> --paths \"/*\""
  value       = aws_cloudfront_distribution.frontend.id
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.frontend.domain_name
}

output "allowed_origins" {
  description = "Origins permitted by both the API Gateway CORS config and the raw bucket CORS rule."
  value       = local.frontend_origins
}

# `terraform apply` already writes this to frontend/config.js via local_file.
# The output is here so you can inspect or regenerate it on demand:
#   terraform output -raw frontend_config
output "frontend_config" {
  description = "Contents of the generated frontend/config.js."
  value       = local.frontend_config_js
}