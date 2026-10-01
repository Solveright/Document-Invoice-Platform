# Whole-account monthly cost backstop. Deliberately unfiltered (no cost-filter
# on project tags) so it also catches spend from anything outside this stack.
#
# AWS Budgets data lags by up to ~24h, so this is a backstop, not a real-time
# cap — the API stage throttle and the consumer's maximum_concurrency are what
# actually bound spend.
resource "aws_budgets_budget" "monthly_cost" {
  name         = "${var.project_name}-monthly-cost"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
