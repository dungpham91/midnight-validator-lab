# RUNBOOK — Midnight FNO Onboarding (Pre-Prod)

> **Audience:** an engineer who knows Linux/DevOps but *not* Midnight.
> **Goal:** bring up a Midnight validator (Founding Node Operator) on the **pre-prod**
> network from a clean Ubuntu 24.04 host, and prove it is syncing.
>
> **Fidelity note.** The command blocks below are reproduced from the Midnight Foundation
> **FNO Preprod Docs** and kept faithful to the source (same order, same commands). My own
> additions (hardware/IOPS notes, gotchas, ordering guidance, teardown) are called out as
> `Gotcha` / `NOTE` blocks so they are additive, never a silent rewrite of the source.
>
> **Service account.** This runbook uses the dedicated **`midnight`** service account (created
> in §1.3) for every path and systemd unit. If you run as a different Linux user, substitute it
> throughout.

---

## 0. Mental model — what you are actually building

Midnight is a **partner chain of Cardano**. A Midnight validator cannot produce blocks on
its own; it continuously reads Cardano main-chain state from a local PostgreSQL database
populated by `cardano-db-sync`. So "run a Midnight node" means running a small stack, all on
**one host**. Architecture (from the FNO docs):

```mermaid
graph TD
    subgraph "Cardano Network (Preprod)"
        P2P[Cardano Peer-to-Peer Network]
        MithrilAgg[Mithril Aggregator - Preprod]
    end
    subgraph "Local Server"
        subgraph "Cardano Node Service"
            Node[cardano-node]
            LocalDB[(Immutable & Ledger DB)]
            Socket[[Unix Socket: node.socket]]
        end
        subgraph "Data Sync Layer"
            MithrilClient[Mithril Client]
            DBSync[cardano-db-sync]
        end
        subgraph "Storage Layer"
            Postgres[(PostgreSQL 17)]
        end
    end
    P2P <-->|Blockchain Protocols| Node
    MithrilAgg -.->|Download Snapshot| MithrilClient
    MithrilClient -.->|Bootstrap| LocalDB
    Node --- LocalDB
    Node --- Socket
    Socket --- DBSync
    DBSync -->|SQL Inserts| Postgres
```

**Critical path / timing.** `cardano-db-sync` is a hard prerequisite and the long pole.
Start the Cardano side **first** and let it run. Mithril snapshot bootstrap makes pre-prod
much faster than a genesis sync, but budget several hours and start overnight. Do **not**
attempt the Midnight validator launch until DB Sync is ≥99%.

> **Preprod vs Mainnet (per docs):** pre-prod uses a different Mithril aggregator endpoint,
> a smaller database, and different chain configuration files.

### 0.1 Dependencies on the Midnight Foundation & recommended ordering

Two things in this runbook depend on the Foundation / on elapsed epochs, **not** on you:

| Step | External dependency | Can it be front-loaded? |
|---|---|---|
| Submit `partner-chains-public-keys.json` (§3.4) | Foundation must **authorise** your keys for block production | **Yes** — do this first |
| Block *production* starting | Foundation authorisation **+** the **n+2 epoch** cycle (§5.4.2) | No — inherent wait |
| (Mainnet only) WireGuard overlay (§Appendix) | Foundation assigns overlay IP/peers | N/A on pre-prod |

**Key generation does NOT require a synced Cardano stack.** You can install the Midnight
binary and generate + submit your keys (§3) within minutes of booting the host, in parallel
with the long DB Sync. Front-loading the registration means any Foundation-side processing
and the n+2 clock can start as early as possible.

> **In a lab / simulation (no real Foundation onboarding):** key authorisation is not granted,
> so you create and keep `partner-chains-public-keys.json` but will not receive a real
> authorisation. That is not a blocker to bringing the node up; the only real long pole is
> Cardano DB Sync. Recommended order: **(1)** boot host, **(2)** start Cardano + DB Sync (§2),
> **(3)** in parallel, install midnight-node and generate the keys (§3), **(4)** once DB Sync
> ≥99%, launch the validator (§5).

---

> **Automation shortcut.** Every stage below is scripted in
> [`scripts/setup_node.sh`](scripts/setup_node.sh) (structured logging, `--dry-run`, secrets
> from AWS Secrets Manager). Read this runbook to understand what it does, then run the script
> to do it. `sudo ./scripts/setup_node.sh --dry-run` first.

## 1. FNO Preprod Requirements

### 1.1 Region & Cloud Strategy
Pre-prod nodes may be deployed in any region. Regional requirements are less strict than
Mainnet; however, latency to peers should remain low for reliable validator performance.
This lab targets **`ap-southeast-1` (Singapore)** — the Terraform default. Any region works;
`us-east-1` is ~20% cheaper if its latency suits you (adjust `region` in `terraform.tfvars`).

### 1.2 Hardware Requirements
The following assume all services (Midnight node, Cardano node, DB Sync) run on one instance.

| Component | Preprod (Minimum) | Preprod (Comfort) |
|---|---|---|
| CPU | 8 cores (≥2.5 GHz) | 16 cores (≥3.0 GHz) |
| RAM | 32 GB | 64 GB |
| Storage | 500 GB NVMe SSD | 1 TB NVMe SSD |
| IOPS | ≥20,000 effective IOPS | ≥60,000 IOPS |
| Network | 500 Mbps, high uptime | 1 Gbps, high uptime |
| OS | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |

