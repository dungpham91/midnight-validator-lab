#!/usr/bin/env bash
#
# setup_node.sh — automate the Midnight pre-prod FNO onboarding from RUNBOOK.md.
#
# Mirrors the runbook stages (Cardano availability -> Postgres -> db-sync -> Midnight node)
# as re-runnable, idempotent-where-possible functions. Secrets are pulled from AWS Secrets
# Manager (never hard-coded). Structured logging: timestamp + level + colour (auto-off when
# not a TTY / NO_COLOR / --no-color). Strict mode + ERR/EXIT traps for error handling.
#
# Run as root on Ubuntu 24.04. See --help.

set -euo pipefail
IFS=$'\n\t'

# ─── Constants ────────────────────────────────────────────────────────────────────────
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly VERSION="1.0.0"

readonly CARDANO_NODE_VERSION="11.0.1"   # PV11/van Rossem hard fork: ≤10.7.1 is obsolete on preprod. Check release notes for the current requirement.
readonly DBSYNC_VERSION="13.7.2.1"       # matched to node 11.0.1; asset: cardano-db-sync-13.7.2.1-linux.tar.gz
readonly MIDNIGHT_NODE_VERSION="0.22.2"
readonly PG_VERSION="17"

readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3
readonly LOG_LEVEL_FATAL=4

# All valid stages, in execution order.
readonly ALL_STAGES=(prereqs secrets mithril cardano postgres dbsync verify-sync midnight keys env service verify)

# ─── Defaults (overridable via flags) ─────────────────────────────────────────────────
node_user="midnight"
network="preprod"
node_name="midnight-fno-$(hostname -s 2>/dev/null || echo node)"
region="ap-southeast-1"
db_secret=""            # AWS Secrets Manager secret name/id holding {"password": ...}
db_password_file=""     # alternative: read password from a file
slack_secret=""         # optional Slack webhook secret
stages_csv="all"
max_lag_seconds=180     # db-sync is "caught up" when its latest block trails the tip by <= this
wait_sync=false
dry_run=false
no_color=false
current_log_level="${LOG_LEVEL_INFO}"

# Populated at runtime; never logged.
DB_PASS=""

# ─── Colours & logging ────────────────────────────────────────────────────────────────
c_reset=""; c_debug=""; c_info=""; c_warn=""; c_error=""; c_fatal=""

function setup_colors() {
    if [[ "${no_color}" == false && -z "${NO_COLOR:-}" && -t 2 ]]; then
        c_reset=$'\033[0m'; c_debug=$'\033[90m'; c_info=$'\033[32m'
        c_warn=$'\033[33m'; c_error=$'\033[31m'; c_fatal=$'\033[1;31m'
    fi
}

# _log <level_num> <level_name> <colour> <message...>
function _log() {
    local level="${1}" name="${2}" colour="${3}"; shift 3
    (( level < current_log_level )) && return 0
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s%s %-5s %s%s\n' "${colour}" "${ts}" "${name}" "$*" "${c_reset}" >&2
}
function log_debug() { _log "${LOG_LEVEL_DEBUG}" DEBUG "${c_debug}" "$@"; }
function log_info()  { _log "${LOG_LEVEL_INFO}"  INFO  "${c_info}"  "$@"; }
function log_warn()  { _log "${LOG_LEVEL_WARN}"  WARN  "${c_warn}"  "$@"; }
function log_error() { _log "${LOG_LEVEL_ERROR}" ERROR "${c_error}" "$@"; }
function log_fatal() { _log "${LOG_LEVEL_FATAL}" FATAL "${c_fatal}" "$@"; exit 1; }

# ─── Error handling / cleanup ─────────────────────────────────────────────────────────
function _on_error() {
    local exit_code="${1}" line="${2}"
    log_error "aborted (exit ${exit_code}) at line ${line}. Fix the issue and re-run — stages are re-runnable."
}
function _cleanup() { : ; }  # nothing persistent to clean up today
trap '_on_error "$?" "${LINENO}"' ERR
trap '_cleanup' EXIT
trap 'log_error "interrupted"; exit 130' INT TERM

# ─── Helpers ──────────────────────────────────────────────────────────────────────────
function is_dry_run() { [[ "${dry_run}" == true ]]; }

