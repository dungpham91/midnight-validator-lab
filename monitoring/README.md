# Monitoring — Midnight Pre-Prod FNO

Prometheus + Alertmanager + Grafana + node_exporter. The Midnight node is Substrate-based,
so it exposes rich metrics on `:9615` (`substrate_*`); host metrics come from node_exporter;
alerts route to Slack.

## Layout

```
monitoring/
├── docker-compose.yml                     # one-command stack
├── prometheus/
│   ├── prometheus.yml                     # scrape jobs
│   └── alert.rules.yml                    # alert definitions
├── alertmanager/
│   ├── alertmanager.yml                   # routing → Slack (severity-based channels)
│   └── secrets/{slack_alerts,slack_critical}.example  # one webhook per channel (git-ignored reals)
└── grafana/
    ├── provisioning/                      # auto-wire datasource + dashboard
    └── dashboards/midnight-node.json      # block height, peers, host resources
```

---

# Step-by-step setup, verification & testing

## Prerequisites

- Docker Engine + Docker Compose plugin on the host that will run monitoring.
  ```bash
  sudo apt update && sudo apt install -y docker.io docker-compose-v2
  sudo usermod -aG docker $USER && newgrp docker   # run docker without sudo
  ```
- Run this stack **on the node host** so node_exporter reads the real host and Prometheus can
  reach the node's `:9615`/`:9933` over `host.docker.internal`. (It can also run on a separate
  box — then set the node's real IP in `prometheus/prometheus.yml` targets.)

## Step 1 — Expose metrics on the Midnight node

Substrate only serves Prometheus metrics when asked. Add these flags to the launch command
**and** the systemd `ExecStart` (see `RUNBOOK.md` §5.2 / §5.3):

```bash
midnight-node ... --rpc-port 9933 --prometheus-external --prometheus-port 9615
```

Confirm metrics are being served:
```bash
curl -s http://localhost:9615/metrics | grep -E 'substrate_block_height|substrate_sub_libp2p_peers_count' | head
```
You should see lines like `substrate_block_height{status="best"} 12345`.

## Step 2 — Create two channels + two Incoming Webhooks

### Why two channels?

Alerts are split by **urgency**, not lumped into one stream, so that a "node is down" page is
never buried under low-priority noise:

| | `#midnight-critical` | `#midnight-alerts` |
|---|---|---|
| Meaning | act **now** | review soon, less urgent |
| Examples | node down, no peers, block height stalled | disk filling, finality lag, service restarted |
| Routing (see `alertmanager.yml`) | `group_wait 10s`, `repeat 1h` | `group_wait 30s`, `repeat 4h` |
| Intended audience | the channel on-call watches closely / pages from | a quieter channel you skim |

This is a deliberate **signal-over-noise** design: you get woken up only for things that
warrant it, and warnings still land somewhere visible without drowning the critical stream.
A single channel would also work for a solo lab — the trade-off is you lose that separation.

### The webhooks