> **Gotcha — IOPS on managed VPS (e.g. AWS Lightsail).** `cardano-db-sync` + Postgres are
> IO-bound, which is exactly the profile AWS says *not* to put on Lightsail: its docs state
> that for "sustained IOPS performance ... or ... large databases ... we recommend using
> Amazon EC2 with GP2 or Provisioned IOPS SSD storage instead of Lightsail." AWS publishes
> **no IOPS figure** for Lightsail's SSD, and the bundle's system disk is intended for
> temporary data only — so the ≥20,000 IOPS target is not something Lightsail commits to. It
> still completes on pre-prod (smaller DB; Mithril removes most initial write load), but
> expect DB Sync to be slower.
>
> That AWS quote predates `gp3`, which has since **superseded `gp2`** (same general-purpose
> tier, but a 3,000-IOPS baseline independent of volume size, IOPS provisionable up to 16,000,
> and ~20% cheaper) — so the modern equivalent of AWS's advice is: use EC2 with **`gp3`**
> (baseline 3,000, up to 16,000 IOPS/volume — close to the target) or **`io2`** (provision
> beyond 20,000). Prefer `gp3` over `gp2`; there is no reason to pick `gp2` today.

### 1.3 Operating System & Environment
- Linux distributions must be compatible with **GLIBC ≥ 2.39**.
- Supported OS: **Ubuntu 24.04+** (recommended) or **Debian 13+**.

```bash
ldd --version    # confirm >= 2.39
```

> **NOTE (added).** Create a dedicated service user and install the base packages used
> across the stack before starting:
> ```bash
> sudo adduser --disabled-password --gecos "" midnight && sudo usermod -aG sudo midnight
> sudo su - midnight
> sudo apt update && sudo apt install -y curl wget jq ca-certificates pv build-essential pkg-config
> ```

---

## 2. Set up Cardano Preprod Availability

This deploys a Cardano relay node and a PostgreSQL database synchronised by cardano-db-sync,
using Mithril to accelerate synchronisation.

### 2.1 Download the Cardano database snapshot

**2.1.1 Install Mithril tooling**
```bash
mkdir -p $HOME/tmp/mithril && cd $HOME/tmp/mithril

curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/input-output-hk/mithril/refs/heads/main/mithril-install.sh | sh -s -- -c mithril-signer -d unstable -p $(pwd)
curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/input-output-hk/mithril/refs/heads/main/mithril-install.sh | sh -s -- -c mithril-client -d unstable -p $(pwd)
curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/input-output-hk/mithril/refs/heads/main/mithril-install.sh | sh -s -- -c mithril-aggregator -d unstable -p $(pwd)
```

**2.1.2 Configure environment variables (Preprod)**
```bash
export CARDANO_NETWORK=preprod
export AGGREGATOR_ENDPOINT=https://aggregator.release-preprod.api.mithril.network/aggregator
export GENESIS_VERIFICATION_KEY=$(wget -q -O - https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/release-preprod/genesis.vkey)
export ANCILLARY_VERIFICATION_KEY=$(wget -q -O - https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/release-preprod/ancillary.vkey)
export SNAPSHOT_DIGEST=latest
```
> For the latest aggregator endpoints and keys, see the Mithril Network Documentation:
> https://mithril.network/doc/manual/getting-started/network-configurations

**2.1.3 Download the snapshot**
```bash
# List available snapshots
./mithril-client cardano-db snapshot list
# Show details for the target snapshot
./mithril-client cardano-db snapshot show $SNAPSHOT_DIGEST
# Download the database
./mithril-client cardano-db download --include-ancillary $SNAPSHOT_DIGEST
```
The snapshot is saved to a `db/` directory in your current path.

### 2.2 Set up the Cardano relay node

