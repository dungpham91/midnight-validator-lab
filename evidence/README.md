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

**1. Block progression (Cardano layer) — the demonstrable height increase.** db-sync keeps importing
Cardano blocks into `cexplorer`; take TWO snapshots a few minutes apart and the block number must go
up:
```bash
sudo -u midnight psql -d cexplorer -c \
  "SELECT max(block_no) AS cardano_block, now()-max(time) AS behind_tip FROM block;" \
  | tee -a evidence/01-cardano-progression.txt
sleep 300
sudo -u midnight psql -d cexplorer -c \
  "SELECT max(block_no) AS cardano_block, now()-max(time) AS behind_tip FROM block;" \
  | tee -a evidence/01-cardano-progression.txt
```
📷 Screenshot both rows — `cardano_block` in the 2nd is higher, `behind_tip` stays small.

**2. Node is at the chain tip, across the PV11 hard fork.** `verify-sync` prints cardano-node's own
`syncProgress` and how far db-sync trails the tip:
```bash
sudo ./scripts/setup_node.sh --stage verify-sync | tee evidence/02-sync-status.txt
```
📷 Screenshot: `syncProgress 100.00%` + `cardano-db-sync ... behind tip` (seconds).

**3. Midnight node is operational** — validator mode, session keys loaded, on the correct chain,
peered. (Session keys are verified by the **keystore files**, not by log text — midnight-node 0.22.2
does not print `AURA pubkey`.)
```bash
sudo -u midnight ls -la /home/midnight/data/chains/midnight_preprod/keystore/ | tee evidence/03-keystore.txt
curl -s -d '{"jsonrpc":"2.0","id":1,"method":"system_health","params":[]}' \
  -H 'Content-Type: application/json' localhost:9933 | tee evidence/04-midnight-health.txt; echo
curl -s -d '{"jsonrpc":"2.0","id":1,"method":"system_peers","params":[]}' \
  -H 'Content-Type: application/json' localhost:9933 | tee evidence/05-midnight-peers.txt; echo
```
📷 Screenshot: keystore holds `aura`/`gran`/`beef` files; health shows `peers` ≥ 1; the peer's
`bestHash` equals your node's genesis (same chain).
> The Midnight height stays at genesis on purpose — an unauthorised FNO can't advance it in a lab
> window (see the honest note at the top). The height increase to capture is the **Cardano** one in
> step 1; here you're proving the node is up, keyed, and on the right network.

**4. Health checker snapshot:**
```bash
sudo -u midnight ./scripts/node_health_check.py --once --verbose | tee evidence/06-health-check.txt
```
📷 Screenshot the coloured PASS/FAIL summary.

**5. Monitoring dashboard (Grafana):**
```bash
cd monitoring && docker compose up -d && cd ..
# From your laptop, SSM port-forward 3000 (see terraform/README.md), open http://localhost:3000
```
📷 Screenshot Grafana → `evidence/07-grafana-dashboard.png` (block height, peers, host metrics).

**6. Prove an alert fires to Slack** (stop the node → MidnightNodeDown → recover):
```bash
sudo systemctl stop midnight-node          # wait ~2 min: alert fires to #midnight-critical
# 📷 screenshot the Slack message → evidence/08-slack-alert.png
sudo systemctl start midnight-node         # sends the resolved notification
```

## Before committing

- **Scrub secrets.** Only public keys, block numbers, logs, and screenshots belong here —
  never `secretPhrase`, `.env`, `.pgpass`, or private keys. `.gitignore` blocks the obvious
  ones; eyeball each file anyway.
- If something is blocked (access, quota, time), just note it in the top-level `README.md` and
  commit whatever partial evidence you captured — a syncing node + working dashboards is plenty.
