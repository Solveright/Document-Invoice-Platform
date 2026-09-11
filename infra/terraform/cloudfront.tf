# ---------------------------------------------------------------------------
# Phase 8 — CloudFront
#
# Replaces the Phase 7 public S3 website endpoint. Two things change shape:
#
#   1. The origin is now the S3 REST endpoint (bucket.s3.<region>.amazonaws.com),
#      NOT the website endpoint. Origin Access Control only works against REST.
#      The REST endpoint has no index_document / error_document behaviour, so
#      directory-style URLs are handled by default_root_object (for "/") and
#      custom_error_response (for everything else).
#
#   2. The bucket goes private again. CloudFront authenticates to S3 with SigV4
#      using the OAC below, and the bucket policy trusts only this distribution.
# ---------------------------------------------------------------------------

locals {
  s3_origin_id = "s3-${aws_s3_bucket.frontend.id}"

  # Hosts the browser is allowed to talk to, used by the CSP below.
  #   - Cognito, for InitiateAuth / RespondToAuthChallenge
  #   - API Gateway, for POST and GET /documents
  #   - S3, for the presigned PUT (boto3 signs a regional virtual-hosted URL,
  #     but the legacy global form is allowed too so a SigV4 addressing change
  #     does not silently break uploads)
  #
  # execute-api is a wildcard rather than aws_apigatewayv2_api.http_api.api_endpoint
  # on purpose. Referencing the API here would create a dependency cycle:
  #   response_headers_policy -> api -> local.frontend_origins -> distribution
  #   -> response_headers_policy
  # because the API's CORS config has to know the CloudFront domain. A wildcard
  # on the leftmost label is valid CSP and breaks the loop.
  csp_connect_src = join(" ", [
    "'self'",
    "https://cognito-idp.${var.aws_region}.amazonaws.com",
    "https://*.execute-api.${var.aws_region}.amazonaws.com",
    "https://${aws_s3_bucket.raw_documents.bucket}.s3.${var.aws_region}.amazonaws.com",
    "https://${aws_s3_bucket.raw_documents.bucket}.s3.amazonaws.com",
  ])
}

# ---------------------------------------------------------------------------
# Origin Access Control
#
# OAC supersedes the older Origin Access Identity. OAI signed with a special
# IAM principal; OAC signs each origin request with SigV4, which is what makes
# it work with SSE-KMS buckets and every current region.
# ---------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.project_name}-${var.environment}-frontend-oac"
  description                       = "SigV4 access from CloudFront to the private site bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ---------------------------------------------------------------------------
# Cache policies
#
# AWS-managed policies rather than hand-rolled ones. CachingOptimized honours
# the Cache-Control headers we set on the S3 objects, so index.html and
# config.js (both no-cache) revalidate while the hashed-ish assets sit at
# max-age=300. config.js additionally gets its own behaviour with caching
# fully disabled, because a stale config points the app at the wrong stack.
# ---------------------------------------------------------------------------

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

resource "aws_cloudfront_response_headers_policy" "security" {
  name    = "${var.project_name}-${var.environment}-security-headers"
  comment = "Baseline security headers for the static site"

  security_headers_config {
    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = false
      preload                    = false
      override                   = true
    }

    dynamic "content_security_policy" {
      # Off by default. A wrong CSP fails closed and the app breaks with a
      # console error rather than anything obvious in the AWS console, so turn
      # it on deliberately once the happy path works.
      for_each = var.enable_csp ? [1] : []

      content {
        override = true
        content_security_policy = join("; ", [
          "default-src 'self'",
          "script-src 'self'",
          "style-src 'self'",
          "img-src 'self' data:",
          "connect-src ${local.csp_connect_src}",
          "frame-ancestors 'none'",
          "base-uri 'none'",
          "form-action 'none'",
        ])
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Distribution
# ---------------------------------------------------------------------------

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.project_name}-${var.environment} static site"
  default_root_object = "index.html"
  price_class         = var.cloudfront_price_class

  # Empty until var.domain_name is set. A distribution may only claim an alias
  # it holds a matching certificate for, which is why this and the
  # viewer_certificate block below are driven by the same condition.
  aliases = local.all_domain_names

  origin {
    origin_id                = local.s3_origin_id
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    target_origin_id = local.s3_origin_id

    # Free HTTPS on the *.cloudfront.net domain; plain HTTP is redirected.
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true

    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }

  ordered_cache_behavior {
    path_pattern     = "/config.js"
    target_origin_id = local.s3_origin_id

    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }

  # The REST origin returns 403 for missing keys (it will not leak whether the
  # object exists), so both codes map back to the app shell. Without this,
  # any path other than "/" is a raw XML error page.
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Exactly one of these renders. Two dynamic blocks rather than one block with
  # conditional attributes, because minimum_protocol_version and
  # ssl_support_method are rejected outright alongside the default certificate.
  dynamic "viewer_certificate" {
    for_each = local.use_custom_domain ? [] : [1]

    content {
      cloudfront_default_certificate = true
    }
  }

  dynamic "viewer_certificate" {
    for_each = local.use_custom_domain ? [1] : []

    content {
      # Depends on the validation resource, not the certificate itself, so the
      # distribution is never updated with a cert ACM has not yet issued.
      acm_certificate_arn      = aws_acm_certificate_validation.frontend[0].certificate_arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = "TLSv1.2_2021"
    }
  }

  tags = {
    Project = var.project_name
  }
}

# ---------------------------------------------------------------------------
# Invalidation
#
# Terraform uploads new objects but CloudFront keeps serving the cached copy
# until the TTL expires. index.html and config.js are no-cache so they
# revalidate immediately; styles.css and app.js sit at max-age=300. This wipes
# the edge cache whenever any asset changes so you are never debugging a stale
# bundle.
#
# Requires the AWS CLI on PATH. Set enable_cloudfront_invalidation = false to
# skip it and accept the 5-minute lag.
# ---------------------------------------------------------------------------

resource "terraform_data" "invalidate_cache" {
  count = var.enable_cloudfront_invalidation ? 1 : 0

  triggers_replace = {
    distribution = aws_cloudfront_distribution.frontend.id
    assets       = join(",", [for o in aws_s3_object.frontend_static : o.etag])
    config       = aws_s3_object.frontend_config.etag
  }

  # Explicit paths rather than "/*", for three reasons:
  #
  #   1. Portability. local-exec runs through `cmd /C` on Windows and `sh -c`
  #      on POSIX. cmd passes "/*" through with the quotes still attached, and
  #      CloudFront rejects a path that starts with a quote character. Dropping
  #      the quotes fixes Windows but then sh globs /* to the filesystem root.
  #      A list with no wildcard is unambiguous under both.
  #   2. Cost. AWS gives 1000 free invalidation paths per month; a wildcard
  #      counts differently and is easy to burn through on a tight edit loop.
  #   3. Precision. We know exactly which four objects exist.
  provisioner "local-exec" {
    command = join(" ", concat(
      [
        "aws cloudfront create-invalidation",
        "--distribution-id ${aws_cloudfront_distribution.frontend.id}",
        "--paths",
      ],
      [for key in keys(local.frontend_static_files) : "/${key}"],
      ["/config.js"],
    ))
  }
}
