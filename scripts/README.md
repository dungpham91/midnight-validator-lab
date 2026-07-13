# scripts/

- **`setup_node.sh`** — automates the RUNBOOK to bring up the node stack (Cardano → Postgres
  → db-sync → Midnight), with structured logging and a dry-run mode.
- **`node_health_check.py`** — polls the node's JSON-RPC, writes structured reports, and
  diffs against the previous one to surface regressions.

---

# setup_node.sh — automated runbook

Runs the [`RUNBOOK.md`](../RUNBOOK.md) stages as re-runnable functions. Same qualities as the
Python tool: `timestamp level message` logging, colour on a TTY (auto-off when piped /
`NO_COLOR` / `--no-color`), strict mode (`set -euo pipefail`) with `ERR`/`EXIT` traps, arg
parsing, and a **`--dry-run`** that logs every action without touching the host.

**Secrets are never hard-coded:** the Postgres password is pulled from AWS Secrets Manager
(`--db-secret`, matching the Terraform stack), from a file (`--db-password-file`), or generated.

Run as root on Ubuntu 24.04. Stages (in order): `prereqs secrets mithril cardano postgres
dbsync verify-sync midnight keys env service verify`.

### How a real run is phased (DB Sync takes hours)

`cardano-db-sync` needs hours before the validator can start, so a real run is **two phases**.
`--dry-run` is a separate, optional preview that **executes nothing** — every action becomes a
`[dry-run] …` log line, so it needs no DB, no sync, no AWS; use it to inspect the plan
(e.g. on the cheap t3.micro test box) before doing anything for real.

```bash
# 0. (optional) Preview only — runs nothing, safe anytime, no sync required
sudo ./setup_node.sh --dry-run

# PHASE A — bring up Cardano + start DB Sync, then leave it to sync (hours)
sudo ./setup_node.sh --stage prereqs,secrets,mithril,cardano,postgres,dbsync \
     --db-secret midnight-validator-lab-preprod/postgres

# ...wait until db-sync is ~99% (check: sudo -u midnight psql -d cexplorer -c "…" — see RUNBOOK §2.5)

# PHASE B — install node + keys + .env, then start the validator once sync is ready
sudo ./setup_node.sh --stage midnight,keys,env,service --wait-sync \
     --db-secret midnight-validator-lab-preprod/postgres --node-name my-fno
```

Notes:
- `midnight`, `keys`, `env` don't need sync — only **starting the validator** (`service`) does.
- `--wait-sync` makes `service` **block until db-sync ≥ 99%** before starting. Without it, if sync
  isn't ready the script writes the systemd unit but does **not** start the node, and tells you to
  re-run `--stage service --wait-sync` later.
- Running `--stage all` in one shot also works: it reaches `service`, which then waits (with
  `--wait-sync`) or defers the start — it won't launch the validator against an unsynced DB.

| Flag | Meaning |
|---|---|
| `--stage LIST` | Comma-separated stages, or `all` (default) |
| `--db-secret NAME` | Secrets Manager id with `{"password": ...}` (preferred) |
| `--db-password-file F` | Read the password from a file instead |
| `--region`, `--user`, `--network`, `--node-name` | Overrides (defaults: ap-southeast-1 / midnight / preprod / hostname) |
| `--wait-sync`, `--min-sync-percent N` | Block until db-sync ≥ N% before starting the validator (default 99) |
| `--dry-run`, `-v/--verbose`, `--no-color` | Log-only run / DEBUG / no colour |

> Idempotent where practical (checks for existing user/role/db before creating). If a stage
> fails, the `ERR` trap logs the line; fix and re-run just that `--stage`.

---

# node_health_check.py — health checker

`node_health_check.py` polls a Midnight (Substrate) node's JSON-RPC endpoint, evaluates
health conditions, writes a structured JSON report, and **diffs against the previous
report to surface regressions**.

## Why a health checker

With a node (see `RUNBOOK.md`) and a metrics stack (`monitoring/`) already in place, a small
checker that reasons over the node's own RPC is the piece you actually cron on the box and
wire into alerting. It answers "is this node healthy right now, and did anything get worse
since last time?" without needing the full Prometheus stack.

## Design highlights

- **Standard library only** — no `pip install` on a fresh node; just Python 3.10+.
- **Idempotent / re-runnable** — always rewrites `latest.json` and appends a timestamped
  copy under `history/`. Safe from cron or a systemd timer.
- **Regression diffing** — compares the new snapshot to `latest.json` and flags: status
  worsening, a previously-passing check now failing, block height stalled or going
  backwards, and peer-count drops.
- **Actionable exit codes** — `0` healthy · `1` degraded/regressed · `2` unreachable — so
  it plugs straight into monitoring or a CI gate.
- **Error handling** — RPC transport errors, timeouts, malformed JSON, and hex/int block
  encodings are all handled; a single failed sub-query degrades gracefully instead of
  crashing.

## Usage

```bash
# One-shot against the local node (RPC port 9933 per RUNBOOK §5)
./node_health_check.py --once

# Custom thresholds / endpoint / output dir
./node_health_check.py --rpc-url http://localhost:9933 \
    --min-peers 3 --max-sync-gap 5 --report-dir ./health-reports

# Continuous polling every 60s (Ctrl-C to stop)
./node_health_check.py --interval 60

# Daemon mode with Slack alerts (webhook read from a file, kept out of argv/history)
./node_health_check.py --interval 60 --slack-webhook-file /etc/midnight/slack_webhook
# ...or from the environment
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/... ./node_health_check.py --interval 60
```

