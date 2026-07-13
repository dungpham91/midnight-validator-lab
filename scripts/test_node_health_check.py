"""Unit tests for node_health_check.py (pytest + stdlib only)."""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import SimpleNamespace

import node_health_check as hc


def _args(rpc_url, **kw):
    base = {
        "rpc_url": rpc_url,
        "timeout": 5,
        "min_peers": 3,
        "max_sync_gap": 5,
        "slack_webhook_url": None,
        "slack_webhook_file": None,
    }
    base.update(kw)
    return SimpleNamespace(**base)


def _report(status="HEALTHY", reachable=True, metrics=None, checks=None):
    report = hc.Report(timestamp="t", target="x", reachable=reachable, status=status)
    report.metrics = metrics or {}
    report.checks = checks or []
    return report


# ── _as_int ───────────────────────────────────────────────────────────────────────────
def test_as_int_variants():
    assert hc._as_int(42) == 42
    assert hc._as_int("0x1a") == 26
    assert hc._as_int("42") == 42
    assert hc._as_int(True) is None  # bool is not a valid numeric here
    assert hc._as_int("nope") is None
    assert hc._as_int(None) is None


# ── diff_regressions ──────────────────────────────────────────────────────────────────
def test_diff_none_previous_has_no_regressions():
    assert hc.diff_regressions(None, _report()) == []


def test_diff_status_worsened():
    prev = {"status": "HEALTHY", "checks": [], "metrics": {}}
    regs = hc.diff_regressions(prev, _report(status="DEGRADED"))
    assert any("status worsened" in r for r in regs)


def test_diff_check_regression_stall_and_peer_drop():
    prev = {
        "status": "HEALTHY",
        "checks": [{"name": "peer_count", "ok": True}],
        "metrics": {"current_block": 100, "peers": 8},
    }
    cur = _report(
        status="DEGRADED",
        metrics={"current_block": 100, "peers": 2},
        checks=[hc.Check("peer_count", False, "2 peers")],
    )
    regs = hc.diff_regressions(prev, cur)
    assert any("check regressed: peer_count" in r for r in regs)
    assert any("did not advance" in r for r in regs)
    assert any("peer count dropped" in r for r in regs)


def test_diff_block_went_backwards():
    prev = {"status": "HEALTHY", "checks": [], "metrics": {"current_block": 200}}
    regs = hc.diff_regressions(prev, _report(metrics={"current_block": 150}))
    assert any("backwards" in r for r in regs)


# ── should_notify ─────────────────────────────────────────────────────────────────────
def test_should_notify_rules():
    # first run, healthy -> stay quiet
    assert hc.should_notify(None, _report(status="HEALTHY")) is False
    # first run, unreachable -> notify
    assert hc.should_notify(None, _report(status="UNREACHABLE", reachable=False)) is True
    # regressions present -> notify
    regressed = _report()
    regressed.regressions = ["peer count dropped: 8 -> 2"]
    assert hc.should_notify({"status": "HEALTHY"}, regressed) is True
    # status transition -> notify
    assert hc.should_notify({"status": "HEALTHY"}, _report(status="DEGRADED")) is True
    # steady healthy -> quiet
    assert hc.should_notify({"status": "HEALTHY"}, _report(status="HEALTHY")) is False


# ── resolve_slack_webhook ─────────────────────────────────────────────────────────────
def test_resolve_slack_webhook_precedence(tmp_path, monkeypatch):
    monkeypatch.delenv(hc.SLACK_WEBHOOK_ENV, raising=False)
    flag = _args("x", slack_webhook_url="from-flag")
    assert hc.resolve_slack_webhook(flag) == "from-flag"

    wh = tmp_path / "wh"
    wh.write_text("from-file\n")
    from_file = _args("x", slack_webhook_file=str(wh))
    assert hc.resolve_slack_webhook(from_file) == "from-file"

    monkeypatch.setenv(hc.SLACK_WEBHOOK_ENV, "from-env")
    assert hc.resolve_slack_webhook(_args("x")) == "from-env"


# ── build_report against a mock RPC server ────────────────────────────────────────────
class _MockRpcHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        method = json.loads(self.rfile.read(length))["method"]
        result = {
            "system_health": {"peers": 9, "isSyncing": False, "shouldHavePeers": True},
            "system_syncState": {"startingBlock": 0, "currentBlock": 500, "highestBlock": 500},
            "system_version": "0.22.2",
            "system_chain": "midnight-preprod",
        }.get(method)
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)


def test_build_report_healthy_against_mock():
    server = ThreadingHTTPServer(("127.0.0.1", 0), _MockRpcHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        port = server.server_address[1]
        report = hc.build_report(_args(f"http://127.0.0.1:{port}"))
        assert report.reachable is True
        assert report.status == hc.STATUS_HEALTHY
        assert report.metrics["peers"] == 9
        assert report.metrics["current_block"] == 500
        assert all(check.ok for check in report.checks)
    finally:
        server.shutdown()


def test_build_report_unreachable():
    report = hc.build_report(_args("http://127.0.0.1:9"))  # port 9 (discard) refuses
    assert report.reachable is False
    assert report.status == hc.STATUS_UNREACHABLE