# run a command, or just log it in dry-run mode
function run() {
    local IFS=' '   # join $* with spaces in logs (global IFS is \n\t); does not affect "$@"
    if is_dry_run; then log_info "[dry-run] $*"; return 0; fi
    log_debug "exec: $*"
    "$@"
}

# run a command string as the node user (login env)
function run_as_user() {
    if is_dry_run; then log_info "[dry-run] (as ${node_user}) $*"; return 0; fi
    log_debug "exec (as ${node_user}): $*"
    sudo -u "${node_user}" HOME="/home/${node_user}" bash -lc "$*"
}

# write a file from stdin (skips in dry-run)
function write_file() {
    local path="${1}"
    if is_dry_run; then log_info "[dry-run] would write ${path}"; cat >/dev/null; return 0; fi
    cat > "${path}"
    log_debug "wrote ${path}"
}

function require_root() {
    [[ "${EUID}" -eq 0 ]] || log_fatal "must run as root (use sudo)"
}

function require_cmd() {
    command -v "${1}" >/dev/null 2>&1 || log_fatal "required command not found: ${1}"
}

function user_home() { echo "/home/${node_user}"; }

# ─── Stage: prerequisites ─────────────────────────────────────────────────────────────
function stage_prereqs() {
    log_info "installing base packages and creating service user '${node_user}'"
    run apt-get update -y
    # liburing2 + libsnappy1v5: runtime shared libs cardano-node 11.x links against (LSM storage).
    run apt-get install -y curl wget jq unzip gnupg ca-certificates pv build-essential pkg-config liburing2 libsnappy1v5
    if id -u "${node_user}" >/dev/null 2>&1; then
        log_debug "user ${node_user} already exists"
    else
        run adduser --disabled-password --gecos "" "${node_user}"
    fi
}

# ─── Stage: secrets (resolve the Postgres password without hard-coding it) ─────────────
function stage_secrets() {
    if [[ -n "${db_secret}" ]]; then
        log_info "fetching Postgres password from Secrets Manager (${db_secret})"
        require_cmd aws
        if is_dry_run; then log_info "[dry-run] would read ${db_secret} from Secrets Manager"; DB_PASS="DRYRUN"; return 0; fi
        local json
        json="$(aws secretsmanager get-secret-value --region "${region}" --secret-id "${db_secret}" --query SecretString --output text)"
        DB_PASS="$(printf '%s' "${json}" | jq -r '.password // empty')"
        [[ -n "${DB_PASS}" ]] || log_fatal "secret ${db_secret} has no .password field"
    elif [[ -n "${db_password_file}" ]]; then
        log_info "reading Postgres password from ${db_password_file}"
        [[ -r "${db_password_file}" ]] || log_fatal "cannot read ${db_password_file}"
        DB_PASS="$(<"${db_password_file}")"
    else
        # No managed secret: generate once and PERSIST it, so split invocations (postgres in one
        # run, env in another) use the SAME password. Prefer --db-secret for real use.
        local pwfile="/etc/midnight/db_password"
        if is_dry_run; then
            DB_PASS="DRYRUN"
        elif [[ -f "${pwfile}" ]]; then
            log_info "reusing previously generated Postgres password (${pwfile})"
            DB_PASS="$(<"${pwfile}")"
        else
            log_warn "no --db-secret/--db-password-file given; generating and saving a password to ${pwfile}"
            require_cmd openssl
            # keep only URL/.pgpass-safe chars (drops +, /, =); cut (not head) avoids SIGPIPE under pipefail
            DB_PASS="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9._-' | cut -c1-40)"
            install -d -m 700 /etc/midnight
            printf '%s' "${DB_PASS}" > "${pwfile}"
            chmod 600 "${pwfile}"
        fi
    fi
    log_debug "Postgres password resolved (${#DB_PASS} chars)"

    # Slack: the SM secret is JSON {alerts, critical} (one webhook per channel). The health
    # checker posts to a single channel, so materialise the CRITICAL webhook for it. Alertmanager
    # reads its own two files (see monitoring/README.md).
    if [[ -n "${slack_secret}" ]]; then
        log_info "materialising the critical Slack webhook to /etc/midnight/slack_webhook (node_health_check.py)"
        if ! is_dry_run; then
            require_cmd aws
            require_cmd jq
            install -d -m 700 /etc/midnight
            aws secretsmanager get-secret-value --region "${region}" --secret-id "${slack_secret}" \
                --query SecretString --output text | jq -r '.critical // empty' > /etc/midnight/slack_webhook
            chmod 600 /etc/midnight/slack_webhook
        fi
    fi
}