**2.2.1 Download Cardano node binaries**
```bash
# Runtime libs cardano-node 11.x links against (LSM storage):
sudo apt-get install -y liburing2 libsnappy1v5

mkdir -p ~/.local/bin ~/.local/share

VERSION="11.0.1"
ARCH="linux-amd64"
URL="https://github.com/IntersectMBO/cardano-node/releases/download/${VERSION}/cardano-node-${VERSION}-${ARCH}.tar.gz"

curl -L "$URL" | tar -xz -C ~/.local/bin --strip-components=2 ./bin
curl -L "$URL" | tar -xz -C ~/.local/share --strip-components=2 ./share
chmod +x ~/.local/bin/cardano-*

cardano-node --version
```
> **Gotcha — pin to the network's *current* required version, not a stale one.** preprod ran the
> **van Rossem (PV11)** intra-era hard fork in late June 2026. A node older than the fork
> (`≤10.7.1`) is rejected with `HeaderError ... ObsoleteNode`, replays only up to the fork slot,
> and then stalls — every peer refuses it. `11.0.1` is the first release that crosses PV11. Before
> a fresh install, check the [cardano-node releases](https://github.com/IntersectMBO/cardano-node/releases)
> for the version the network currently requires rather than copying a number from any doc.
> **Gotcha — `share` extraction (corrected from the source docs).** The upstream doc extracts
> `share` with `--strip-components=1`, but the tarball entries are `./share/preprod/...`, so
> `1` lands the files at `~/.local/share/**share**/preprod/config.json` while the systemd unit
> (and the db-sync `NodeConfigFile`) expect `~/.local/share/preprod/config.json`. With the
> doc's value cardano-node **fails to start** ("config not found") and nothing syncs. Use
> **`--strip-components=2`** (as above) so configs land at `~/.local/share/preprod/`. Verified
> against the real 11.0.1 tarball. `scripts/setup_node.sh` already uses `2`. Sanity-check after:
> `ls ~/.local/share/preprod/config.json`.
>
> **NOTE (added) — verify the download (supply chain).** The release ships
> `cardano-node-11.0.1-sha256sums.txt`. To check before trusting the binary:
> ```bash
> cd ~/tmp && curl -L -O "$URL" && curl -L -O "https://github.com/IntersectMBO/cardano-node/releases/download/${VERSION}/cardano-node-${VERSION}-sha256sums.txt"
> sha256sum -c cardano-node-${VERSION}-sha256sums.txt --ignore-missing
> ```
> `scripts/setup_node.sh` does this automatically.

**2.2.2 Initialize the data directory**
```bash
mkdir ~/cardano-data
mv ~/tmp/mithril/db/ ~/cardano-data/
```

**2.2.3 Configure the systemd service**
Create `/etc/systemd/system/cardano-node.service` (uses the `midnight` service account):
```ini
[Unit]
Description=Cardano Relay Node (Preprod)
Wants=network-online.target
After=network-online.target

[Service]
User=midnight
Type=simple
WorkingDirectory=/home/midnight/cardano-data
ExecStart=/home/midnight/.local/bin/cardano-node run \
    --topology /home/midnight/.local/share/preprod/topology.json \
    --database-path /home/midnight/cardano-data/db \
    --socket-path /home/midnight/cardano-data/db/node.socket \
    --host-addr 0.0.0.0 \
    --port 3001 \
    --config /home/midnight/.local/share/preprod/config.json
KillSignal=SIGINT
Restart=always
RestartSec=5
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable cardano-node
sudo systemctl start cardano-node
```

### 2.3 Configure PostgreSQL 17

> **NOTE — Terraform / Secrets Manager path.** If you provisioned the host with `terraform/`,
> the Postgres password is generated and stored in **AWS Secrets Manager**, and the host has a
> helper that applies it. After installing PostgreSQL (§2.3.1), instead of typing a password in
> §2.3.2/§2.3.3, run:
> ```bash
> sudo /usr/local/bin/fetch-node-secrets.sh
> ```
> This creates the `midnight` role + `cexplorer` DB from the managed password and writes
> `~/.pgpass` (socket **and** localhost entries, `0600`) — no secret is ever typed or
> committed. Skip to §2.4. The manual steps below are the fallback when not using Terraform.

**2.3.1 Install PostgreSQL**
```bash
sudo apt install curl ca-certificates -y
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -s -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
sudo sh -c 'echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
sudo apt update && sudo apt -y install postgresql-17 postgresql-server-dev-17
```

**2.3.2 Initialize the database and roles**
```sql
CREATE USER midnight WITH PASSWORD 'your_secure_password';
ALTER ROLE midnight WITH SUPERUSER CREATEDB;
CREATE DATABASE cexplorer;
```
> Run via `sudo -u postgres psql`. Choose a strong password; you will reuse it in `.pgpass`.

**2.3.3 Configure authentication** (`.pgpass` **must** be `0600`)
```bash
export POSTGRES_PASSWORD='your_secure_password'
export PGPASSFILE="${HOME}/.pgpass"

# Write both the Unix-socket and localhost/TCP entries so socket auth AND `-h localhost` work.
printf '%s\n%s\n' \
  "/var/run/postgresql:5432:cexplorer:midnight:$POSTGRES_PASSWORD" \
  "localhost:5432:cexplorer:midnight:$POSTGRES_PASSWORD" > "$PGPASSFILE"
chmod 0600 "$PGPASSFILE"
```

**2.3.4 Performance tuning**
Pre-prod DB sizes are much smaller than Mainnet; tuning is less critical but still
recommended. Update `/etc/postgresql/17/main/postgresql.conf`:

| Parameter | Recommended Value | Description |
|---|---|---|
| `shared_buffers` | 4GB | Keeps ledger data in active memory. |
| `maintenance_work_mem` | 1GB | Accelerates index building during sync. |
| `max_parallel_maintenance_workers` | 2 | Allows multiple cores to build indexes. |
| `effective_cache_size` | 12GB | Informs the planner of available RAM for caching. |
| `join_collapse_limit` | 1 | Force Postgres to follow the exact join order. |

```bash
sudo systemctl restart postgresql   # apply the tuning
```

### 2.4 Set up cardano-db-sync

**2.4.1 Install binaries and schema**
```bash
NETWORK="preprod"
mkdir -p ~/tmp && cd ~/tmp
# matched tag+filename (see Gotcha below — the upstream doc mismatched these and 404s)
curl -L -O https://github.com/IntersectMBO/cardano-db-sync/releases/download/13.7.2.1/cardano-db-sync-13.7.2.1-linux.tar.gz
tar -xzf cardano-db-sync-13.7.2.1-linux.tar.gz

# The tarball ships bin/ and schema/ read-only (0555). Use `cp -f` so a re-run can replace the
# read-only binaries in place, and `cp -a` (not `mv`) for schema: moving a directory to a new
# parent needs write on the dir itself (to rewrite its `..`), which 0555 denies to a non-root
# user. Restore write afterwards so the dir stays idempotently removable.
cp -f bin/* ~/.local/bin/
mkdir -p ~/cardano-data/
cp -a ~/tmp/schema ~/cardano-data/
chmod -R u+w ~/cardano-data/schema

cd ~/cardano-data
curl -O https://book.world.dev.cardano.org/environments/$NETWORK/db-sync-config.json
sed -i "s|\"NodeConfigFile\": \"config.json\"|\"NodeConfigFile\": \"/home/midnight/.local/share/$NETWORK/config.json\"|" ~/cardano-data/db-sync-config.json
```

> **Gotcha — match db-sync to the node version, and match tag to filename.** Two traps here:
> (1) db-sync must be paired with the running node — `13.7.2.1` is the release that matches
> cardano-node `11.0.1`/PV11; an older db-sync against an 11.x node can stall. Check the
> [db-sync releases](https://github.com/IntersectMBO/cardano-db-sync/releases) for the pairing.
> (2) The upstream doc mixed a tag with a *different* filename (e.g. tag `13.6.0.5` with file
> `13.6.0.7`), which 404s — each tag ships a filename that matches its own version
> (`cardano-db-sync-13.7.2.1-linux.tar.gz`). The command above uses the matched pair;
> `scripts/setup_node.sh` does the same.
> Releases: https://github.com/IntersectMBO/cardano-db-sync/releases
>
> **Supply chain:** unlike cardano-node and midnight-node, cardano-db-sync ships **no checksum
> file** for this release, so the download can't be checksum-verified from upstream. Pull it
> only over HTTPS from the official releases page (and, if you want extra assurance, compare
> the hash against a second trusted source).

**2.4.2 Restore from a database snapshot (optional)**
Pre-prod sync from genesis is faster than Mainnet, but a snapshot can still save time.
```bash
wget [SNAPSHOT_URL]
pv [SNAPSHOT_FILE].tgz | tar -xf -
mv ~/tmp/*.lstate.gz ~/cardano-data/db-sync-state/

pg_restore -h /var/run/postgresql -U midnight -d cexplorer -Fd ~/tmp/db -v --no-owner --no-privileges --jobs=4
```
> `[SNAPSHOT_URL]`/`[SNAPSHOT_FILE]` are placeholders in the source — supply a real db-sync
> snapshot if you have one; otherwise skip this step and let db-sync index from the node.

**2.4.3 Manage the db-sync service**
Create `/etc/systemd/system/cardano-db-sync.service`:
```ini
[Unit]
Description=Cardano DB Sync (Preprod)
After=cardano-node.service
Requires=cardano-node.service

[Service]
User=midnight
Type=simple
Environment="PGPASSFILE=/home/midnight/.pgpass"
WorkingDirectory=/home/midnight/cardano-data
ExecStart=/home/midnight/.local/bin/cardano-db-sync \
    --config /home/midnight/cardano-data/db-sync-config.json \
    --socket-path /home/midnight/cardano-data/db/node.socket \
    --schema-dir /home/midnight/cardano-data/schema \
    --state-dir /home/midnight/cardano-data/db-sync-state
KillSignal=SIGINT
Restart=always
RestartSec=10
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable cardano-db-sync
sudo systemctl start cardano-db-sync
```
> **Gotcha — startup delay.** db-sync can appear idle for 5–20 min on first start while
> it initialises the schema before rows appear in `block`. This is normal.

### 2.5 Verify synchronization — **do not proceed until ≥99%**
```sql
psql -d cexplorer -c "SELECT block_no, slot_no, time FROM block ORDER BY id DESC LIMIT 1;"
```
Calculate sync percentage:
```sql
psql -d cexplorer -c "
SELECT
    100 * (EXTRACT(epoch FROM (MAX(time) AT TIME ZONE 'UTC')) - EXTRACT(epoch FROM (MIN(time) AT TIME ZONE 'UTC')))
    / (EXTRACT(epoch FROM (NOW() AT TIME ZONE 'UTC')) - EXTRACT(epoch FROM (MIN(time) AT TIME ZONE 'UTC')))
AS sync_percent
FROM block;"
```
**Evidence:** once `sync_percent` ≈ 100, capture both queries into `evidence/`.

---

## 3. Install Midnight Node & Generate Validator Keys (Preprod)

> This is identical to the Mainnet procedure except `NETWORK=preprod` throughout.
> **Front-load this (see §0.1):** it needs the binary but **not** a synced Cardano stack, so
> run it in parallel with §2's DB Sync.

### 3.1 Install the Midnight node

**3.1.1 Prepare directories**
```bash
mkdir -p ~/data ~/res ~/.local/bin
```
- `~/data`: node database and base path · `~/res`: chain config files · `~/.local/bin`: binaries.

**3.1.2 Download and install the binary**
> Verify the latest release tag: https://github.com/midnightntwrk/midnight-node/releases
```bash
mkdir -p ~/tmp && cd ~/tmp
curl -L -O https://github.com/midnightntwrk/midnight-node/releases/download/node-0.22.2/midnight-node-0.22.2-linux-amd64.tar.gz
tar -xvzf midnight-node-0.22.2-linux-amd64.tar.gz

mv ~/tmp/midnight-node ~/.local/bin/
rm -rf ~/res && mv ~/tmp/res ~/res    # see Gotcha: plain 'mv ~/tmp/res ~/res' would nest
source ~/.bashrc
midnight-node --version
```
> **NOTE (added) — verify the download (supply chain).** The release also publishes
> `SHA256SUMS-amd64`. Before trusting the binary that will hold your keys, check it:
> ```bash
> cd ~/tmp && curl -L -O https://github.com/midnightntwrk/midnight-node/releases/download/node-0.22.2/SHA256SUMS-amd64
> sha256sum -c SHA256SUMS-amd64 --ignore-missing
> ```
> **Gotcha — `~/res` nesting (corrected above).** §3.1.1 pre-creates `~/res`, so the doc's plain
> `mv ~/tmp/res ~/res` moves the folder *into* it → `~/res/res/preprod/...`, but §5 expects
> `~/res/preprod/...`. The `rm -rf ~/res && mv` above avoids that; `scripts/setup_node.sh` does
> the same.

### 3.2 Manage validator keys

> These keys grant control over node identity, block production, finality, and cross-chain
> operations. Compromise can lead to loss of control over your node. See `SECURITY.md`.

| Key Name | Scheme | Type | Purpose |
|---|---|---|---|
| Node Key | ed25519 | Network | Persistent network identity (PeerID) for P2P |
| Aura Key | sr25519 | `aura` | Block production consensus (proposing blocks) |
| Grandpa Key | ed25519 | `gran` | Block finality (voting on the irreversible chain) |
| Cross-Chain | ecdsa | `beef` | Secure interaction/bridging with the Cardano parent chain |

> Session keys are only required for a **validator** (block producer). Non-validator relay
> nodes do not require session keys.

**3.2.1 Generate session keys**
```bash
cd ~
export CFG_PRESET=preprod         # required — see gotcha below
# Generate AURA (sr25519)
midnight-node key generate --scheme sr25519 --output-type json > aura.json
# Generate GRANDPA (ed25519)
midnight-node key generate --scheme ed25519 --output-type json > grandpa.json
# Generate CROSS-CHAIN (ecdsa)
midnight-node key generate --scheme ecdsa --output-type json > cross_chain.json
```
> **Gotcha — `key` subcommands load the chain config.** midnight-node's `key generate` / `key insert`
> / `key generate-node-key` build the chain config before running, so they fail with
> `Error: Input("chainspec_genesis_block not configured")` unless **`CFG_PRESET=preprod` is exported
> and you run from `~`**. The preset file `res/cfg/preprod.toml` points at the genesis with *relative*
> paths (`chainspec_genesis_block = "res/genesis/genesis_block_preprod.mn"`), which only resolve when
> the cwd is `~` (where `res/` lives). Keep `CFG_PRESET` exported for every `key` command in §3.2–3.3.
>
> Back up the JSON files immediately in a secure, offline location.

**3.2.2 Generate the network key**
```bash
NETWORK="preprod"
NETWORK_DIR="$HOME/data/chains/midnight_${NETWORK}/network"
mkdir -p "$NETWORK_DIR"
chmod 700 "$NETWORK_DIR"

midnight-node key generate-node-key --file "$NETWORK_DIR/secret_ed25519"
```
View your unique PeerID:
```bash
midnight-node key inspect-node-key --file "$NETWORK_DIR/secret_ed25519"
```

### 3.3 Configure the keystore
```bash
sudo apt-get install jq -y

cd ~
export CFG_PRESET=preprod          # key insert loads the chain config too (see §3.2.1 gotcha)
KEYSTORE_PATH="$HOME/data/chains/midnight_preprod/keystore"
mkdir -p "$KEYSTORE_PATH"

# Insert AURA key
midnight-node key insert \
  --keystore-path "$KEYSTORE_PATH" \
  --scheme sr25519 \
  --key-type aura \
  --suri "$(jq -r .secretPhrase aura.json)"

# Insert GRANDPA key
midnight-node key insert \
  --keystore-path "$KEYSTORE_PATH" \
  --scheme ed25519 \
  --key-type gran \
  --suri "$(jq -r .secretPhrase grandpa.json)"

# Insert Cross-Chain key
midnight-node key insert \
  --keystore-path "$KEYSTORE_PATH" \
  --scheme ecdsa \
  --key-type beef \
  --suri "$(jq -r .secretPhrase cross_chain.json)"
```

### 3.4 Register as a Founding Node Operator (FNO)

> Midnight's docs title this step "Federated Node Operator"; it is the same FNO role. This
> guide uses "Founding" throughout for consistency.

**3.4.1 Create the registration file**
```bash
OUTPUT_FILE="$HOME/partner-chains-public-keys.json"

cat <<EOF > "$OUTPUT_FILE"
{
  "partner_chains_key": "$(jq -r .publicKey cross_chain.json)",
  "keys": {
    "aura": "$(jq -r .publicKey aura.json)",
    "crch": "$(jq -r .publicKey cross_chain.json)",
    "gran": "$(jq -r .publicKey grandpa.json)"
  }
}
EOF
```

**3.4.2 Verify the output**
```bash
cat "$OUTPUT_FILE"
```
This JSON file is your **Validator Application**. In a real onboarding you would share it with the
Midnight Foundation to be authorised for block production on Preprod. **Only public keys leave the box.**

> **Lab scope — do NOT submit.** This lab stops at a running, syncing validator; it does **not**
> submit `partner-chains-public-keys.json` to the Foundation. Authorisation is Foundation-gated and
> only takes effect after the n+2 epoch (days), so it can't complete inside a lab window anyway — and
> this is a throwaway node that gets `terraform destroy`ed, so its keys should never be registered.
> The file is still generated to demonstrate the registration step; §3.4.3 below documents *how* you
> would submit it. Completion here = the node up, keys loaded, and block height progressing (see
> [`evidence/`](evidence/)). The rest of §3.4 is reference for a real deployment.

**3.4.3 What you send, and how to send it safely (reference — not performed in this lab)**

*What to send (pre-prod):* only `partner-chains-public-keys.json`, which contains exclusively
**public** keys — the cross-chain ecdsa public key (`partner_chains_key` / `crch`), the Aura
sr25519 public key (`aura`), and the Grandpa ed25519 public key (`gran`). Nothing secret is
in this file (it is built with `jq -r .publicKey`, not `.secretPhrase`).

> **NEVER send:** the `secretPhrase` from `aura.json` / `grandpa.json` / `cross_chain.json`,
> the keystore directory, `secret_ed25519`, `.pgpass`, or `.env`. Those stay on the host.
> Verify before sending: `grep -i secret partner-chains-public-keys.json` should return nothing.

*Why "secure" still matters even though the keys are public:* the risk here is **authenticity
& integrity**, not confidentiality. If an attacker intercepts your registration and swaps in
their own public keys, they — not you — get authorised into your validator slot. So protect
the *binding* between your identity and your keys:

1. **Use the official channel only.** Submit via the Foundation-designated route — the
   `fno-validator-ops` channel in the Midnight Discord (requires the validator role; request
   it from the Foundation) or an official onboarding form/portal over HTTPS. Confirm the
   destination is genuine; ignore unsolicited DMs asking for your keys (impersonation).
2. **Use an integrity-protected transport.** Prefer the official HTTPS form/portal or an
   authenticated channel where your operator identity is verified over plain email.
3. **Provide an out-of-band fingerprint.** Share a checksum so the recipient can verify the
   file was not altered in transit:
   ```bash
   sha256sum partner-chains-public-keys.json
   ```
   Optionally GPG-sign the message/file so the Foundation can verify it is really from you.
4. **Confirm receipt** through the same official channel, and keep a record of what/when you
   submitted (for audit).

(Mainnet additionally requires sending your WireGuard `publickey`, public `IP:Port`, and node
PeerID — see Appendix A. Not applicable on pre-prod.)

### 3.5 Best practices for secret management
- **Restricted permissions:** `chmod 600` on all key files.
- **Systemd credential loading:** use `LoadCredential=` to inject secrets at runtime.
- **Secrets managers:** integrate HashiCorp Vault, AWS Secrets Manager, or Azure Key Vault
  for dynamic injection and rotation.

---

## 4. WireGuard — SKIP on pre-prod

> **Gotcha — do not do the WireGuard page for pre-prod.** The FNO Docs include a WireGuard
> guide whose title says "(Preprod)", but its own body describes integrating into "the
> Midnight **Mainnet's** trusted overlay". The authoritative "Run in Validator Mode (Preprod)"
> page states: *"Preprod does not use the WireGuard guarded overlay. The `--reserved-only` and
> `--reserved-nodes` flags are not required. The node connects to the Preprod network through
> standard peer discovery."*
>
> **Impact of skipping on pre-prod: none.** WireGuard is only the private point-to-point mesh
> between trusted validators on mainnet. On pre-prod the node discovers peers over the public
> P2P network — you only need **P2P port 6000** reachable (and Cardano's 3001). Syncing, RPC,
> peering, and block production all work without it, and you avoid the static-IP requirement.
>
> The full WireGuard procedure is preserved in the **Appendix (mainnet reference)** below for
> completeness, but is **not executed** for this pre-prod runbook.

---

## 5. Run the Midnight Node in Validator Mode (Preprod)

> **Preprod vs Mainnet:** pre-prod does **not** use the WireGuard overlay; `--reserved-only`
> / `--reserved-nodes` are not required. Standard peer discovery is used.
>
> **Check-list — at this point you should have:**
> - Fully synced Cardano Preprod availability services (§2, sync ≥99%).
> - Generated and shared your public validator keys with the Foundation (§3).

### 5.1 Prepare the environment configuration
> The source uses a `.env` file for demonstration. For production, use a secure secret
> manager (HashiCorp Vault, AWS Secrets Manager, Azure Key Vault).

**5.1.1 Verify connection variables**
```bash
# Retrieve the PostgreSQL password
export POSTGRES_PASSWORD=$(cut -d: -f5 ~/.pgpass)
echo $POSTGRES_PASSWORD

# Verify database connectivity
psql -h localhost -p 5432 -U midnight -d cexplorer -c "SELECT 'PostgreSQL Connection Verified' AS status;"
```

> **NOTE — `.pgpass` covers socket + TCP.** §2.3.3 writes both a `/var/run/postgresql` (socket)
> and a `localhost` (TCP) entry, so the `-h localhost` verify above authenticates via `.pgpass`
> without prompting. (The upstream doc wrote only the socket entry, which made this TCP verify
> prompt for a password — corrected here and in `scripts/setup_node.sh`.)

**5.1.2 Create the `.env` file** (`~/.env`)
```dotenv
# PostgreSQL connection
POSTGRES_HOST='localhost'
POSTGRES_DB='cexplorer'
POSTGRES_PORT=5432
POSTGRES_USER='midnight'
POSTGRES_PASSWORD='YOUR_POSTGRES_PASSWORD'
DB_SYNC_POSTGRES_CONNECTION_STRING=postgresql://midnight:YOUR_POSTGRES_PASSWORD@localhost:5432/cexplorer

# Cardano Preprod params
CARDANO_SECURITY_PARAMETER='432'
BLOCK_STABILITY_MARGIN=30

# Push to public telemetry
PROMETHEUS_PUSH_ENDPOINT='https://telemetry.shielded.tools/api/v1/receive'

# Midnight node settings
CFG_PRESET=preprod
NODE_NAME='YOUR_NODE_NAME'

# Absolute path to network and keystore files
NODE_KEY_FILE='/home/midnight/data/chains/midnight_preprod/network/secret_ed25519'
AURA_SEED_FILE='/home/midnight/keystore/61757261...'
GRANDPA_SEED_FILE='/home/midnight/keystore/6265656...'
CROSS_CHAIN_SEED_FILE='/home/midnight/keystore/6772616...'
```
> **Gotcha — keystore path in `.env` vs where keys were inserted.** The `*_SEED_FILE`
> paths above point at `/home/midnight/keystore/<hex>...`, but §3.3 inserts keys into
> `/home/midnight/data/chains/midnight_preprod/keystore`. The hex prefixes are the key-type
> encodings (`61757261`=`aura`, `6772616e`=`gran`, `62656566`=`beef`/cross-chain). Note the
> source `.env` also **transposes two labels**: `GRANDPA_SEED_FILE` shows a `6265656…`
> (`beef` = cross-chain) prefix and `CROSS_CHAIN_SEED_FILE` shows a `6772616…` (`gran` =
> grandpa) prefix — i.e. swapped. The launch command in §5.2 loads keys automatically from
> `--base-path .../data/chains/midnight_preprod/keystore`, so these `*_SEED_FILE` values are
> informational; if you actually wire them, fix the swap and point them at the real hex-named
> files created by §3.3. (`scripts/setup_node.sh` omits these lines entirely, for this reason.)

### 5.2 Perform an interactive test launch
```bash
source ~/.env

# On Preprod, the node connects through standard peer discovery — no overlay flags required.
midnight-node \
    --chain /home/midnight/res/preprod/chain-spec-raw.json \
    --base-path /home/midnight/data \
    --telemetry-url 'wss://telemetry.shielded.tools./submit 1' \
    --validator \
    --pool-limit 35 \
    --name ${NODE_NAME} \
    --rpc-port 9933 \
    --prometheus-external --prometheus-port 9615
```

> **NOTE (added) — Prometheus metrics for §Monitoring.** The `--prometheus-external
> --prometheus-port 9615` flags (included in the launch above and the §5.3 unit) expose node
> metrics on `:9615` for the monitoring stack to scrape — matching `scripts/setup_node.sh`.
>
> **Gotcha — telemetry URL.** The `--telemetry-url` value is reproduced verbatim from the
> docs, including the trailing dot in `telemetry.shielded.tools.` — a trailing-dot FQDN is
> technically valid but looks like a typo; the canonical host (and the `PROMETHEUS_PUSH_ENDPOINT`)
> is `telemetry.shielded.tools` without it. Verify against the current docs if telemetry
> doesn't register.

**5.2.2 Verify node output**
- **Postgres connection established** — DB settings correct.
- **Peers** — if peer count stays at 0, check firewall for **port 6000**.
- **Syncing** — the `Best: #` value should increment as the node pulls blocks.

### 5.3 Deploy as a systemd service
Create `/etc/systemd/system/midnight-node.service` (ExecStart path typically
`/home/midnight/.local/bin/midnight-node`):
```ini
[Unit]
Description=Midnight Protocol Node (Preprod FNO)
After=network.target postgresql.service
Wants=postgresql.service

[Service]
User=midnight
Group=midnight
Type=simple
WorkingDirectory=/home/midnight
EnvironmentFile=/home/midnight/.env

ExecStart=/home/midnight/.local/bin/midnight-node \
    --chain /home/midnight/res/preprod/chain-spec-raw.json \
    --base-path /home/midnight/data \
    --telemetry-url 'wss://telemetry.shielded.tools./submit 1' \
    --validator \
    --pool-limit 35 \
    --name ${NODE_NAME} \
    --rpc-port 9933 \
    --prometheus-external --prometheus-port 9615

Restart=on-failure
RestartSec=10
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable midnight-node
sudo systemctl start midnight-node
```

### 5.4 Verify block production

**5.4.1 Check session keys**
```bash
journalctl -u midnight-node -f
```
Look for these at node startup:
- `AURA pubkey: ...`
- `GRANDPA pubkey: ...`
- `CROSS_CHAIN pubkey: ...`
> If these lines are missing, the node has no keys loaded and cannot participate in validation.

**5.4.2 Understand the n+2 epoch rule**
Validators do not produce blocks immediately. Midnight follows an n+2 transition cycle:
- **Epoch n:** added to the whitelist. Node remains passive.
- **Epoch n+1:** queued for the next session. Still passive.
- **Epoch n+2:** joins the validator set and begins block production.

**5.4.3 Confirm block authoring**
When your node begins producing blocks, you will see logs like:
```text
✨ Imported #12345 (0xabc1…def2)
🏆 Prepared block for proposing at #12346
🔖 Pre-sealed block for proposal at #12346
✨ Successfully proposed block #12346 (0xdef3…ghi4)
```
If you see `Successfully proposed block`, your node is actively contributing to consensus.

> **Gotcha — expected evidence on a freshly-onboarded node.** Because block production requires
> (a) Foundation authorisation of your keys and (b) the n+2 epoch cycle, a freshly-onboarded
> FNO will **not** show `Successfully proposed block` within a short window. The honest,
> achievable evidence is a **syncing** node: `Best: #` climbing, peers > 0, and
> "Postgres connection established". Capture that to `evidence/` and note the n+2 lifecycle.

---

## 6. Teardown (cost control) — *added*

```bash
sudo systemctl disable --now midnight-node cardano-db-sync cardano-node postgresql
# then DELETE the cloud instance — Lightsail bills up to the monthly cap if left running.
```

---

## Appendix A — WireGuard overlay (MAINNET reference, not run on pre-prod)

Reproduced from the FNO WireGuard page for completeness. **Skip entirely on pre-prod.**

1. **Install WireGuard tools `v1.0.20250521`** (build from source):
   ```bash
   sudo apt update && sudo apt install -y git build-essential pkg-config libelf-dev linux-headers-$(uname -r)
   WIREGUARD_TOOLS_VERSION="v1.0.20250521"
   WORKDIR="$(mktemp -d)"
   git clone https://git.zx2c4.com/wireguard-tools "$WORKDIR/wireguard-tools"
   cd "$WORKDIR/wireguard-tools" && git checkout "$WIREGUARD_TOOLS_VERSION"
   make -C src && sudo make -C src install
   wg --version
   ```
2. **Generate the tunnel keypair:**
   ```bash
   umask 077
   wg genkey | tee privatekey | wg pubkey > publickey
   ```
   `privatekey` stays on the server; `publickey` is sent to the Foundation.
   (The Substrate network key / PeerID is the same one from §3.2.2.)
3. **Send to the Foundation:** your `publickey`, public `IP:Port`, and node PeerID (via their form).
4. **Configure `/etc/wireguard/wg0.conf`** with the assigned overlay IP + peers:
   ```ini
   [Interface]
   Address = <assigned_overlay_ip>/32
   PrivateKey = <your_wireguard_private_key>
   ListenPort = 51820
   MTU = 1420

   [Peer]
   PublicKey = <validator_wg_public_key>
   Endpoint = <validator_public_ip>:51820
   AllowedIPs = <validator_overlay_ip>/32
   PersistentKeepalive = 25
   ```
5. **Enable and verify:**
   ```bash
   sudo systemctl enable --now wg-quick@wg0
   sudo wg show     # expect a recent handshake and Transfer > 0 B
   ```

---

## Appendix B — port & version reference

| Component | Version | Port |
|---|---|---|
| cardano-node | 11.0.1 | 3001 (P2P) |
| PostgreSQL | 17 | 5432 |
| cardano-db-sync | 13.7.2.1 | — (Unix socket) |
| midnight-node | 0.22.2 | 9933 (RPC), 6000 (P2P), 9615 (Prometheus, if enabled) |
| WireGuard (mainnet only) | v1.0.20250521 | 51820 |

## Appendix C — quick service health
```bash
systemctl status cardano-node cardano-db-sync postgresql midnight-node --no-pager
journalctl -u midnight-node -n 100 --no-pager
```

---

## Appendix D — Communication channels & operational references

From the **FNO Hub**. FNOs operate both Preprod and Mainnet; some links below are
Mainnet-oriented — noted where relevant.

**Communication channels (do these as part of onboarding):**
- **Notifi — Validators list:** subscribe at https://midnight.notifi.network/ (operational
  announcements are sent here; whoever runs the node must be subscribed).
- **Discord — `fno-validator-ops`:** primary FNO operations chat. Requires the **validator
  role** — request access from the Midnight Foundation. Invite: https://discord.com/invite/midnightnetwork
- This is also the channel used to submit/coordinate your validator keys (§3.4.3).

**Dashboards & telemetry (useful for monitoring / verification):**
- **Network Telemetry:** https://telemetry.shielded.tools/ — the public telemetry service your
  node pushes to (matches `PROMETHEUS_PUSH_ENDPOINT` and `--telemetry-url` in §5). You can see
  your node by the `NODE_NAME` you set.
- **Health Status dashboard:** https://po-dash-0-1.vercel.app/dashboard — diagnostic tool /
  runbook reference (Mainnet operations).
- **Block Explorer:** http://midnightexplorer.com/ (Mainnet Lite).

**Repositories:**
- https://github.com/midnightntwrk — including `midnight-node` (binary + `res/` chain specs).

> **NOTE.** No separate "Prerequisites" page exists in the FNO Preprod Docs — prerequisites
> are the Requirements in §1 (Ubuntu 24.04, GLIBC ≥2.39, hardware). The `make`/`gcc` build
> tools the docs mention are only needed to compile WireGuard, which is **not used on
> pre-prod** (Appendix A).
