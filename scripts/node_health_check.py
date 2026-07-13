#!/usr/bin/env python3
"""Midnight pre-prod node health checker.

Polls a Midnight (Substrate) node's JSON-RPC endpoint, evaluates a set of health
conditions, writes a structured JSON report to disk, and diffs the new report against
the previous one to surface regressions.

Design goals:
  * Dependency-free — standard library only, so it runs on a fresh node with no pip.
  * Re-runnable / idempotent — always overwrites ``latest.json`` and appends a
    timestamped copy under ``history/``; safe to run from cron or a systemd timer.
  * Actionable exit codes — 0 healthy, 1 degraded or regressed, 2 unreachable — so it
    composes with alerting/monitoring.

Usage:
    ./node_health_check.py                          # one-shot against localhost:9933
    ./node_health_check.py --once --rpc-url http://localhost:9933
    ./node_health_check.py --interval 60            # poll every 60s until Ctrl-C
    ./node_health_check.py --min-peers 3 --max-sync-gap 5 --report-dir ./health-reports

    # Daemon mode with Slack alerts (webhook kept out of argv via a file or env var):
    ./node_health_check.py --interval 60 --slack-webhook-file /etc/midnight/slack_webhook
    SLACK_WEBHOOK_URL=https://hooks.slack.com/services/... ./node_health_check.py --interval 60
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

# ── Constants ───────────────────────────────────────────────────────────────────────
DEFAULT_RPC_URL = "http://localhost:9933"
DEFAULT_REPORT_DIR = "./health-reports"
DEFAULT_MIN_PEERS = 3
DEFAULT_MAX_SYNC_GAP = 5
DEFAULT_TIMEOUT = 10
SLACK_WEBHOOK_ENV = "SLACK_WEBHOOK_URL"

STATUS_HEALTHY = "HEALTHY"
STATUS_DEGRADED = "DEGRADED"
STATUS_UNREACHABLE = "UNREACHABLE"

EXIT_OK = 0
EXIT_DEGRADED = 1
EXIT_UNREACHABLE = 2


# ── Logging ─────────────────────────────────────────────────────────────────────────
LOG = logging.getLogger("healthcheck")

# ANSI colours, applied per level. Auto-disabled when not a TTY or NO_COLOR is set.
_RESET = "\033[0m"
_LEVEL_COLORS = {
    logging.DEBUG: "\033[90m",       # grey
    logging.INFO: "\033[32m",        # green
    logging.WARNING: "\033[33m",     # yellow
    logging.ERROR: "\033[31m",       # red
    logging.CRITICAL: "\033[1;31m",  # bold red
}


class ColorFormatter(logging.Formatter):
    """Formatter that colourises the whole line by log level when enabled."""

    def __init__(self, *args: object, use_color: bool = False, **kwargs: object) -> None:
        super().__init__(*args, **kwargs)
        self.use_color = use_color

    def format(self, record: logging.LogRecord) -> str:
        line = super().format(record)
        if self.use_color:
            return f"{_LEVEL_COLORS.get(record.levelno, '')}{line}{_RESET}"
        return line


def setup_logging(verbose: bool = False, no_color: bool = False) -> None:
    """Configure the module logger: timestamp + level, colour on a TTY.

    Logs go to stdout so existing `... | tee report.txt` pipelines still capture them;
    colour is suppressed automatically when stdout is not a terminal (or NO_COLOR is set),
    so redirected/tee'd files stay clean.
    """
    # Short, aligned level names: DEBUG/INFO/WARN/ERROR/CRIT all fit 5 columns.
    logging.addLevelName(logging.WARNING, "WARN")
    logging.addLevelName(logging.CRITICAL, "CRIT")

    use_color = (
        not no_color
        and os.environ.get("NO_COLOR") is None
        and sys.stdout.isatty()
    )
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(
        ColorFormatter(
            fmt="%(asctime)s %(levelname)-5s %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
            use_color=use_color,
        )
    )
    LOG.setLevel(logging.DEBUG if verbose else logging.INFO)
    LOG.handlers.clear()
    LOG.addHandler(handler)
    LOG.propagate = False


# ── Data model ──────────────────────────────────────────────────────────────────────
@dataclass
class Check:
    """A single named health condition and its outcome."""

    name: str
    ok: bool
    detail: str


@dataclass
class Report:
    """A full health snapshot, serialised to JSON on disk."""

    timestamp: str
    target: str
    reachable: bool
    status: str
    node: dict = field(default_factory=dict)
    metrics: dict = field(default_factory=dict)
    checks: list[Check] = field(default_factory=list)
    regressions: list[str] = field(default_factory=list)


# ── JSON-RPC client ─────────────────────────────────────────────────────────────────
class RpcError(Exception):
    """Raised when the RPC endpoint is unreachable or returns an error."""


def rpc_call(rpc_url: str, method: str, timeout: int) -> object:
    """Invoke a single Substrate JSON-RPC method and return its ``result``.

    Raises RpcError on transport failure, HTTP error, or a JSON-RPC error object.
    """
    payload = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": method, "params": []}
    ).encode()
    request = urllib.request.Request(
        rpc_url, data=payload, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = json.loads(response.read().decode())
    except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
        raise RpcError(f"{method}: transport error: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise RpcError(f"{method}: invalid JSON response: {exc}") from exc

    if "error" in body:
        raise RpcError(f"{method}: rpc error: {body['error']}")
    return body.get("result")


def _as_int(value: object) -> int | None:
    """Coerce a Substrate numeric field (int or hex string like '0x1a') to int."""
    if isinstance(value, bool):  # bool is an int subclass — guard against it
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value, 16) if value.startswith("0x") else int(value)
        except ValueError:
            return None
    return None


# ── Health evaluation ───────────────────────────────────────────────────────────────
def build_report(args: argparse.Namespace) -> Report:
    """Query the node and assemble a Report (without regression diffing)."""
    now = datetime.now(timezone.utc).isoformat()

    # First probe also tells us whether the node is reachable at all.
    try:
        health = rpc_call(args.rpc_url, "system_health", args.timeout)
    except RpcError as exc:
        report = Report(
            timestamp=now,
            target=args.rpc_url,
            reachable=False,
            status=STATUS_UNREACHABLE,
        )
        report.checks.append(Check("rpc_reachable", False, str(exc)))
        return report

    # Best-effort enrichment; individual failures must not abort the whole report.
    sync_state: dict = {}
    version = chain = None
    try:
        sync_state = rpc_call(args.rpc_url, "system_syncState", args.timeout) or {}
    except RpcError:
        sync_state = {}
    try:
        version = rpc_call(args.rpc_url, "system_version", args.timeout)
    except RpcError:
        version = None
    try:
        chain = rpc_call(args.rpc_url, "system_chain", args.timeout)
    except RpcError:
        chain = None

    peers = _as_int(health.get("peers")) if isinstance(health, dict) else None
    is_syncing = bool(health.get("isSyncing")) if isinstance(health, dict) else None
    should_have_peers = (
        bool(health.get("shouldHavePeers")) if isinstance(health, dict) else None
    )
    current_block = _as_int(sync_state.get("currentBlock"))
    highest_block = _as_int(sync_state.get("highestBlock"))
    sync_gap = (
        highest_block - current_block
        if current_block is not None and highest_block is not None
        else None
    )

    report = Report(
        timestamp=now,
        target=args.rpc_url,
        reachable=True,
        status=STATUS_HEALTHY,
        node={"version": version, "chain": chain},
        metrics={
            "peers": peers,
            "is_syncing": is_syncing,
            "should_have_peers": should_have_peers,
            "current_block": current_block,
            "highest_block": highest_block,
            "sync_gap": sync_gap,
        },
    )

    # ── Health conditions ──
    report.checks.append(Check("rpc_reachable", True, "RPC responded"))

    if peers is None:
        report.checks.append(Check("peer_count", False, "peer count unavailable"))
    else:
        report.checks.append(
            Check(
                "peer_count",
                peers >= args.min_peers,
                f"{peers} peers (min {args.min_peers})",
            )
        )

    if should_have_peers and peers == 0:
        report.checks.append(
            Check("network_connected", False, "node expects peers but has 0")
        )

    if sync_gap is None:
        report.checks.append(
            Check("sync_gap", False, "sync state unavailable")
        )
    else:
        report.checks.append(
            Check(
                "sync_gap",
                sync_gap <= args.max_sync_gap,
                f"{sync_gap} blocks behind tip (max {args.max_sync_gap})",
            )
        )

    # A node that is up but reports no block height at all is unhealthy.
    report.checks.append(
        Check(
            "has_block_height",
            current_block is not None and current_block > 0,
            f"current_block={current_block}",
        )
    )

    if any(not c.ok for c in report.checks):
        report.status = STATUS_DEGRADED
    return report


# ── Persistence + regression diffing ────────────────────────────────────────────────
def load_previous(report_dir: Path) -> dict | None:
    """Load the previous ``latest.json`` if present, else None."""
    latest = report_dir / "latest.json"
    if not latest.is_file():
        return None
    try:
        return json.loads(latest.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def diff_regressions(previous: dict | None, current: Report) -> list[str]:
    """Compare the current report against the previous one and list regressions."""
    if previous is None:
        return []

    regressions: list[str] = []

    # Overall status got worse.
    rank = {STATUS_HEALTHY: 0, STATUS_DEGRADED: 1, STATUS_UNREACHABLE: 2}
    prev_status = previous.get("status", STATUS_HEALTHY)
    if rank.get(current.status, 0) > rank.get(prev_status, 0):
        regressions.append(f"status worsened: {prev_status} -> {current.status}")

    # A check that used to pass now fails.
    prev_checks = {c["name"]: c["ok"] for c in previous.get("checks", [])}
    for check in current.checks:
        if prev_checks.get(check.name) is True and not check.ok:
            regressions.append(f"check regressed: {check.name} ({check.detail})")

    # Block height stalled or went backwards (only meaningful if both present).
    prev_block = (previous.get("metrics") or {}).get("current_block")
    cur_block = current.metrics.get("current_block")
    if isinstance(prev_block, int) and isinstance(cur_block, int):
        if cur_block < prev_block:
            regressions.append(
                f"block height went backwards: {prev_block} -> {cur_block}"
            )
        elif cur_block == prev_block and current.reachable:
            regressions.append(
                f"block height did not advance since last check (stuck at {cur_block})"
            )

    # Peer count dropped.
    prev_peers = (previous.get("metrics") or {}).get("peers")
    cur_peers = current.metrics.get("peers")
    if isinstance(prev_peers, int) and isinstance(cur_peers, int) and cur_peers < prev_peers:
        regressions.append(f"peer count dropped: {prev_peers} -> {cur_peers}")

    return regressions


def write_report(report_dir: Path, report: Report) -> Path:
    """Persist the report as latest.json and a timestamped history file."""
    report_dir.mkdir(parents=True, exist_ok=True)
    history_dir = report_dir / "history"
    history_dir.mkdir(exist_ok=True)

    payload = asdict(report)
    safe_ts = report.timestamp.replace(":", "").replace("+00:00", "Z")
    history_file = history_dir / f"health-{safe_ts}.json"
    history_file.write_text(json.dumps(payload, indent=2))
    (report_dir / "latest.json").write_text(json.dumps(payload, indent=2))
    return history_file


# ── Presentation ────────────────────────────────────────────────────────────────────
def log_summary(report: Report) -> None:
    """Log a concise summary at a level matching the node's status.

    Overall status is logged at INFO (healthy) / WARN (degraded) / ERROR (unreachable).
    Passing checks are DEBUG (shown with --verbose); failing checks and regressions are WARN.
    """
    level = {
        STATUS_HEALTHY: logging.INFO,
        STATUS_DEGRADED: logging.WARNING,
        STATUS_UNREACHABLE: logging.ERROR,
    }.get(report.status, logging.INFO)

    if report.reachable:
        m = report.metrics
        LOG.log(
            level,
            "%s %s peers=%s best=%s tip=%s gap=%s syncing=%s",
            report.status, report.target, m.get("peers"), m.get("current_block"),
            m.get("highest_block"), m.get("sync_gap"), m.get("is_syncing"),
        )
    else:
        LOG.log(level, "%s %s (unreachable)", report.status, report.target)

    for check in report.checks:
        if check.ok:
            LOG.debug("check ok   %s: %s", check.name, check.detail)
        else:
            LOG.warning("check FAIL %s: %s", check.name, check.detail)
    for reg in report.regressions:
        LOG.warning("regression: %s", reg)


# ── Slack notification ───────────────────────────────────────────────────────────────
def resolve_slack_webhook(args: argparse.Namespace) -> str | None:
    """Resolve the Slack webhook URL from flag, file, or environment (in that order)."""
    if args.slack_webhook_url:
        return args.slack_webhook_url.strip()
    if args.slack_webhook_file:
        try:
            return Path(args.slack_webhook_file).read_text().strip()
        except OSError as exc:
            LOG.error("cannot read slack webhook file: %s", exc)
            return None
    env = os.environ.get(SLACK_WEBHOOK_ENV)
    return env.strip() if env else None


def should_notify(previous: dict | None, report: Report) -> bool:
    """Decide whether to send a Slack message this cycle.

    Notify on fresh regressions or any status transition (including recovery). A steady
    HEALTHY or steady DEGRADED state does not re-notify, which keeps a polling daemon from
    spamming every interval. A first run that is already healthy stays silent.
    """
    if report.regressions:
        return True
    prev_status = previous.get("status") if previous else None
    if prev_status is None:
        return report.status != STATUS_HEALTHY
    return prev_status != report.status


def post_slack(webhook_url: str, report: Report, timeout: int) -> None:
    """Post a health summary to a Slack incoming webhook. Never raises."""
    tag = {
        STATUS_HEALTHY: ":white_check_mark:",
        STATUS_DEGRADED: ":warning:",
        STATUS_UNREACHABLE: ":red_circle:",
    }
    lines = [f"{tag.get(report.status, '')} *Midnight node {report.status}* — `{report.target}`"]
    if report.reachable:
        m = report.metrics
        lines.append(
            f"peers={m.get('peers')} best={m.get('current_block')} "
            f"tip={m.get('highest_block')} gap={m.get('sync_gap')}"
        )
    for check in (c for c in report.checks if not c.ok):
        lines.append(f"• FAIL {check.name}: {check.detail}")
    for reg in report.regressions:
        lines.append(f"• regression: {reg}")

    payload = json.dumps({"text": "\n".join(lines)}).encode()
    request = urllib.request.Request(
        webhook_url, data=payload, headers={"Content-Type": "application/json"}
    )
    try:
        urllib.request.urlopen(request, timeout=timeout)
        LOG.info("posted %s alert to Slack", report.status)
    except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
        LOG.warning("slack notification failed: %s", exc)


def run_once(args: argparse.Namespace) -> int:
    """Execute a single health check cycle and return the process exit code."""
    report_dir = Path(args.report_dir)
    previous = load_previous(report_dir)
    report = build_report(args)
    report.regressions = diff_regressions(previous, report)
    history_file = write_report(report_dir, report)
    LOG.debug("report written to %s", history_file)
    log_summary(report)

    webhook = resolve_slack_webhook(args)
    if webhook and (args.slack_notify_healthy or should_notify(previous, report)):
        post_slack(webhook, report, args.timeout)

    if not report.reachable:
        return EXIT_UNREACHABLE
    if report.status != STATUS_HEALTHY or report.regressions:
        return EXIT_DEGRADED
    return EXIT_OK


# ── Entry point ─────────────────────────────────────────────────────────────────────
def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Health-check a Midnight pre-prod node and report regressions."
    )
    parser.add_argument("--rpc-url", default=DEFAULT_RPC_URL, help="Substrate JSON-RPC URL")
    parser.add_argument("--report-dir", default=DEFAULT_REPORT_DIR, help="Output directory")
    parser.add_argument("--min-peers", type=int, default=DEFAULT_MIN_PEERS)
    parser.add_argument("--max-sync-gap", type=int, default=DEFAULT_MAX_SYNC_GAP)
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="RPC timeout (s)")
    parser.add_argument(
        "--interval",
        type=int,
        default=0,
        help="Poll every N seconds until interrupted (0 = run once)",
    )
    parser.add_argument("--once", action="store_true", help="Force a single run")
    parser.add_argument(
        "--slack-webhook-url",
        default=None,
        help=f"Slack incoming webhook URL (prefer --slack-webhook-file or ${SLACK_WEBHOOK_ENV})",
    )
    parser.add_argument(
        "--slack-webhook-file",
        default=None,
        help="File holding the Slack webhook URL (keeps it out of argv/env/history)",
    )
    parser.add_argument(
        "--slack-notify-healthy",
        action="store_true",
        help="Also post to Slack on healthy runs (heartbeat); default posts only on problems/changes",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="Log passing checks too (DEBUG)")
    parser.add_argument(
        "--no-color", action="store_true", help="Disable coloured log output (also honours NO_COLOR)"
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    setup_logging(verbose=args.verbose, no_color=args.no_color)

    if args.interval <= 0 or args.once:
        return run_once(args)

    # Continuous mode: keep the last exit code, loop until interrupted.
    LOG.info("polling %s every %ds (Ctrl-C to stop)", args.rpc_url, args.interval)
    last_code = EXIT_OK
    try:
        while True:
            last_code = run_once(args)
            time.sleep(args.interval)
    except KeyboardInterrupt:
        LOG.info("interrupted")
    return last_code


if __name__ == "__main__":
    sys.exit(main())