# ─── Stage: Mithril snapshot (fast Cardano bootstrap) ─────────────────────────────────
function stage_mithril() {
    # Only the mithril-client is needed to download a snapshot (signer/aggregator are for
    # operating an aggregator, not for an FNO bootstrapping its Cardano DB).
    log_info "downloading Cardano ${network} DB snapshot via Mithril"
    run_as_user "mkdir -p \$HOME/tmp/mithril && cd \$HOME/tmp/mithril && \
        curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/input-output-hk/mithril/refs/heads/main/mithril-install.sh | sh -s -- -c mithril-client -d unstable -p \$(pwd) && \
        export CARDANO_NETWORK=${network} && \
        export AGGREGATOR_ENDPOINT=https://aggregator.release-${network}.api.mithril.network/aggregator && \
        export GENESIS_VERIFICATION_KEY=\$(wget -q -O - https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/release-${network}/genesis.vkey) && \
        export ANCILLARY_VERIFICATION_KEY=\$(wget -q -O - https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/release-${network}/ancillary.vkey) && \
        ./mithril-client cardano-db download --include-ancillary latest"
}

# ─── Stage: cardano-node ──────────────────────────────────────────────────────────────
function stage_cardano() {
    log_info "installing cardano-node ${CARDANO_NODE_VERSION} (checksum-verified) and its systemd service"
    if ! is_dry_run && [[ ! -d "$(user_home)/tmp/mithril/db" ]]; then
        log_warn "no Mithril snapshot at $(user_home)/tmp/mithril/db — cardano-node will sync from GENESIS"
        log_warn "(much slower; may not finish overnight). Run the 'mithril' stage first for a fast bootstrap."
    fi
    local base="cardano-node-${CARDANO_NODE_VERSION}-linux-amd64.tar.gz"
    local rel="https://github.com/IntersectMBO/cardano-node/releases/download/${CARDANO_NODE_VERSION}"
    # Download to disk, verify against the published sha256sums, then extract.
    run_as_user "mkdir -p \$HOME/.local/bin \$HOME/.local/share \$HOME/tmp && cd \$HOME/tmp && \
        curl -L -O '${rel}/${base}' && \
        curl -L -O '${rel}/cardano-node-${CARDANO_NODE_VERSION}-sha256sums.txt' && \
        sha256sum -c cardano-node-${CARDANO_NODE_VERSION}-sha256sums.txt --ignore-missing && \
        tar -xz -f '${base}' -C \$HOME/.local/bin   --strip-components=2 ./bin && \
        tar -xz -f '${base}' -C \$HOME/.local/share --strip-components=2 ./share && \
        chmod +x \$HOME/.local/bin/cardano-* && \
        mkdir -p \$HOME/cardano-data && ([ -d \$HOME/tmp/mithril/db ] && mv \$HOME/tmp/mithril/db \$HOME/cardano-data/ || true)"

    local home; home="$(user_home)"
    write_file /etc/systemd/system/cardano-node.service <<EOF
[Unit]
Description=Cardano Relay Node (${network})
Wants=network-online.target
After=network-online.target

[Service]
User=${node_user}
Type=simple
WorkingDirectory=${home}/cardano-data
ExecStart=${home}/.local/bin/cardano-node run \\
    --topology ${home}/.local/share/${network}/topology.json \\
    --database-path ${home}/cardano-data/db \\
    --socket-path ${home}/cardano-data/db/node.socket \\
    --host-addr 0.0.0.0 \\
    --port 3001 \\
    --config ${home}/.local/share/${network}/config.json
KillSignal=SIGINT
Restart=always
RestartSec=5
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
EOF
    run systemctl daemon-reload
    run systemctl enable --now cardano-node
}

