# AWS Budget for cost alerts
# Only created if TF_VAR_budget_alert_email and TF_VAR_budget_limit env vars are set

locals {
  budget_enabled = var.budget_alert_email != null && var.budget_limit != null
}

resource "aws_budgets_budget" "benchmark" {
  count = local.budget_enabled ? 1 : 0

  name              = "ruby-bench-monthly"
  budget_type       = "COST"
  limit_amount      = var.budget_limit
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2024-01-01_00:00"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Name$ruby-bench-*"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }

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
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
