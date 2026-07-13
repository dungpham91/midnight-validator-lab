# ── Security group (least privilege) ──────────────────────────────────────────────────
# Inbound: only P2P (optional). RPC 9933, Prometheus 9615, and Grafana 3000 are NEVER
# exposed — reach them via `aws ssm start-session` port-forwarding. Admin access is SSM by
# default (no SSH port); SSH is opt-in and CIDR-restricted.
resource "aws_security_group" "node" {
  name_prefix = "${local.name_prefix}-sg-"
  description = "Midnight validator node - least privilege"
  vpc_id      = aws_vpc.main.id
  #checkov:skip=CKV2_AWS_5:Attached to aws_instance.node via vpc_security_group_ids

  tags = { Name = "${local.name_prefix}-sg-node" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cardano_p2p" {
  count             = var.allow_p2p_inbound ? 1 : 0
  security_group_id = aws_security_group.node.id
  description       = "Cardano P2P"
  ip_protocol       = "tcp"
  from_port         = 3001
  to_port           = 3001
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "midnight_p2p" {
  count             = var.allow_p2p_inbound ? 1 : 0
  security_group_id = aws_security_group.node.id
  description       = "Midnight P2P"
  ip_protocol       = "tcp"
  from_port         = 6000
  to_port           = 6000
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count             = var.ssh_enabled ? 1 : 0
  security_group_id = aws_security_group.node.id
  description       = "SSH (restricted)"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.ssh_allowed_cidr
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.node.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ── KMS CMK (encrypts secrets + the EBS root volume + flow logs) ──────────────────────
data "aws_caller_identity" "current" {}

# Explicit key policy (CKV2_AWS_64): account root administers via IAM; CloudWatch Logs may
# use the key to encrypt the VPC flow-log group.
data "aws_iam_policy_document" "kms" {
  # The root-account admin statement (kms:* on the key) is the AWS-recommended default for
  # every KMS key policy — without it the key can become unmanageable. In a key policy,
  # resource "*" scopes to this key only. These wildcard checks don't model that context.
  #checkov:skip=CKV_AWS_356:KMS key-policy root statement; "*" scopes to this key
  #checkov:skip=CKV_AWS_109:Standard KMS root administration statement
  #checkov:skip=CKV_AWS_111:Standard KMS root administration statement
  statement {
    sid       = "EnableRootAccountAdmin"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowCloudWatchLogs"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "main" {
  description             = "${local.name_prefix} secrets and EBS encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms.json

  tags = { Name = "${local.name_prefix}-kms" }
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name_prefix}"
  target_key_id = aws_kms_key.main.key_id
}

# ── Secrets Manager: Postgres credentials (password generated, never hard-coded) ──────
resource "random_password" "db" {
  length  = 40
  special = true
  # Keep the charset safe for both a libpq URL (userinfo) and .pgpass (':'/'\' are delimiters).
  override_special = "-_=."
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name_prefix}/postgres"
  description             = "Postgres cexplorer credentials for cardano-db-sync"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 0 # lab convenience: allow immediate re-create
  #checkov:skip=CKV2_AWS_57:Automatic rotation needs a rotation Lambda; out of lab scope (rotation covered in SECURITY.md §2)

  tags = { Name = "${local.name_prefix}-secret-postgres" }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = "midnight"
    password = random_password.db.result
    dbname   = "cexplorer"
    host     = "localhost"
    port     = 5432
  })
}

# ── Secrets Manager: optional Slack webhooks (one per channel, stored as one JSON secret) ──
resource "aws_secretsmanager_secret" "slack" {
  count                   = local.slack_enabled ? 1 : 0
  name                    = "${local.name_prefix}/slack-webhooks"
  description             = "Slack incoming webhooks per channel: {alerts, critical}"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 0
  #checkov:skip=CKV2_AWS_57:Automatic rotation needs a rotation Lambda; out of lab scope

  tags = { Name = "${local.name_prefix}-secret-slack" }
}

resource "aws_secretsmanager_secret_version" "slack" {
  count     = local.slack_enabled ? 1 : 0
  secret_id = aws_secretsmanager_secret.slack[0].id
  secret_string = jsonencode({
    alerts   = var.slack_webhook_alerts   # -> #midnight-alerts (warnings)
    critical = var.slack_webhook_critical # -> #midnight-critical
  })
}

# ── IAM: instance role (SSM + least-privilege secret read) ────────────────────────────
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name_prefix}-role-node"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = { Name = "${local.name_prefix}-role-node" }
}

# SSM Session Manager (browser/CLI shell without opening SSH)
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "secrets_access" {
  statement {
    sid     = "ReadNodeSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = concat(
      [aws_secretsmanager_secret.db.arn],
      local.slack_enabled ? [aws_secretsmanager_secret.slack[0].arn] : [],
    )
  }

  statement {
    sid       = "DecryptWithCmk"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "secrets_access" {
  name   = "${local.name_prefix}-policy-secrets"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.secrets_access.json
}

resource "aws_iam_instance_profile" "node" {
  name = "${local.name_prefix}-profile-node"
  role = aws_iam_role.node.name
}
