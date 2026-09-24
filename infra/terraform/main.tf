# IMPORTANT: always run `terraform apply -var-file=test.tfvars` in this
# directory. A bare `apply` (no var-file) drifts against the live
# test.solveright.com.tw ACM cert / Route 53 config and will DESTROY that
# cert. See test.tfvars for the values that must be supplied.

terraform {
  # use_lockfile (S3-native locking) needs >= 1.10. State is written by
  # 1.15.x, so older binaries (e.g. a future CI runner) can't read it anyway.
  required_version = ">= 1.10.0"

  # State bucket is created out-of-band (aws s3api), NOT managed by this
  # config: versioned, SSE-S3, public access blocked, TLS-only policy.
  # Locking is S3-native (use_lockfile); DynamoDB locking is deprecated.
  backend "s3" {
    bucket       = "document-invoice-platform-tfstate-366258938367"
    key          = "dev/terraform.tfstate"
    region       = "ap-northeast-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    # Used to write the generated frontend/config.js back to disk.
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# CloudFront only accepts ACM certificates issued in us-east-1, regardless of
# where the rest of the stack lives. Used by route53.tf.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}