| Flag | Default | Meaning |
|---|---|---|
| `--rpc-url` | `http://localhost:9933` | Substrate JSON-RPC endpoint |
| `--report-dir` | `./health-reports` | Where `latest.json` + `history/` are written |
| `--min-peers` | `3` | Fail `peer_count` below this |
| `--max-sync-gap` | `5` | Fail `sync_gap` (tip − current) above this |
| `--timeout` | `10` | Per-RPC timeout (seconds) |
| `--interval` | `0` | Poll every N seconds (`0` = run once) |
| `--once` | — | Force a single run even if `--interval` is set |
| `--slack-webhook-url` | — | Slack incoming webhook URL |
| `--slack-webhook-file` | — | File holding the webhook (preferred; keeps it out of argv/history) |
| `--slack-notify-healthy` | — | Also post on healthy runs (heartbeat); default posts only on problems/changes |
| `-v`, `--verbose` | — | Also log passing checks (DEBUG level) |
| `--no-color` | — | Disable coloured output (also honours the `NO_COLOR` env var) |

### Slack alerting

Provide a webhook via `--slack-webhook-file`, `--slack-webhook-url`, or the
`SLACK_WEBHOOK_URL` environment variable (resolved in that order). To keep the secret out of
`argv`/shell history, prefer the file:

```bash
sudo install -d -m 700 /etc/midnight
printf '%s' 'https://hooks.slack.com/services/...' | sudo tee /etc/midnight/slack_webhook >/dev/null
sudo chmod 600 /etc/midnight/slack_webhook
```

To avoid a polling daemon spamming Slack, a message is sent **only** on a fresh regression or
a status transition (including recovery). A steady `HEALTHY` or steady `DEGRADED` state does
not re-notify. Use `--slack-notify-healthy` if you want a message on every run (heartbeat). A
failed Slack post is logged to stderr and never aborts the health check.

## Logging output

Output goes through Python's `logging` with a `timestamp level message` format and is
coloured by level on a terminal:

```
2026-07-13 12:00:01 INFO  HEALTHY http://localhost:9933 peers=9 best=500 tip=500 gap=0 syncing=False
2026-07-13 12:00:37 WARN  check FAIL peer_count: 2 peers (min 3)
2026-07-13 12:00:37 WARN  regression: peer count dropped: 9 -> 2
2026-07-13 12:01:10 ERROR UNREACHABLE http://localhost:9933 (unreachable)
```

- Overall status is logged at **INFO** (healthy) / **WARN** (degraded) / **ERROR** (unreachable);
  failing checks and regressions at WARN; passing checks at DEBUG (`--verbose` to show them).
- Colour is **auto-disabled** when stdout is not a TTY (piped/redirected), or when `--no-color`
  / `NO_COLOR` is set — so `... | tee report.txt` and journald stay clean (no ANSI escapes).
- Logs go to **stdout**, so `journalctl -u node-health` captures them under systemd.

## Health conditions evaluated

`rpc_reachable`, `peer_count ≥ min`, `network_connected` (has peers when it should),
`sync_gap ≤ max`, `has_block_height`. Metrics come from `system_health`,
`system_syncState`, `system_version`, `system_chain`.

## Report shape

```json
{
  "timestamp": "2026-07-13T...Z",
  "target": "http://localhost:9933",
  "reachable": true,
  "status": "HEALTHY | DEGRADED | UNREACHABLE",
  "node": { "version": "0.22.2", "chain": "midnight-preprod" },
  "metrics": { "peers": 8, "current_block": 1000, "highest_block": 1001, "sync_gap": 1, "is_syncing": false },
  "checks": [ { "name": "peer_count", "ok": true, "detail": "8 peers (min 3)" } ],
  "regressions": [ "peer count dropped: 8 -> 2" ]
}
```

## Run it as a service

**Option 1 — systemd timer** (runs `--once` on a schedule; `latest.json` carries state
between runs so regression/transition detection still works):
```ini
# /etc/systemd/system/node-health.service
[Service]
Type=oneshot
User=midnight
ExecStart=/home/midnight/node_health_check.py --once \
    --report-dir /home/midnight/health-reports \
    --slack-webhook-file /etc/midnight/slack_webhook
```
```ini
# /etc/systemd/system/node-health.timer
[Timer]
OnBootSec=1min
OnUnitActiveSec=60s
Persistent=true
[Install]
WantedBy=timers.target
```

**Option 2 — long-running daemon** (`--interval`), if you prefer one persistent process:
```ini
# /etc/systemd/system/node-health.service
[Service]
User=midnight
ExecStart=/home/midnight/node_health_check.py --interval 60 \
    --report-dir /home/midnight/health-reports \
    --slack-webhook-file /etc/midnight/slack_webhook
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
```

> Verified locally against a mock RPC server: healthy → `exit 0`; stalled block + peer
> drop → all four regressions detected, `exit 1`; node offline → `UNREACHABLE`, `exit 2`.