# ─── Stage: PostgreSQL 17 ─────────────────────────────────────────────────────────────
function stage_postgres() {
    log_info "installing PostgreSQL ${PG_VERSION} and configuring role/db"
    run apt-get install -y curl ca-certificates
    run install -d /usr/share/postgresql-common/pgdg
    run curl -s -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
    if ! is_dry_run; then
        sh -c 'echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    fi
    run apt-get update -y
    run apt-get install -y "postgresql-${PG_VERSION}" "postgresql-server-dev-${PG_VERSION}"

    [[ -n "${DB_PASS}" ]] || stage_secrets
    if is_dry_run; then
        log_info "[dry-run] would create role 'midnight' + database 'cexplorer' and write .pgpass"
    else
        sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='midnight'" | grep -q 1 \
            || sudo -u postgres psql -c "CREATE USER midnight WITH PASSWORD '${DB_PASS}'; ALTER ROLE midnight WITH SUPERUSER CREATEDB;"
        sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='cexplorer'" | grep -q 1 \
            || sudo -u postgres psql -c "CREATE DATABASE cexplorer;"
        local home; home="$(user_home)"
        umask 077
        printf '%s\n%s\n' \
            "/var/run/postgresql:5432:cexplorer:midnight:${DB_PASS}" \
            "localhost:5432:cexplorer:midnight:${DB_PASS}" > "${home}/.pgpass"
        chown "${node_user}:${node_user}" "${home}/.pgpass"
        chmod 600 "${home}/.pgpass"
    fi

    log_info "applying pre-prod Postgres tuning"
    local conf="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
    local marker="# midnight-lab tuning"
    if ! is_dry_run && [[ -f "${conf}" ]]; then
        if grep -qF "${marker}" "${conf}"; then
            log_debug "tuning already applied; skipping"
        else
            {
                echo "${marker}"
                echo "shared_buffers = 4GB"
                echo "maintenance_work_mem = 1GB"
                echo "max_parallel_maintenance_workers = 2"
                echo "effective_cache_size = 12GB"
                echo "join_collapse_limit = 1"
            } >> "${conf}"
            run systemctl restart postgresql
        fi
    fi
}

# ─── Stage: cardano-db-sync ───────────────────────────────────────────────────────────
function stage_dbsync() {
    log_info "installing cardano-db-sync ${DBSYNC_VERSION} and its systemd service"
    log_warn "cardano-db-sync ${DBSYNC_VERSION} publishes no checksum file; this download is not checksum-verified (upstream limitation)"
    local home; home="$(user_home)"
    # The db-sync tarball ships bin/ and schema/ read-only (0555), which breaks naive re-runs:
    # tar can't overwrite into a 0555 dir, cp can't overwrite a 0555 binary, and a non-root user
    # can't rm inside a 0555 dir (chmod works as the owner regardless of the write bit, so we
    # restore write before removing). Crucially, the live cardano-data/schema is removed ONLY
    # right before the fresh copy replaces it, and only after the tarball has extracted — so a
    # failed download/extract can never leave db-sync with no schema dir to start from.
    run_as_user "mkdir -p \$HOME/tmp \$HOME/cardano-data && cd \$HOME/tmp && \
        { chmod -R u+w \$HOME/tmp/bin \$HOME/tmp/schema 2>/dev/null || true; } && rm -rf \$HOME/tmp/bin \$HOME/tmp/schema && \
        curl -L -O https://github.com/IntersectMBO/cardano-db-sync/releases/download/${DBSYNC_VERSION}/cardano-db-sync-${DBSYNC_VERSION}-linux.tar.gz && \
        tar -xzf cardano-db-sync-${DBSYNC_VERSION}-linux.tar.gz && \
        test -d \$HOME/tmp/schema && \
        cp -f bin/* \$HOME/.local/bin/ && \
        { chmod -R u+w \$HOME/cardano-data/schema 2>/dev/null || true; } && rm -rf \$HOME/cardano-data/schema && \
        cp -a \$HOME/tmp/schema \$HOME/cardano-data/ && chmod -R u+w \$HOME/cardano-data/schema && \
        cd \$HOME/cardano-data && curl -O https://book.world.dev.cardano.org/environments/${network}/db-sync-config.json && \
        sed -i 's|\"NodeConfigFile\": \"config.json\"|\"NodeConfigFile\": \"${home}/.local/share/${network}/config.json\"|' \$HOME/cardano-data/db-sync-config.json"

    write_file /etc/systemd/system/cardano-db-sync.service <<EOF
[Unit]
Description=Cardano DB Sync (${network})
After=cardano-node.service
Requires=cardano-node.service

[Service]
User=${node_user}
Type=simple
Environment="PGPASSFILE=${home}/.pgpass"
WorkingDirectory=${home}/cardano-data
ExecStart=${home}/.local/bin/cardano-db-sync \\
    --config ${home}/cardano-data/db-sync-config.json \\
    --socket-path ${home}/cardano-data/db/node.socket \\
    --schema-dir ${home}/cardano-data/schema \\
    --state-dir ${home}/cardano-data/db-sync-state
KillSignal=SIGINT
Restart=always
RestartSec=10
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
EOF
    run systemctl daemon-reload
    run systemctl enable --now cardano-db-sync
    log_warn "db-sync may sit idle 5-20 min before rows appear; full sync takes hours"
}

