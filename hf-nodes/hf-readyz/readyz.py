#!/usr/bin/env python3
"""Readiness endpoint for Splunk HF syslog and HEC health. HTTP :9099 only.

Routes:
  /readyz/syslog        -- UDP MISC_CHECK target (keepalived IPVS real_server)
  /readyz/hec            -- HAProxy httpchk target for the HEC backend
  /readyz                -- legacy combined route, kept for backward compat

Syslog health and HEC health are checked and reported independently: an
outage in one must not pull the host out of the other's pool.
"""
import http.server
import json
import os
import shutil
import socket
import subprocess
import socketserver
import time
import urllib.error
import urllib.request
import uuid
import threading

BIND_ADDR = os.environ.get("READYZ_BIND", "0.0.0.0")
BIND_PORT = int(os.environ.get("READYZ_PORT", "9099"))
DATA_DIR = os.environ.get("READYZ_DATA_DIR", "/data/log/splunk/syslog")
DISK_FREE_PCT_MIN = float(os.environ.get("READYZ_DISK_FREE_PCT_MIN", "10"))
SPLUNKD_PORT = int(os.environ.get("READYZ_SPLUNKD_PORT", "8089"))
HEC_PORT = int(os.environ.get("READYZ_HEC_PORT", "8088"))
SYSLOG_PORT = int(os.environ.get("READYZ_SYSLOG_PORT", "514"))
SYNTHETIC_ENABLED = os.environ.get("READYZ_SYNTHETIC_CHECK", "0") == "1"
SYNTHETIC_INTERVAL = float(os.environ.get("READYZ_SYNTHETIC_INTERVAL", "30"))
# Set this to your lb1,lb2 IPs (both poll every HF independently at ~3s
# cadence) -- see the hf-readyz.service unit's Environment= line.
ALLOWED_CLIENTS = set(
    os.environ.get("READYZ_ALLOWED_CLIENTS", "127.0.0.1,::1").split(",")
)

_synthetic_cache = {"ts": 0.0, "ok": True, "detail": "skipped"}
_synthetic_lock = threading.Lock()


