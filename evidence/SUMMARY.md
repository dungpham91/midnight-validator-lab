# Evidence summary

A quick map of every captured file to what it demonstrates, from a full end-to-end pre-prod run on
AWS (Singapore) on 2026-07-13/14. Screenshots are `.jpg`; text captures are `.txt`. Secrets are
redacted in the images.

> **Read the honest note first (bottom of this file):** why *Peer count = 1*, *Best block = 0*, and
> the health check reporting *DEGRADED* are the **expected** state for this lab, not faults.

---

## Infrastructure (Terraform / IaC)

| File | What it shows |
|---|---|
| `terraform-apply.jpg` | `terraform apply` → **26 resources created** (VPC, EC2 `r6i.2xlarge`, KMS CMK, Secrets Manager, IAM, SG, flow logs) + outputs. Secrets redacted. |

## Node onboarding & automation

| File | What it shows |
|---|---|
| `run-setup-node-script.jpg` | `setup_node.sh --stage prereqs,secrets,mithril,cardano,postgres,dbsync` — prereqs, Postgres password pulled from Secrets Manager, Mithril snapshot download. |
| `cardano-db-sync-start.jpg` | cardano-db-sync installed + its systemd service created. |
| `finish-setup-node-script-phase-A.jpg` | Cardano/DB-Sync phase completes. |
| `cardano-db-sync-check.jpg` | db-sync inserting Cardano blocks into `cexplorer`; also captures the `ObsoleteNode` moment that led to the PV11 upgrade (see root README Troubleshooting #5). |
| `generate-keys.jpg` | Validator session keys generated + `partner-chains-public-keys.json` (registration file). **Public keys only should be visible — verify secrets are redacted before committing.** |
| `finish-setup-node-script-phase-B1.jpg` | `--stage midnight,keys,env,service,verify` — midnight-node downloaded + `res/` extracted. |
| `finish-setup-node-script-phase-B2.jpg` | keys generated (node **PeerID** shown), `.env` written, validator service installed, verify stage. |

## Sync state, block progression & node health

| File | What it shows |
|---|---|
| `check-status.jpg` | Final capture — **Cardano `block_no` climbing 4933777 → 4933789** (the demonstrable height increase), `verify-sync` = `syncProgress 100.00%`, keystore files present, `system_health` / `system_peers`, health checker output. |

## Monitoring & alerting

| File | What it shows |
|---|---|
| `setup-monitoring.jpg` | `docker compose up` — prometheus / alertmanager / grafana / node-exporter all **Up**. |
| `expose-grafana.jpg` | SSM port-forwarding (3000) — reaching a private port with no public exposure. |
| `grafana-dashboard.jpg` | Dashboard: best/finalized block, peer count, node-up, host CPU/mem/disk. |
| `prometheus-status-target.jpg` | Scrape targets **UP**: `midnight-node:9615`, `node-exporter:9100`, `prometheus`. |
| `prometheus-status-alerts.jpg` | **10 alert rules** across 3 groups (host-resources / midnight-core / midnight-supporting); 3 firing. |
| `alertmanager-status.jpg` | Routing by severity: `slack-critical` ← BlockProgressionStalled; `slack-warnings` ← FinalityStalled + LowPeerCount. |
| `slack-midnight-critical.jpg` | **#midnight-critical** received the `critical` alert (with summary + detail + runbook link). |
| `slack-midnight-alerts.jpg` | **#midnight-alerts** received the two `warning` alerts. |

→ Together these prove the full pipeline **Prometheus → Alertmanager → Slack**, with **two channels
routed by severity**, working end to end.

---

## Expected observations (honest read)

These three are the **correct** state for an unauthorised lab FNO, not defects — the detective trail
is in the root [`README.md`](../README.md) Troubleshooting #9:

- **Peer count = 1.** Of the two official pre-prod bootnodes, only one (`bootnode-2`) was reachable
  on TCP/30333; `bootnode-1`'s endpoint was down from our side. The pre-prod P2P set is small.
- **Best block = 0.** The reachable bootnode itself reports `bestNumber: 0`, and our node's genesis
  hash matches it — so there is **no block above genesis to import**. The node is synced to what the
  network exposes, not stuck. A fresh FNO advancing its own Midnight height requires committee
  authorisation + the n+2 epoch, which is out of a lab window — and this node is deliberately **not**
  registered with the Foundation (it is torn down afterwards). The demonstrable block-height
  increase is therefore on the **Cardano** layer (`check-status.jpg`).
- **Health checker = DEGRADED.** It honestly fails `peer_count` (1 < 3) and `has_block_height` (0)
  while passing `rpc_reachable` and `sync_gap` — i.e. the tool correctly detects the conditions
  above rather than green-washing.
