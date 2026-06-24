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