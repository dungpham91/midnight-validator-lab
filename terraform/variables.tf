variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-southeast-1" # Singapore
}

variable "project" {
  description = "Project name, used as a naming prefix"
  type        = string
  default     = "midnight-validator-lab"
}

variable "environment" {
  description = "Environment name (matches the Midnight network target)"
  type        = string
  default     = "preprod"
}

variable "owner" {
  description = "Owner tag (email or team) applied to all resources"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Extra tags merged into every resource"
  type        = map(string)
  default     = {}
}

# ── Compute ───────────────────────────────────────────────────────────────────────────
variable "instance_type" {
  description = "EC2 instance type. r6i.2xlarge = 8 vCPU / 64 GiB (minimum cores + comfort RAM). Use x86_64 — this lab pins linux-amd64 artifacts (cardano-db-sync is amd64-only)."
  type        = string
  default     = "r6i.2xlarge"
}

variable "ami_id" {
  description = "Override the Ubuntu 24.04 AMI. Empty = look up the latest Canonical image."
  type        = string
  default     = ""
}

variable "ebs_optimized" {
  description = "Enable EBS optimization. Supported by r6i/t3; set false for t2.* (unsupported)."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs to an encrypted CloudWatch log group (network audit trail)"
  type        = bool
  default     = true
}

# ── Storage (gp3) ─────────────────────────────────────────────────────────────────────
variable "root_volume_size_gb" {
  description = "Root gp3 volume size in GB (>=500 for pre-prod)"
  type        = number
  default     = 640
}

variable "root_volume_iops" {
  description = "Provisioned gp3 IOPS (3000 free baseline; up to 16000 per volume)"
  type        = number
  default     = 10000
}

variable "root_volume_throughput" {
  description = "Provisioned gp3 throughput in MB/s (125 free baseline; up to 1000)"
  type        = number
  default     = 250
}

# ── Networking ────────────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.20.1.0/24"
}

variable "allow_p2p_inbound" {
  description = "Open inbound Cardano (3001) and Midnight (6000) P2P ports for better peering"
  type        = bool
  default     = true
}

# ── Access (SSM by default; SSH optional) ─────────────────────────────────────────────
variable "ssh_enabled" {
  description = "Open inbound SSH (22). Default false — access via SSM Session Manager instead."
  type        = bool
  default     = false
}

variable "ssh_allowed_cidr" {
  description = "CIDR allowed to reach SSH when ssh_enabled = true. Never use 0.0.0.0/0."
  type        = string
  default     = ""
}

variable "ssh_public_key" {
  description = "Public key material for the SSH key pair (required when ssh_enabled = true)"
  type        = string
  default     = ""
}

# ── Secrets ───────────────────────────────────────────────────────────────────────────
variable "slack_webhook_url" {
  description = "Optional Slack webhook. If set, it is stored in Secrets Manager (never in plaintext state output)."
  type        = string
  default     = ""
  sensitive   = true
}
