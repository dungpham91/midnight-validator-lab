data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-igw" }
}

resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[0]
  # Do not auto-assign public IPs at the subnet level; the node opts in explicitly via
  # associate_public_ip_address (CKV_AWS_130).
  map_public_ip_on_launch = false

  tags = { Name = "${local.name_prefix}-snet-public-a" }
}

# Lock down the VPC's default security group (deny all in/out) — CKV2_AWS_12.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-sg-default-locked" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name_prefix}-rt-public" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

# ── VPC flow logs → encrypted CloudWatch log group (CKV2_AWS_11) ───────────────────────
resource "aws_cloudwatch_log_group" "flow" {
  count             = var.enable_flow_logs ? 1 : 0
  name              = "/${local.name_prefix}/vpc-flow-logs"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.main.arn

  tags = { Name = "${local.name_prefix}-cwl-vpc-flow" }
}

data "aws_iam_policy_document" "flow_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow" {
  count              = var.enable_flow_logs ? 1 : 0
  name               = "${local.name_prefix}-role-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_assume.json

  tags = { Name = "${local.name_prefix}-role-flow-logs" }
}

data "aws_iam_policy_document" "flow_write" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = var.enable_flow_logs ? ["${aws_cloudwatch_log_group.flow[0].arn}:*"] : ["*"]
  }
}

resource "aws_iam_role_policy" "flow" {
  count  = var.enable_flow_logs ? 1 : 0
  name   = "${local.name_prefix}-policy-flow-logs"
  role   = aws_iam_role.flow[0].id
  policy = data.aws_iam_policy_document.flow_write.json
}

resource "aws_flow_log" "main" {
  count                = var.enable_flow_logs ? 1 : 0
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow[0].arn
  iam_role_arn         = aws_iam_role.flow[0].arn

  tags = { Name = "${local.name_prefix}-flow-log" }
}