def _rsyslog_active():
    try:
        out = subprocess.run(
            ["systemctl", "is-active", "rsyslog"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True, timeout=2,
        )
        return out.stdout.strip() == "active", out.stdout.strip()
    except Exception as exc:
        return False, str(exc)


def _socket_listening(proto_flag):
    try:
        out = subprocess.run(
            ["ss", "-n", proto_flag, "sport", "=", f":{SYSLOG_PORT}"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True, timeout=2,
        )
        lines = [l for l in out.stdout.splitlines()
                 if l.strip() and not l.lstrip().startswith(("State", "Netid"))]
        return bool(lines), "
".join(lines)[:200]
    except Exception as exc:
        return False, str(exc)


def _disk_ok():
    try:
        probe = os.path.join(DATA_DIR, f".readyz-probe-{uuid.uuid4().hex}")
        with open(probe, "w") as fh:
            fh.write("readyz")
        os.remove(probe)
        usage = shutil.disk_usage(DATA_DIR)
        free_pct = (usage.free / usage.total) * 100
        return free_pct >= DISK_FREE_PCT_MIN, f"{free_pct:.1f}% free"
    except Exception as exc:
        return False, str(exc)


def _splunkd_reachable():
    try:
        with socket.create_connection(("127.0.0.1", SPLUNKD_PORT), timeout=1.5):
            return True, "connected"
    except Exception as exc:
        return False, str(exc)


def _hec_healthy():
    # Splunk's HEC health endpoint needs no token and reflects whether the
    # HEC input itself (not just the TCP port) is actually accepting data.
    url = f"http://127.0.0.1:{HEC_PORT}/services/collector/health"
    try:
        with urllib.request.urlopen(url, timeout=1.5) as resp:
            return resp.status == 200, f"http {resp.status}"
    except urllib.error.HTTPError as exc:
        return False, f"http {exc.code}"
    except Exception as exc:
        return False, str(exc)


def _synthetic_ok():
    # Optional end-to-end probe: sends a UDP syslog line to localhost and
    # confirms it lands on disk under <DATA_DIR>/127.0.0.1/. Off by default
    # (READYZ_SYNTHETIC_CHECK=1 to enable) -- cheap checks above are usually
    # enough, this catches silent ingest-pipeline breakage.
    if not SYNTHETIC_ENABLED:
        return True, "disabled"

    with _synthetic_lock:
        now = time.time()
        if now - _synthetic_cache["ts"] < SYNTHETIC_INTERVAL:
            return _synthetic_cache["ok"], _synthetic_cache["detail"] + " (cached)"

        marker = f"READYZ-{uuid.uuid4().hex}"
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.sendto(f"<134>{marker}\n".encode(), ("127.0.0.1", SYSLOG_PORT))
            sock.close()
            today_dir = os.path.join(DATA_DIR, "127.0.0.1")
            deadline = now + 2.0
            found = False
            while time.time() < deadline:
                if os.path.isdir(today_dir):
                    for fname in os.listdir(today_dir):
                        path = os.path.join(today_dir, fname)
                        try:
                            with open(path, "r", errors="ignore") as fh:
                                if marker in fh.read()[-4096:]:
                                    found = True
                                    break
                        except Exception:
                            continue
                if found:
                    break
                time.sleep(0.2)
            _synthetic_cache.update(ts=now, ok=found, detail="landed" if found else "not found")
            return found, _synthetic_cache["detail"]
        except Exception as exc:
            _synthetic_cache.update(ts=now, ok=False, detail=str(exc))
            return False, str(exc)


def run_syslog_checks():
    checks = {}
    checks["rsyslog_active"], _ = _rsyslog_active()
    checks["udp_listening"], _ = _socket_listening("-lun")
    checks["tcp_listening"], _ = _socket_listening("-ltn")
    checks["disk_ok"], disk_detail = _disk_ok()
    checks["synthetic_ok"], synthetic_detail = _synthetic_ok()

    ready = all(checks.values())
    failed = [name for name, ok in checks.items() if not ok]
    reason = "ok" if ready else "failed:" + ",".join(failed)
    return ready, {
        "ready": ready,
        "checks": checks,
        "disk": disk_detail,
        "synthetic": synthetic_detail,
        "reason": reason,
    }


def run_hec_checks():
    checks = {}
    checks["splunkd_reachable"], _ = _splunkd_reachable()
    checks["hec_healthy"], hec_detail = _hec_healthy()

    ready = all(checks.values())
    failed = [name for name, ok in checks.items() if not ok]
    reason = "ok" if ready else "failed:" + ",".join(failed)
    return ready, {
        "ready": ready,
        "checks": checks,
        "hec": hec_detail,
        "reason": reason,
    }


def run_legacy_combined_checks():
    checks = {}
    checks["rsyslog_active"], _ = _rsyslog_active()
    checks["udp_listening"], _ = _socket_listening("-lun")
    checks["tcp_listening"], _ = _socket_listening("-ltn")
    checks["disk_ok"], disk_detail = _disk_ok()
    checks["splunkd_reachable"], _ = _splunkd_reachable()
    checks["synthetic_ok"], synthetic_detail = _synthetic_ok()

    ready = all(checks.values())
    failed = [name for name, ok in checks.items() if not ok]
    reason = "ok" if ready else "failed:" + ",".join(failed)
    return ready, {
        "ready": ready,
        "checks": checks,
        "disk": disk_detail,
        "synthetic": synthetic_detail,
        "reason": reason,
    }


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.client_address[0] not in ALLOWED_CLIENTS:
            self.send_response(403)
            self.end_headers()
            return
        if self.path == "/readyz/syslog":
            ready, body = run_syslog_checks()
        elif self.path == "/readyz/hec":
            ready, body = run_hec_checks()
        elif self.path == "/readyz":
            ready, body = run_legacy_combined_checks()
        else:
            self.send_response(404)
            self.end_headers()
            return
        payload = json.dumps(body).encode()
        self.send_response(200 if ready else 503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        pass  # quiet by default; rely on the reason field for diagnosis


if __name__ == "__main__":
    class _Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    server = _Server((BIND_ADDR, BIND_PORT), Handler)
    server.serve_forever()