A Slack Incoming Webhook is **bound to the one channel** it was created for (app-based webhooks
can't override the channel in the payload). Two channels therefore need **two webhooks**.

1. Create two channels: **`#midnight-alerts`** (warnings) and **`#midnight-critical`** (critical).
2. Create an app once: **https://api.slack.com/apps** ▸ **Create New App** ▸ *From scratch* ▸
   pick your workspace ▸ open **Incoming Webhooks** ▸ toggle it **On**.
3. **Add New Webhook to Workspace** twice — once selecting `#midnight-alerts`, once selecting
   `#midnight-critical`. Copy both URLs. (Keep them straight — that mapping is the whole point.)

## Step 3 — Wire the two webhooks (Secrets Manager as source of truth)

**Source of truth = AWS Secrets Manager** (CMK-encrypted, IAM-scoped, audited, rotatable). The
Terraform stack stores both webhooks in **one** secret as JSON: `{"alerts": "...", "critical": "..."}`
(set `slack_webhook_alerts` / `slack_webhook_critical`). Alertmanager and the dependency-free
`node_health_check.py` can't call Secrets Manager directly, so materialise the webhooks to local
`0600` files (ideally on `tmpfs`) — caches, never a second source; git-ignored.

**Alertmanager** reads a **separate file per channel** (`api_url_file`), so each receiver posts to
the right place:

| Receiver | File (`secrets/`) | Channel |
|---|---|---|
| `slack-warnings` | `slack_alerts` | `#midnight-alerts` |
| `slack-critical` | `slack_critical` | `#midnight-critical` |

**On the Terraform-provisioned box** — split the one JSON secret into the two files:
```bash
S=$(aws secretsmanager get-secret-value --region ap-southeast-1 \
      --secret-id midnight-validator-lab-preprod/slack-webhooks \
      --query SecretString --output text)
jq -rn --argjson s "$S" '$s.alerts'   | sudo install -m600 /dev/stdin monitoring/alertmanager/secrets/slack_alerts
jq -rn --argjson s "$S" '$s.critical' | sudo install -m600 /dev/stdin monitoring/alertmanager/secrets/slack_critical
```

**Standalone (no Secrets Manager):** copy each example and paste the matching webhook:
```bash
cd monitoring/alertmanager/secrets
cp slack_alerts.example slack_alerts       # paste the #midnight-alerts webhook
cp slack_critical.example slack_critical   # paste the #midnight-critical webhook
```

**The health checker** (`node_health_check.py`) posts to a single channel — point it at the
**critical** webhook via `--slack-webhook-file /etc/midnight/slack_webhook`. On the Terraform box,
`setup_node.sh --slack-secret …/slack-webhooks` (and the user_data helper) writes that file from
the secret's `.critical` field automatically. Only the `*.example` files are committed.

> **Ranking (most → least secure):** Secrets Manager (KMS-encrypted, IAM, audit, rotation) →
> `tmpfs` 0600 file materialised at runtime → on-disk 0600 file → env var → in config/argv
> (never). This repo uses the first two.

## Step 4 — Start the stack

```bash
cd monitoring
docker compose up -d
docker compose ps          # all containers should be "running"/"healthy"
```
- Grafana → http://localhost:3000 (`admin` / `admin`, change on first login)
- Prometheus → http://localhost:9090
- Alertmanager → http://localhost:9093

> **On a remote EC2 host** these ports are not exposed publicly (by design). Reach them from
> your laptop with an SSM port-forward, then browse `http://localhost:<port>`:
> ```bash
> aws ssm start-session --target <instance-id> --region ap-southeast-1 \
>   --document-name AWS-StartPortForwardingSession \
>   --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
> ```
> (See `terraform/README.md` ▸ Credentials & access ▸ step 4.)

## Step 5 — Verify scrape targets are UP

Prometheus UI ▸ **Status ▸ Targets** — `midnight-node`, `node-exporter`, and `prometheus`
should be **UP**. Or from the CLI:
```bash
curl -s 'http://localhost:9090/api/v1/targets' | jq '.data.activeTargets[] | {job:.labels.job, health}'
```
> If `midnight-node` is DOWN: confirm Step 1 (`--prometheus-external`), that `:9615` is
> reachable, and that `host.docker.internal` resolves (compose already maps it via
> `host-gateway`).

## Step 6 — Check the data

**In Prometheus** (Graph tab), try these queries:
```promql
substrate_block_height{status="best"}          # best block, should climb
substrate_block_height{status="finalized"}     # finalized block
substrate_sub_libp2p_peers_count               # peer count
up{job="midnight-node"}                         # 1 = scraping OK
100 - (avg by (instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)   # CPU %
```
**In Grafana**: open dashboard **Midnight ▸ "Midnight FNO — Pre-Prod Node"** (auto-provisioned).
Panels for best/finalized block, peers, node-up, and host CPU/mem/disk should populate within
~30s.

## Step 7 — Confirm alert rules loaded

Prometheus UI ▸ **Alerts** (or `http://localhost:9090/rules`) lists the rules from
`alert.rules.yml`; each shows `inactive` / `pending` / `firing`. Alertmanager UI
(`:9093`) shows currently firing alerts and silences.

## Step 8 — Test that alerts fire and reach Slack

**Method A — synthetic alert straight into Alertmanager (fastest, tests Slack wiring):**
```bash
curl -s -XPOST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[{
  "labels":{"alertname":"SlackTest","severity":"critical","instance":"midnight-preprod-01"},
  "annotations":{"summary":"Slack wiring test","description":"If you see this in Slack, routing works."}
}]'
```
Within ~10s a message should appear in `#midnight-critical`. (It auto-resolves after
`resolve_timeout`.)

**Method B — trigger a real rule (end-to-end):** stop the node and wait for the `for:` window.
```bash
sudo systemctl stop midnight-node
# after ~2m: MidnightNodeDown flips pending → firing → Slack
sudo systemctl start midnight-node     # recovery sends a resolved notification
```

**Method C — validate rules/routing offline (no Slack needed):**
```bash
# Lint the alert rules
docker run --rm -v "$PWD/prometheus:/p" prom/prometheus:v3.13.1 promtool check rules /p/alert.rules.yml
# Explain where a given alert would route
docker run --rm -v "$PWD/alertmanager:/a" prom/alertmanager:v0.33.1 \
  amtool config routes test --config.file=/a/alertmanager.yml severity=critical
```

## Step 9 — Node health checker (complements the stack)

Independent of Prometheus, `../scripts/node_health_check.py` polls the node's RPC and writes
structured reports with regression diffing (details in `../scripts/README.md`):
```bash
../scripts/node_health_check.py --once                  # one snapshot, exit 0/1/2
../scripts/node_health_check.py --interval 60           # continuous
```
Optionally run it on a timer (unit files in `../scripts/README.md`).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `midnight-node` target DOWN | node not started with `--prometheus-external`; `:9615` blocked |
| Grafana panels empty | datasource not linked → check *Connections ▸ Data sources*; targets UP? |
| No Slack message | `secrets/slack_alerts` or `secrets/slack_critical` missing/empty/wrong; `docker compose restart alertmanager`; check `docker logs alertmanager` |
| Alerts never fire | rule `for:` window not elapsed; verify metric names exist in Prometheus |

---

# Alert design — why these, and the operational response

A validator has one job: stay **up**, stay **connected**, and keep **advancing blocks**. The
three core alerts each guard one of those, chosen for signal-over-noise — every one is
actionable and has a `for:` window so a single bad scrape never pages.

### 1. `MidnightNodeDown`
- **Signal:** `up{job="midnight-node"} == 0` for 2m → process crashed / restarted / port
  unreachable.
- **Severity:** critical (pages `#midnight-critical`).
- **Response:** `systemctl status midnight-node`, `journalctl -u midnight-node -n 200`.
  Check OOM (`dmesg | grep -i oom`), disk-full, or a bad restart. Restart; if it crash-loops,
  roll back the last change and preserve logs.

### 2. `MidnightBlockProgressionStalled`
- **Signal:** best block height (`substrate_block_height{status="best"}`) unchanged for 10m —
  *the* validator health metric; a node can be "up" yet frozen.
- **Severity:** critical.
- **Response:** confirm peers (see #3) **and** that cardano-db-sync/Postgres are healthy —
  Midnight stalls if its Cardano data source stalls. Check `journalctl` for DB errors; verify
  `cexplorer` is progressing. Escalate to the Foundation if the network tip has also stopped.

### 3. `MidnightLowPeerCount`
- **Signal:** `substrate_sub_libp2p_peers_count < 3` for 10m (warning); the companion
  `MidnightNoPeers` fires at `== 0` for 5m (critical). Isolation is the leading indicator of a
  coming stall.
- **Response:** verify **P2P port 6000**, outbound connectivity/DNS, boot-node reachability.
  Zero peers usually means a network/firewall change, not a node bug.

### Supporting alerts
- **`MidnightFinalityStalled`** — best advances but finalized doesn't → GRANDPA/lag issue.
- **`MidnightNodeRecentlyRestarted`** — start-time changed → catches crash loops.
- **`HostHighCpu` / `HostHighMemory` / `HostDiskFillingUp` / `HostDiskWillFillIn24h`** —
  resource pressure that *causes* the failures above. Disk is the classic killer: Cardano DB
  + Postgres grow forever, so the predictive alert buys lead time to resize before db-sync halts.

### Deliberately **not** alerting on
- **"No blocks produced yet."** A newly-onboarded FNO is passive until the Foundation
  authorises its keys and the **n+2 epoch** rule elapses (`RUNBOOK.md` §5.4.2). Alerting on
  zero authored blocks during onboarding would be pure noise. Once in the active set, add a
  per-slot "missed block" alert.
