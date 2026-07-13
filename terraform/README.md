# terraform/ — provision the lab host on AWS

Stands up everything the node needs on EC2, with sensible security defaults baked in.

> **Scope.** This is a single-file, self-contained module whose only job is to spin the lab
> host up fast. It is **not** a reference for structuring a real Terraform codebase (modules,
> environments, remote state, CI). For a cleaner, more standard layout, see
> [`dungpham91/devops.demo.terraform`](https://github.com/dungpham91/devops.demo.terraform).
>
> Findings from `checkov` are addressed: real issues are fixed in the code; a few accepted
> lab tradeoffs are suppressed inline with a documented reason (and in `../.checkov.yaml`).
> `checkov -d terraform` → 0 failed.

## What it creates

- **VPC** + public subnet + internet gateway + route table
- **EC2 instance** (`r6i.2xlarge` by default — 8 vCPU / 64 GiB, x86_64) running Ubuntu 24.04
- **gp3 root volume** (640 GB, provisioned IOPS/throughput), **encrypted** with a customer KMS key
- **KMS CMK** (rotation on) used for both secrets and the EBS volume
- **Secrets Manager**: a generated Postgres password (and, optionally, your Slack webhook)
- **IAM instance role**: SSM access + least-privilege read of *only* those secrets and `kms:Decrypt`
- **Security group**: P2P inbound only; RPC/metrics/Grafana stay closed
- **user_data**: installs prerequisites and drops `/usr/local/bin/fetch-node-secrets.sh`

## Usage

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit region/owner/etc.
terraform init
terraform plan
terraform apply

# Open a shell WITHOUT SSH (uses the SSM output):
eval "$(terraform output -raw ssm_start_session)"
# then continue with ../RUNBOOK.md (run `sudo /usr/local/bin/fetch-node-secrets.sh`
# again after installing PostgreSQL to create the role/db from the managed password).
```

## Credentials & access (step by step)

### 1. Give Terraform AWS credentials

Terraform reads standard AWS credentials from the environment. Pick **one**:

**a) Environment variables** (quick; use a short-lived key or STS session):
```bash
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."          # only if using temporary/STS credentials
export AWS_DEFAULT_REGION="ap-southeast-1"
aws sts get-caller-identity             # verify who you are
```

**b) A named profile** (recommended — nothing secret in your shell history):
```bash
aws configure --profile midnight        # paste key/secret/region once
export AWS_PROFILE=midnight
```

**c) AWS IAM Identity Center (SSO)** — best if your org uses it:
```bash
aws configure sso --profile midnight
aws sso login --profile midnight
export AWS_PROFILE=midnight
```

The principal you use needs permission to create the resources here: EC2 + VPC, EBS,
Security Groups, **IAM** (role/policy/instance-profile), **KMS** (create key + grants),
and **Secrets Manager**. For a lab, an admin/PowerUser+IAM principal is simplest; for least
privilege, scope a policy to those services. Terraform never stores your credentials — it
uses them only during `plan`/`apply`.

### 2. Install the Session Manager plugin (for shell/tunnels without SSH)
```bash
# macOS
brew install --cask session-manager-plugin
# Debian/Ubuntu
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/smp.deb && sudo dpkg -i /tmp/smp.deb
# verify
session-manager-plugin --version
```

### 3. Open a shell on the box

**SSM Session Manager (default, no SSH port):**
```bash
eval "$(terraform output -raw ssm_start_session)"   # = aws ssm start-session --target <id> --region <region>
# you land as ssm-user; become the service account:
sudo -iu midnight
```

**SSH over SSM** (only if you set `ssh_enabled = true` and provided a key — still no public
port 22, SSH is tunnelled through SSM). Add to `~/.ssh/config`:
```sshconfig
Host midnight-node
  HostName <instance-id>          # e.g. i-0abc123...
  User ubuntu
  ProxyCommand sh -c "aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p --region ap-southeast-1"
```
then `ssh midnight-node`.

### 4. Reach Grafana / Alertmanager / Prometheus / RPC (private) via SSM port-forwarding

These ports are **not** exposed to the internet. Forward them to your laptop on demand:
```bash
ID=$(terraform output -raw instance_id); REGION=$(terraform output -raw region 2>/dev/null || echo ap-southeast-1)

# Grafana  → http://localhost:3000
aws ssm start-session --target "$ID" --region "$REGION" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'

# Alertmanager → http://localhost:9093   (change portNumber to 9090 for Prometheus, 9933 for RPC)
aws ssm start-session --target "$ID" --region "$REGION" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["9093"],"localPortNumber":["9093"]}'
```
Leave the session open and browse `http://localhost:<port>`; Ctrl-C closes the tunnel.

**Prerequisites summary:** an AWS account + credentials (above), Terraform ≥ 1.5, the AWS CLI
v2, and the Session Manager plugin.

## Security posture (why it's built this way)

| Control | How |
|---|---|
| No hard-coded secrets | Postgres password is generated (`random_password`) and stored in Secrets Manager; never in code, and not exposed as an output |
| Encryption at rest | Customer-managed KMS key (rotation enabled) encrypts secrets **and** the EBS root volume |
| Least-privilege IAM | Instance role can read only the two specific secret ARNs and `kms:Decrypt` one key — nothing else |
| No SSH by default | Admin access via SSM Session Manager; port 22 stays closed unless you opt in with a restricted CIDR |
| Minimal attack surface | Security group opens only P2P (3001/6000); RPC 9933, Prometheus 9615, Grafana 3000 are never exposed — reach them by SSM port-forwarding |
| SSRF hardening | IMDSv2 required (`http_tokens = required`), hop limit 1 |

(Reaching the private ports — Grafana/Alertmanager/Prometheus/RPC — is covered under
*Credentials & access ▸ step 4* above.)

> **State contains the generated password.** Terraform state stores `random_password` in
> plaintext. Do not commit it (it is git-ignored) — and for anything beyond a lab, use the
> encrypted S3 backend stubbed in `versions.tf`.

## Small test box (validate the setup script cheaply first)

Before paying for the full node, stand up a tiny box (`t3.micro`, 20 GB) to exercise
`scripts/setup_node.sh` — its logging, arg parsing, and `--dry-run` flow.

> **Use a separate Terraform workspace.** This directory has a single state, so the test box
> and the real host must not share it — otherwise applying one reconfigures the other. A
> workspace gives the test box its own isolated state (`environment = "test"` also keeps the
> AWS resource names distinct).

```bash
cp test.tfvars.example test.tfvars          # test.tfvars is git-ignored
terraform workspace new test                # isolated state for the test box
terraform apply -var-file=test.tfvars
eval "$(terraform output -raw ssm_start_session)"
# on the box:  sudo -iu midnight  &&  <repo>/scripts/setup_node.sh --dry-run
terraform destroy -var-file=test.tfvars
terraform workspace select default          # switch back before touching the real host
```

1 GiB RAM only exercises the script — it cannot run a real DB Sync. It costs a few cents/hour.

## Cost & teardown

Rough cost is in the root [`README.md`](../README.md#reference-environment--rough-cost)
(≈ $25–28 for a full run in Singapore). When done:

```bash
terraform destroy                                   # real host (default workspace)
# test box (from its workspace):
terraform workspace select test && terraform destroy -var-file=test.tfvars
terraform workspace select default
```
