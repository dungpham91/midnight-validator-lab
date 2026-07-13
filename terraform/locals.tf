locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
  })

  slack_enabled = var.slack_webhook_url != ""
}
