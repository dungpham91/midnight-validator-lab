# evidence/ — proof the node is syncing & healthy

Logs and screenshots from my pre-prod lab run: `cardano-db-sync` progress, the Midnight node
importing blocks, the health checker, and the monitoring/alerting working end to end. Commit
the captured files here.

## Why this takes overnight (and why I run the VM at night)

A Midnight validator reads Cardano main-chain state from a local PostgreSQL DB populated by
`cardano-db-sync`. So the node can't meaningfully validate until **DB Sync is caught up** — and
that is the long pole: several hours even with a Mithril snapshot bootstrap. It's a
kick-off-and-wait job, not something you can speed up by sitting there.

So the sensible pattern is:

- **Start the Cardano/DB-Sync phase in the evening and let it run overnight.** By morning the DB
  is synced and the node is ready to bring up — no active babysitting during the slow part.
- **Running the VM overnight also keeps cost sane.** Cloud compute bills by the hour whether
  you're watching or asleep, so the unavoidable multi-hour sync should overlap your sleep, not
  your working hours. Start it right before bed so it finishes around when you wake up — that
  minimises paid *idle* time (a box that synced at 3am then sits unused until noon is wasted
  money). Capture evidence in the morning, then tear the box down.

> **What "healthy" looks like here (be honest):** a freshly brought-up node shows a **syncing**
> state — `Best:` climbing, peers > 0, Postgres connected. It does **not** author blocks yet:
> block production only starts after the operator's keys are authorised and the n+2 epoch cycle
> elapses (RUNBOOK §5.4.3). Capturing the syncing node + working monitoring is the real proof.
>
> **Lab stops before Foundation submission.** `partner-chains-public-keys.json` is generated but is
> **not** submitted to the Foundation — authorisation can't take effect inside a lab window (n+2
> epochs) and this node is torn down afterwards. So "authored blocks" is intentionally out of scope;
> the evidence to collect is the *syncing/importing* node with keys loaded, not produced blocks.

> **What was actually observed on this run (be honest about the two layers):**
> - **Cardano layer — real block progression.** `cardano-node` crossed the van Rossem/PV11 hard
>   fork (syncProgress → 100), and `cardano-db-sync` imported Cardano blocks into `cexplorer` with
>   `block_no` climbing (e.g. 4929534 → 4933636). This is the demonstrable block-height increase.
> - **Midnight layer — operational, at genesis.** The node runs in `--validator` mode with session
>   keys loaded and peers with the **official preprod bootnode**, on the correct chain (its genesis
>   `bestHash` matches). But `system_syncState` shows `highestBlock: 0` and the connected bootnode
>   itself reports `bestNumber: 0` — there is no block above genesis exposed to import, so the node
>   is *synced to what the network shows*, not stuck. A fresh, unauthorised FNO advancing its own
>   Midnight height is gated on committee authorisation + the n+2 epoch, which is out of lab scope.
>   Evidence here = node up, on the right chain, keys loaded, peered — not a rising Midnight height.

## Evening — start the long sync

```bash
# on the host, as root
sudo ./scripts/setup_node.sh --stage prereqs,secrets,mithril,cardano,postgres,dbsync \
     --db-secret midnight-validator-lab-preprod/postgres
```
Leave `cardano-db-sync` running overnight. Nothing to capture yet.

## Capture — once the node is up and DB Sync has caught up

Run each command from the repo root on the host (`/home/midnight/midnight-validator-lab`).
Every command `tee`s a file **and** prints to the terminal, so you can commit the file *and*
screenshot the output.

**1. Cardano node + db-sync are at the chain tip.** `verify-sync` reports the node's own
`syncProgress` and how many seconds db-sync trails the tip (small = caught up):
```bash
sudo ./scripts/setup_node.sh --stage verify-sync | tee evidence/01-sync-status.txt
sudo -u midnight psql -d cexplorer -c \
  "SELECT block_no, slot_no, time FROM block ORDER BY id DESC LIMIT 1;" \
  | tee evidence/02-dbsync-latest-block.txt
```
📷 Screenshot the `verify-sync` line: `syncProgress 100.00%` + `db-sync ... behind tip` (seconds).

**2. Session keys are loaded** (the node read Aura / Grandpa / Cross-chain from the keystore):
```bash
journalctl -u midnight-node --no-pager | grep -Ei 'AURA pubkey|GRANDPA pubkey|CROSS_CHAIN pubkey' \
  | tee evidence/03-session-keys.txt
```
📷 Screenshot the three `pubkey` lines.

**3. Block progression — take TWO snapshots a few minutes apart** (the block number must go up):
```bash
journalctl -u midnight-node --no-pager | grep -E 'Best:|Imported' | tail -n 20 \
  | tee evidence/04-block-progression-1.txt
sleep 300
journalctl -u midnight-node --no-pager | grep -E 'Best:|Imported' | tail -n 20 \
  | tee evidence/04-block-progression-2.txt
```
📷 Screenshot both — the highest `Best:#` in snapshot 2 should exceed snapshot 1.

**4. Health checker snapshot:**
```bash
sudo -u midnight ./scripts/node_health_check.py --once --verbose | tee evidence/05-health-check.txt
```
📷 Screenshot the coloured PASS/FAIL summary.

**5. Monitoring dashboard (Grafana):**
```bash
cd monitoring && docker compose up -d && cd ..
# From your laptop, SSM port-forward 3000 (see terraform/README.md), open http://localhost:3000
```
📷 Screenshot Grafana → `evidence/06-grafana-dashboard.png` (block height, peers, host metrics).

**6. Prove an alert fires to Slack** (stop the node → MidnightNodeDown → recover):
```bash
sudo systemctl stop midnight-node          # wait ~2 min: alert fires to #midnight-critical
# 📷 screenshot the Slack message → evidence/07-slack-alert.png
sudo systemctl start midnight-node         # sends the resolved notification
```

## Before committing

- **Scrub secrets.** Only public keys, block numbers, logs, and screenshots belong here —
  never `secretPhrase`, `.env`, `.pgpass`, or private keys. `.gitignore` blocks the obvious
  ones; eyeball each file anyway.
- If something is blocked (access, quota, time), just note it in the top-level `README.md` and
  commit whatever partial evidence you captured — a syncing node + working dashboards is plenty.