# ─── Stage: verify sync (report lag, optionally wait) ─────────────────────────────────
# Readiness is measured by how far db-sync's latest block trails the live chain, NOT by a
# time-weighted "percent". On a chain that is years old, a time ratio rounds to 100% while the
# DB is still a full day behind — useless as a gate. Lag-in-seconds does not saturate: it only
# reaches ~0 when db-sync has actually caught up to the tip.

function _magic_arg() {
    case "${network}" in
        mainnet) echo "--mainnet" ;;
        preprod) echo "--testnet-magic 1" ;;
        preview) echo "--testnet-magic 2" ;;
        *)       echo "--testnet-magic 1" ;;
    esac
}

# cardano-node's own tip as JSON (block/slot/syncProgress); empty if the socket isn't up yet.
function _node_tip_json() {
    local sock; sock="$(user_home)/cardano-data/db/node.socket"
    [[ -S "${sock}" ]] || return 1
    # shellcheck disable=SC2046
    sudo -u "${node_user}" bash -lc "CARDANO_NODE_SOCKET_PATH='${sock}' '$(user_home)/.local/bin/cardano-cli' query tip $(_magic_arg)" 2>/dev/null
}

# db-sync's latest block number in cexplorer (0 if no rows yet).
function _dbsync_block() {
    sudo -u "${node_user}" psql -d cexplorer -tAc "SELECT COALESCE(max(block_no),0) FROM block;" 2>/dev/null | tr -d ' '
}

# Seconds db-sync's latest block trails wall-clock (a huge sentinel if the table is empty).
function _sync_lag_seconds() {
    sudo -u "${node_user}" psql -d cexplorer -tAc \
        "SELECT COALESCE(EXTRACT(epoch FROM (now() - max(time)))::bigint, 999999999) FROM block;" 2>/dev/null | tr -d ' '
}

# Pretty-print a seconds count as HhMMmSSs.
function _fmt_lag() { local s="${1:-0}"; printf '%dh%02dm%02ds' "$((s/3600))" "$(((s%3600)/60))" "$((s%60))"; }

function _report_sync() {
    local node_json; node_json="$(_node_tip_json || true)"
    if [[ -n "${node_json}" ]]; then
        log_info "cardano-node: syncProgress $(printf '%s' "${node_json}" | jq -r '.syncProgress // "?"')% (tip block $(printf '%s' "${node_json}" | jq -r '.block // "?"'))"
    else
        log_warn "cardano-node socket not ready (still replaying?) — cannot read node tip yet"
    fi
    local lag; lag="$(_sync_lag_seconds || echo 999999999)"; lag="${lag:-999999999}"
    log_info "cardano-db-sync: latest block $(_dbsync_block), $(_fmt_lag "${lag}") behind tip"
}

function stage_verify_sync() {
    if is_dry_run; then log_info "[dry-run] would report node syncProgress + db-sync lag"; return 0; fi
    _report_sync
    if [[ "${wait_sync}" == true ]]; then
        local lag; lag="$(_sync_lag_seconds || echo 999999999)"; lag="${lag:-999999999}"
        while (( lag > max_lag_seconds )); do
            log_info "waiting for db-sync lag <= ${max_lag_seconds}s (currently $(_fmt_lag "${lag}")) ..."
            sleep 120
            lag="$(_sync_lag_seconds || echo 999999999)"; lag="${lag:-999999999}"
        done
        log_info "db-sync caught up (lag $(_fmt_lag "${lag}"))"
    fi
}

