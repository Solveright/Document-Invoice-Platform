# ---------------------------------------------------------------------------
# Phase 9 — DNS
#
# solveright.com.tw is a live production domain whose DNS is managed at PChome
# (apex, www, case, and MX records). This file deliberately does NOT touch any
# of that. Only the single subdomain in var.domain_name is involved.
#
# There are two ways to run this, controlled by var.manage_dns_in_route53:
#
# ── true (default) — subdomain delegation ─────────────────────────────────
#   Terraform creates a Route 53 hosted zone for the subdomain and manages the
#   records inside it. You delegate once, by hand, at PChome:
#
#     terraform output -json route53_nameservers
#
#   then add four NS records at PChome with the name "test" (the label only,
#   not the full hostname), one per nameserver. Everything else at PChome keeps
#   resolving exactly as it does today.
#
#   This is the better architecture and the one Phase 9 is actually about —
#   but it requires PChome's DNS panel to support NS records. Not every
#   registrar control panel does. If yours only offers A / CNAME / MX / TXT,
#   use the other mode.
#
# ── false — DNS stays entirely at PChome ──────────────────────────────────
#   No hosted zone, no Route 53 records. Terraform still requests the ACM
#   certificate, then waits while you add two records at PChome by hand:
#
#     terraform output -json acm_validation_records   # CNAME, proves ownership
#     terraform output site_cname_target              # CNAME, points at CloudFront
#
#   Simpler and it always works, but Phase 9 stops exercising Route 53.
#
# Everything here is inert until var.domain_name is set.
# ---------------------------------------------------------------------------

locals {
  use_custom_domain = var.domain_name != ""

  # Names the certificate must cover and CloudFront must answer for.
  all_domain_names = local.use_custom_domain ? concat(
    [var.domain_name],
    var.additional_domain_names,
  ) : []

  manage_dns = local.use_custom_domain && var.manage_dns_in_route53

  zone_id = local.manage_dns ? (
    var.create_hosted_zone
    ? aws_route53_zone.subdomain[0].zone_id
    : data.aws_route53_zone.existing[0].zone_id
  ) : null
}

# ---------------------------------------------------------------------------
# Hosted zone
# ---------------------------------------------------------------------------

resource "aws_route53_zone" "subdomain" {
  count = local.manage_dns && var.create_hosted_zone ? 1 : 0

  name    = var.domain_name
  comment = "Delegated subdomain for ${var.project_name}. Parent zone stays at PChome."

  tags = {
    Project = var.project_name
  }
}

data "aws_route53_zone" "existing" {
  count = local.manage_dns && !var.create_hosted_zone ? 1 : 0

  name         = var.domain_name
  private_zone = false
}

# ---------------------------------------------------------------------------
# ACM certificate
#
# CloudFront only reads certificates from us-east-1, no matter where the rest
# of the stack lives. Hence the provider alias — this is the single most
# common Phase 9 trip-up.
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "frontend" {
  count = local.use_custom_domain ? 1 : 0

  provider = aws.us_east_1

  domain_name               = var.domain_name
  subject_alternative_names = var.additional_domain_names
  validation_method         = "DNS"

  # The distribution references this cert, so it can never be destroyed before
  # its replacement exists.
  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Project = var.project_name
  }
}

# Only created when Route 53 holds the zone. In PChome-only mode these records
# are your job — see the acm_validation_records output.
resource "aws_route53_record" "cert_validation" {
  for_each = local.manage_dns ? {
    for dvo in aws_acm_certificate.frontend[0].domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id = local.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60

  # ACM reuses validation records across renewals; without this a re-issue
  # collides with the record already in the zone.
  allow_overwrite = true
}

# Blocks until ACM sees the DNS records and issues the certificate.
#
# In Route 53 mode, a hang here means the NS delegation at PChome is missing or
# wrong. In PChome-only mode it simply means you have not added the CNAME yet —
# the apply is waiting on you, which is why the timeout is generous.
resource "aws_acm_certificate_validation" "frontend" {
  count = local.use_custom_domain ? 1 : 0

  provider = aws.us_east_1

  certificate_arn = aws_acm_certificate.frontend[0].arn

  # Only pass FQDNs we actually created. Passing an empty list would tell ACM
  # we manage nothing, so in PChome-only mode this attribute is omitted and the
  # resource just polls until the certificate reaches ISSUED.
  validation_record_fqdns = local.manage_dns ? [
    for record in aws_route53_record.cert_validation : record.fqdn
  ] : null

  timeouts {
    create = "45m"
  }
}

# ---------------------------------------------------------------------------
# Alias records
#
# A/AAAA aliases rather than CNAMEs. Aliases are free to resolve, work at a
# zone apex (a CNAME cannot), and Route 53 resolves them to CloudFront's
# current edge IPs automatically.
#
# In PChome-only mode you add a single CNAME instead — see site_cname_target.
# ---------------------------------------------------------------------------

resource "aws_route53_record" "frontend_ipv4" {
  for_each = local.manage_dns ? toset(local.all_domain_names) : toset([])

  zone_id = local.zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.frontend.domain_name
    zone_id                = aws_cloudfront_distribution.frontend.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "frontend_ipv6" {
  for_each = local.manage_dns ? toset(local.all_domain_names) : toset([])

  zone_id = local.zone_id
  name    = each.value
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.frontend.domain_name
    zone_id                = aws_cloudfront_distribution.frontend.hosted_zone_id
    evaluate_target_health = false
  }
}
