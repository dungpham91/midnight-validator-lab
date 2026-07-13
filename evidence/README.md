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

## Evening — start the long sync

```bash
# on the host, as root
sudo ./scripts/setup_node.sh --stage prereqs,secrets,cardano,postgres,dbsync \
     --db-secret midnight-validator-lab-preprod/postgres
```
Leave `cardano-db-sync` running overnight. Nothing to capture yet.

## Next morning — capture once DB Sync is ~99%

**1. Cardano DB Sync progress** (wait until `sync_percent` ≈ 100):
```bash
sudo -u midnight psql -d cexplorer -c \
  "SELECT block_no, slot_no, time FROM block ORDER BY id DESC LIMIT 1;" \
  | tee evidence/01-dbsync-latest-block.txt
sudo -u midnight psql -d cexplorer -c \
  "SELECT round(100*(EXTRACT(epoch FROM (MAX(time) AT TIME ZONE 'UTC')) - EXTRACT(epoch FROM (MIN(time) AT TIME ZONE 'UTC'))) / (EXTRACT(epoch FROM (NOW() AT TIME ZONE 'UTC')) - EXTRACT(epoch FROM (MIN(time) AT TIME ZONE 'UTC'))),2) AS sync_percent FROM block;" \
  | tee evidence/02-dbsync-sync-percent.txt
```

**2. Bring up the validator** (installs node + keys + starts once sync is ready):
```bash
sudo ./scripts/setup_node.sh --stage midnight,keys,env,service --wait-sync \
     --db-secret midnight-validator-lab-preprod/postgres --node-name my-fno
```

**3. Session keys loaded + block progression:**
```bash
journalctl -u midnight-node --no-pager | grep -Ei 'AURA pubkey|GRANDPA pubkey|CROSS_CHAIN pubkey' \
  | tee evidence/03-session-keys.txt
journalctl -u midnight-node --no-pager | grep -E 'Postgres|Best:|Imported|peers' \
  | tail -n 100 | tee evidence/04-block-progression.txt
```

**4. Health checker snapshot:**
```bash
sudo -u midnight ./scripts/node_health_check.py --once --verbose | tee evidence/05-health-check.txt
```

**5. Monitoring works end-to-end** (start the stack, screenshot Grafana):
```bash
cd monitoring && docker compose up -d
# From your laptop, SSM port-forward 3000 (see terraform/README.md), then screenshot:
#   evidence/06-grafana-dashboard.png   (best/finalized block, peers, host)
```

**6. Prove an alert fires to Slack** (stop the node → MidnightNodeDown → recover):
```bash
sudo systemctl stop midnight-node          # wait ~2 min: alert fires to #midnight-critical
# screenshot the Slack message → evidence/07-slack-alert.png
sudo systemctl start midnight-node         # sends the resolved notification
```

## Before committing

- **Scrub secrets.** Only public keys, block numbers, logs, and screenshots belong here —
  never `secretPhrase`, `.env`, `.pgpass`, or private keys. `.gitignore` blocks the obvious
  ones; eyeball each file anyway.
- If something is blocked (access, quota, time), just note it in the top-level `README.md` and
  commit whatever partial evidence you captured — a syncing node + working dashboards is plenty.