# ─── Stage: midnight-node binary ──────────────────────────────────────────────────────
function stage_midnight() {
    log_info "installing midnight-node ${MIDNIGHT_NODE_VERSION}"
    # Do NOT pre-create \$HOME/res: 'mv tmp/res \$HOME/res' into an existing dir would nest to
    # \$HOME/res/res and break --chain \$HOME/res/${network}/... . rm+mv keeps it idempotent.
    local rel="https://github.com/midnightntwrk/midnight-node/releases/download/node-${MIDNIGHT_NODE_VERSION}"
    # Verify the binary that will hold the validator keys before extracting it.
    run_as_user "mkdir -p \$HOME/data \$HOME/.local/bin \$HOME/tmp && cd \$HOME/tmp && \
        curl -L -O '${rel}/midnight-node-${MIDNIGHT_NODE_VERSION}-linux-amd64.tar.gz' && \
        curl -L -O '${rel}/SHA256SUMS-amd64' && \
        sha256sum -c SHA256SUMS-amd64 --ignore-missing && \
        tar -xvzf midnight-node-${MIDNIGHT_NODE_VERSION}-linux-amd64.tar.gz && \
        mv -f \$HOME/tmp/midnight-node \$HOME/.local/bin/midnight-node && \
        rm -rf \$HOME/res && mv \$HOME/tmp/res \$HOME/res"
}

# ─── Stage: validator keys ────────────────────────────────────────────────────────────
function stage_keys() {
    log_info "generating validator keys, keystore, and registration file"
    # midnight-node's `key` subcommands load the chain config, so they need CFG_PRESET set and must
    # run from \$HOME — the preset toml (res/cfg/${network}.toml) references genesis via RELATIVE
    # paths (res/genesis/...), resolved from the cwd. Without both: "chainspec_genesis_block not
    # configured".
    run_as_user "cd \$HOME && export CFG_PRESET=${network} && \
        \$HOME/.local/bin/midnight-node key generate --scheme sr25519 --output-type json > aura.json && \
        \$HOME/.local/bin/midnight-node key generate --scheme ed25519 --output-type json > grandpa.json && \
        \$HOME/.local/bin/midnight-node key generate --scheme ecdsa   --output-type json > cross_chain.json && \
        chmod 600 aura.json grandpa.json cross_chain.json && \
        NETWORK_DIR=\$HOME/data/chains/midnight_${network}/network && mkdir -p \$NETWORK_DIR && chmod 700 \$NETWORK_DIR && \
        \$HOME/.local/bin/midnight-node key generate-node-key --file \$NETWORK_DIR/secret_ed25519"

    run_as_user "cd \$HOME && export CFG_PRESET=${network} && \
        KEYSTORE=\$HOME/data/chains/midnight_${network}/keystore && mkdir -p \$KEYSTORE && \
        \$HOME/.local/bin/midnight-node key insert --keystore-path \$KEYSTORE --scheme sr25519 --key-type aura --suri \"\$(jq -r .secretPhrase \$HOME/aura.json)\" && \
        \$HOME/.local/bin/midnight-node key insert --keystore-path \$KEYSTORE --scheme ed25519 --key-type gran --suri \"\$(jq -r .secretPhrase \$HOME/grandpa.json)\" && \
        \$HOME/.local/bin/midnight-node key insert --keystore-path \$KEYSTORE --scheme ecdsa   --key-type beef --suri \"\$(jq -r .secretPhrase \$HOME/cross_chain.json)\""

    run_as_user "cat > \$HOME/partner-chains-public-keys.json <<EOF
{
  \"partner_chains_key\": \"\$(jq -r .publicKey \$HOME/cross_chain.json)\",
  \"keys\": {
    \"aura\": \"\$(jq -r .publicKey \$HOME/aura.json)\",
    \"crch\": \"\$(jq -r .publicKey \$HOME/cross_chain.json)\",
    \"gran\": \"\$(jq -r .publicKey \$HOME/grandpa.json)\"
  }
}
EOF"
    log_warn "back up aura.json/grandpa.json/cross_chain.json offline; submit partner-chains-public-keys.json to the Foundation (public keys only)"
}

