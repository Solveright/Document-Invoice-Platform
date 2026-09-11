variable "aws_region" {
  description = "AWS deployment region"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "document-invoice-platform"
}

variable "environment" {
  description = "Environment"
  type        = string
  default     = "dev"
}

variable "local_dev_origins" {
  description = "Origins allowed for local frontend development. Set to [] to lock the API down to the deployed site only."
  type        = list(string)
  default = [
    "http://localhost:8000",
    "http://127.0.0.1:8000",
    "http://localhost:5500",
    "http://127.0.0.1:5500",
  ]
}

variable "extra_frontend_origins" {
  description = "Additional allowed origins, e.g. the CloudFront or custom-domain URL added in Phases 8-9."
  type        = list(string)
  default     = []
}

variable "max_upload_bytes" {
  description = "Largest PDF the API will issue a presigned upload URL for. Capped by Textract's 10 MB synchronous limit as of Phase 10 — anything larger uploads fine but fails extraction."
  type        = number
  default     = 10485760 # 10 MB

  validation {
    condition     = var.max_upload_bytes <= 10485760
    error_message = "Textract's synchronous AnalyzeExpense limit is 10 MB. Larger files need the asynchronous StartExpenseAnalysis API, which this project does not implement."
  }
}

variable "upload_url_ttl_seconds" {
  description = "Lifetime of a presigned upload URL. Keep short; it is a bearer credential."
  type        = number
  default     = 900
}

# --------------------------------------------------------------- Phase 8

variable "cloudfront_price_class" {
  description = "Edge locations to use. PriceClass_100 is cheapest but excludes Asia entirely, which is useless from Tokyo. PriceClass_200 adds Japan; PriceClass_All adds South America and Oceania."
  type        = string
  default     = "PriceClass_200"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cloudfront_price_class)
    error_message = "Must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

variable "enable_cloudfront_invalidation" {
  description = "Run `aws cloudfront create-invalidation` after uploading changed assets. Requires the AWS CLI on PATH. Set false to skip and accept a stale edge cache until the TTL expires."
  type        = bool
  default     = true
}

# -------------------------------------------------------------- Phase 10

variable "textract_region" {
  description = "Where to call Textract. It is NOT available in ap-northeast-1, so the consumer reads the PDF from the Tokyo bucket and sends the raw bytes to the nearest supported region. Seoul is closest. Valid alternatives: ap-southeast-1, ap-southeast-2, ap-south-1."
  type        = string
  default     = "ap-northeast-2"
}

# --------------------------------------------------------------- Phase 9

variable "domain_name" {
  description = "Custom hostname for the site, e.g. test.solveright.com.tw. Leave empty to stay on the *.cloudfront.net domain — everything in route53.tf is inert until this is set."
  type        = string
  default     = ""
}

variable "additional_domain_names" {
  description = "Extra hostnames the certificate should cover and CloudFront should answer for."
  type        = list(string)
  default     = []
}

variable "manage_dns_in_route53" {
  description = "true: Terraform holds a Route 53 hosted zone for the subdomain and you delegate to it with NS records at PChome. false: DNS stays entirely at PChome and you add the ACM validation CNAME and the site CNAME by hand. Set false if PChome's DNS panel does not support NS records."
  type        = bool
  default     = true
}

variable "create_hosted_zone" {
  description = "Only applies when manage_dns_in_route53 is true. Create the hosted zone, or set false to look up one that already exists."
  type        = bool
  default     = true
}

variable "enable_csp" {
  description = "Send a Content-Security-Policy header. Off by default because a wrong CSP fails closed — turn it on once the upload flow works end to end."
  type        = bool
  default     = false
}