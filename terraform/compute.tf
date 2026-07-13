data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_key_pair" "node" {
  count      = var.ssh_enabled && var.ssh_public_key != "" ? 1 : 0
  key_name   = "${local.name_prefix}-key"
  public_key = var.ssh_public_key

  tags = { Name = "${local.name_prefix}-key" }
}

resource "aws_instance" "node" {
  ami                    = coalesce(var.ami_id, data.aws_ami.ubuntu.id)
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public_a.id
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name
  key_name               = var.ssh_enabled && var.ssh_public_key != "" ? aws_key_pair.node[0].key_name : null
  monitoring             = true # CloudWatch detailed (1-min) monitoring
  ebs_optimized          = var.ebs_optimized

  # A public IP is required: this single-subnet lab needs outbound internet (apt, GitHub,
  # Mithril) and inbound P2P, with no NAT gateway. Access is still SSM-only and the SG is
  # least-privilege. For a no-public-IP design use a private subnet + NAT (see README).
  #checkov:skip=CKV_AWS_88:Public IP is an accepted tradeoff for this single-subnet lab; access is SSM-only, SG least-privilege
  associate_public_ip_address = true

  # IMDSv2 only — blocks SSRF-based credential theft.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    iops        = var.root_volume_iops
    throughput  = var.root_volume_throughput
    encrypted   = true
    kms_key_id  = aws_kms_key.main.arn

    tags = { Name = "${local.name_prefix}-ebs-root" }
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region            = var.region
    db_secret_name    = aws_secretsmanager_secret.db.name
    slack_secret_name = local.slack_enabled ? aws_secretsmanager_secret.slack[0].name : ""
  })

  tags = { Name = "${local.name_prefix}-ec2-node" }

  # Secret must exist before the instance boots and tries to fetch it.
  depends_on = [
    aws_secretsmanager_secret_version.db,
    aws_iam_role_policy.secrets_access,
  ]
}