# ─── Stage: .env ──────────────────────────────────────────────────────────────────────
function stage_env() {
    # The docs' AURA/GRANDPA/CROSS_CHAIN *_SEED_FILE entries are intentionally omitted: the
    # node loads session keys from the keystore under --base-path (see RUNBOOK §5.1.2 gotcha).
    log_info "writing ${node_user} .env"
    [[ -n "${DB_PASS}" ]] || stage_secrets
    local home; home="$(user_home)"
    if is_dry_run; then log_info "[dry-run] would write ${home}/.env"; return 0; fi
    umask 077
    write_file "${home}/.env" <<EOF
POSTGRES_HOST='localhost'
POSTGRES_DB='cexplorer'
POSTGRES_PORT=5432
POSTGRES_USER='midnight'
POSTGRES_PASSWORD='${DB_PASS}'
DB_SYNC_POSTGRES_CONNECTION_STRING=postgresql://midnight:${DB_PASS}@localhost:5432/cexplorer
CARDANO_SECURITY_PARAMETER='432'
BLOCK_STABILITY_MARGIN=30
PROMETHEUS_PUSH_ENDPOINT='https://telemetry.shielded.tools/api/v1/receive'
CFG_PRESET=${network}
NODE_NAME='${node_name}'
NODE_KEY_FILE='${home}/data/chains/midnight_${network}/network/secret_ed25519'
EOF
    chown "${node_user}:${node_user}" "${home}/.env"
    chmod 600 "${home}/.env"
}

# ─── Stage: midnight validator service ────────────────────────────────────────────────
function stage_service() {
    local home; home="$(user_home)"
    if [[ "${wait_sync}" != true ]] && ! is_dry_run; then
        local lag; lag="$(_sync_lag_seconds || echo 999999999)"; lag="${lag:-999999999}"
        if (( lag > max_lag_seconds )); then
            log_warn "db-sync lag $(_fmt_lag "${lag}") (> ${max_lag_seconds}s). Writing the unit but NOT starting the validator yet."
            log_warn "re-run '--stage service --wait-sync' (or start manually) once db-sync catches up."
        fi
    fi
    log_info "installing midnight-node validator service"
    write_file /etc/systemd/system/midnight-node.service <<EOF
[Unit]
Description=Midnight Protocol Node (${network} FNO)
After=network.target postgresql.service
Wants=postgresql.service

[Service]
User=${node_user}
Group=${node_user}
Type=simple
WorkingDirectory=${home}
EnvironmentFile=${home}/.env
ExecStart=${home}/.local/bin/midnight-node \\
    --chain ${home}/res/${network}/chain-spec-raw.json \\
    --base-path ${home}/data \\
    --telemetry-url 'wss://telemetry.shielded.tools./submit 1' \\
    --validator \\
    --pool-limit 35 \\
    --name \${NODE_NAME} \\
    --rpc-port 9933 \\
    --prometheus-external --prometheus-port 9615
Restart=on-failure
RestartSec=10
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    run systemctl daemon-reload
    run systemctl enable midnight-node
    local lag
    if is_dry_run; then
        lag=0
    else
        lag="$(_sync_lag_seconds || echo 999999999)"
    fi
    lag="${lag:-999999999}"
    if (( lag <= max_lag_seconds )) || [[ "${wait_sync}" == true ]]; then
        run systemctl start midnight-node
    fi
}

# ─── Stage: verify ────────────────────────────────────────────────────────────────────
function stage_verify() {
    if is_dry_run; then log_info "[dry-run] would check journalctl for keys/Best:#"; return 0; fi
    log_info "recent midnight-node logs (keys loaded + block progression):"
    journalctl -u midnight-node -n 40 --no-pager 2>/dev/null | grep -Ei 'AURA pubkey|GRANDPA pubkey|CROSS_CHAIN pubkey|Best:|Imported|Postgres' || \
        log_warn "no matching log lines yet — the node may still be starting or waiting on db-sync"
    log_info "note: a fresh FNO stays passive until Foundation authorisation + the n+2 epoch (see RUNBOOK §5.4)"
}

# ─── Orchestration ────────────────────────────────────────────────────────────────────
function run_stage() {
    case "${1}" in
        prereqs)     stage_prereqs ;;
        secrets)     stage_secrets ;;
        mithril)     stage_mithril ;;
        cardano)     stage_cardano ;;
        postgres)    stage_postgres ;;
        dbsync)      stage_dbsync ;;
        verify-sync) stage_verify_sync ;;
        midnight)    stage_midnight ;;
        keys)        stage_keys ;;
        env)         stage_env ;;
        service)     stage_service ;;
        verify)      stage_verify ;;
        *)           log_fatal "unknown stage: ${1}" ;;
    esac
}

function usage() {
    cat <<EOF
${SCRIPT_NAME} v${VERSION} — automate Midnight ${network} FNO setup (see RUNBOOK.md)

Usage: sudo ${SCRIPT_NAME} [options]

Options:
  --stage LIST         Comma-separated stages, or 'all' (default). Stages, in order:
                       $(IFS=' '; echo "${ALL_STAGES[*]}")
  --db-secret NAME     AWS Secrets Manager secret with {"password": ...} (preferred)
  --db-password-file F Read the Postgres password from a file instead
  --slack-secret NAME  Secrets Manager id of the {alerts,critical} webhooks JSON; the critical
                       webhook is materialised to /etc/midnight/slack_webhook (0600) for the health checker
  --region REGION      AWS region for Secrets Manager (default: ${region})
  --user USER          Service user (default: ${node_user})
  --network NET        Midnight network (default: ${network})
  --node-name NAME     Telemetry node name (default: ${node_name})
  --wait-sync          Block until db-sync lag <= --max-lag-seconds before starting the validator
  --max-lag-seconds N  Max db-sync lag behind the chain tip to start the validator (default: ${max_lag_seconds})
  --dry-run            Log every action without executing anything
  -v, --verbose        DEBUG logging
  --no-color           Disable coloured logs (also honours NO_COLOR)
  -h, --help           Show this help
  -V, --version        Show version

Examples:
  sudo ${SCRIPT_NAME} --dry-run
  sudo ${SCRIPT_NAME} --stage prereqs,secrets,mithril,cardano,postgres,dbsync --db-secret midnight-validator-lab-preprod/postgres
  sudo ${SCRIPT_NAME} --stage service --wait-sync
EOF
}

function parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --stage)             stages_csv="${2}"; shift 2 ;;
            --db-secret)         db_secret="${2}"; shift 2 ;;
            --db-password-file)  db_password_file="${2}"; shift 2 ;;
            --slack-secret)      slack_secret="${2}"; shift 2 ;;
            --region)            region="${2}"; shift 2 ;;
            --user)              node_user="${2}"; shift 2 ;;
            --network)           network="${2}"; shift 2 ;;
            --node-name)         node_name="${2}"; shift 2 ;;
            --wait-sync)         wait_sync=true; shift ;;
            --max-lag-seconds)   max_lag_seconds="${2}"; shift 2 ;;
            --dry-run)           dry_run=true; shift ;;
            -v|--verbose)        current_log_level="${LOG_LEVEL_DEBUG}"; shift ;;
            --no-color)          no_color=true; shift ;;
            -h|--help)           usage; exit 0 ;;
            -V|--version)        echo "${SCRIPT_NAME} ${VERSION}"; exit 0 ;;
            *)                   log_error "unknown option: ${1}"; usage; exit 1 ;;
        esac
    done
}

function main() {
    parse_arguments "$@"
    setup_colors
    require_root

    local -a stages
    if [[ "${stages_csv}" == "all" ]]; then
        stages=("${ALL_STAGES[@]}")
    else
        IFS=',' read -r -a stages <<< "${stages_csv}"
    fi

    log_info "starting ${SCRIPT_NAME} v${VERSION} (network=${network}, user=${node_user}, dry_run=${dry_run})"
    log_info "stages: $(IFS=' '; echo "${stages[*]}")"
    is_dry_run && log_warn "DRY-RUN: no changes will be made"

    for stage in "${stages[@]}"; do
        log_info "── stage: ${stage} ──"
        run_stage "${stage}"
    done

    log_info "done."
}

main "$@"
