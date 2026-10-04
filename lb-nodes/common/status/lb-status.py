#!/usr/bin/env python3
"""LB durum izleme: Splunk (HEC) ve opsiyonel Slack (anlik uyari + periyodik rapor).

Splunk'a her zaman (STATUS_INDEX bos degilse ve token varsa):
  sourcetype lb:status:hec -> her check'te tam durum (JSON)
  sourcetype lb:event:hec  -> yeni / duzelen sorun (Splunk alert'leri buna kurulabilir)
HEC hedefi once yerel HAProxy (127.0.0.1), olmazsa sirayla dogrudan HF'ler.
Slack'e sadece SLACK_ENABLED=yes ise (varsayilan kapali).

Kullanim:
  lb-status check   [--dry-run]   # lb-status-check.timer, varsayilan dakikada bir
  lb-status report  [--dry-run]   # lb-status-report.timer, varsayilan saatte bir
  --dry-run: Slack/HEC'e gondermez, mesajlari ve JSON'u ekrana basar.

check : durumu toplar, sorun listesini bir oncekiyle karsilastirir. YENI sorun
        -> hemen Slack; duzelen sorun -> "duzeldi". Durumu (JSON) her seferinde
        Splunk HEC'e (STATUS_INDEX) gonderir.
report: sadece VIP'i tutan (MASTER) LB. Sorun yoksa tek satir, varsa tablo.

Her LB kendi servis/disk sorunlarini bildirir. HF'lerle ilgili her sey sadece
MASTER'dan gelir (iki LB ayni HF'leri gordugu icin aksi halde mesajlar ciftlenir).
Syslog havuzu (IPVS) ve VRRP degisiklikleri keepalived notify.sh ile ZATEN anlik
bildiriliyor; burada tekrar uyarilmaz, sadece rapor tablosunda gorunur.
"""
import csv
import io
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request

SITE = "<ALERT_SITE_NAME>"
VIP = "<VIP_IP>"
SYSLOG_PORT = "<SYSLOG_PORT>"
HEC_PORT = "<HEC_PORT>"
HEC_SSL = "<HEC_SSL>" == "1"
READYZ_PORT = "<READYZ_PORT>"
LB_IPS = ["<LB1_IP>", "<LB2_IP>"]
HF_NODES = [n.split(":", 1) for n in "<HF_NODES>".split()]
STATUS_INDEX = "<STATUS_INDEX>"
DISK_WARN_PCT = float("<STATUS_DISK_WARN_PCT>")
SLACK_ENABLED = "<SLACK_ENABLED>" == "yes"
LB_DISK_WARN_USED_PCT = 90.0

KEYS_DIR = "/etc/keepalived/keys"
STATE_FILE = "/var/lib/lb-status/problems.json"
HAPROXY_CSV = "http://127.0.0.1:8404/stats;csv"
HEC_BACKEND = "hec_hfs"
HOST = socket.gethostname().split(".")[0]
PREFIX = "[{}{}]".format(SITE + " / " if SITE else "", HOST)

DRY_RUN = "--dry-run" in sys.argv


# --------------------------------------------------------------------- yardimci
def sh(cmd, timeout=5):
    try:
        out = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             universal_newlines=True, timeout=timeout)
        return out.stdout
    except Exception:
        return ""


def read_secret(name):
    try:
        with open(os.path.join(KEYS_DIR, name)) as fh:
            return fh.readline().strip()
    except OSError:
        return ""


def http_get(url, timeout=3):
    """(http_code | None, body_text)"""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", "replace")
    except Exception:
        return None, ""


def tcp_ok(ip, port, timeout=2):
    try:
        with socket.create_connection((ip, int(port)), timeout=timeout):
            return True
    except Exception:
        return False


def human(n):
    if n is None:
        return "-"
    n = float(n)
    for unit in ("", "k", "M"):
        if abs(n) < 1000:
            return "{:.0f}{}".format(n, unit) if unit == "" else "{:.1f}{}".format(n, unit)
        n /= 1000.0
    return "{:.1f}G".format(n)


# --------------------------------------------------------------------- toplama
def own_ips():
    ips = set()
    for line in sh(["ip", "-4", "-o", "addr", "show"]).splitlines():
        parts = line.split()
        if "inet" in parts:
            ips.add(parts[parts.index("inet") + 1].split("/")[0])
    return ips


def svc_active(name):
    return sh(["systemctl", "is-active", name]).strip() == "active"


def lb_host_metrics():
    m = {}
    try:
        m["load1"] = round(os.getloadavg()[0], 2)
    except OSError:
        pass
    try:
        mem = {}
        with open("/proc/meminfo") as fh:
            for line in fh:
                k, v = line.split(":", 1)
                mem[k] = int(v.split()[0])
        m["mem_avail_pct"] = round(mem["MemAvailable"] * 100.0 / mem["MemTotal"], 1)
    except (OSError, KeyError, ValueError):
        pass
    try:
        u = shutil.disk_usage("/")
        m["root_used_pct"] = round(u.used * 100.0 / u.total, 1)
    except OSError:
        pass
    return m


def haproxy_servers():
    """{svname: {...}} for the HEC backend, plus "__backend__"."""
    code, text = http_get(HAPROXY_CSV)
    if code != 200 or not text:
        return None
    text = text.lstrip("# ")
    out = {}
    for row in csv.DictReader(io.StringIO(text)):
        if row.get("pxname") != HEC_BACKEND:
            continue
        name = "__backend__" if row.get("svname") == "BACKEND" else row.get("svname")
        if name == "FRONTEND":
            continue
        out[name] = {
            "status": row.get("status", "?"),
            "check_status": row.get("check_status", ""),
            "lastchg_s": int(row["lastchg"]) if row.get("lastchg", "").isdigit() else None,
            "scur": int(row["scur"]) if row.get("scur", "").isdigit() else None,
            # mode http -> req_rate, mode tcp -> session rate
            "rate": int(row.get("req_rate") or row.get("rate") or 0),
        }
    return out


def ipvs_pools():
    """{"TCP": {hf_ip: {"inpps": n, "cps": n}}, "UDP": {...}} for VIP:SYSLOG_PORT."""
    pools = {"TCP": {}, "UDP": {}}
    cur = None
    for line in sh(["ipvsadm", "-L", "-n", "--rate"]).splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] in ("TCP", "UDP"):
            cur = parts[0] if parts[1] == "{}:{}".format(VIP, SYSLOG_PORT) else None
        elif parts[0] == "->" and cur and ":" in parts[1] and len(parts) >= 4 and parts[2].isdigit():
            ip = parts[1].rsplit(":", 1)[0]
            pools[cur][ip] = {"cps": int(parts[2]), "inpps": int(parts[3])}
    return pools


def readyz(ip, path):
    code, text = http_get("http://{}:{}{}".format(ip, READYZ_PORT, path))
    try:
        body = json.loads(text) if text else {}
    except ValueError:
        body = {}
    return code, body


def collect():
    ips = own_ips()
    role = "MASTER" if VIP in ips else "BACKUP"
    st = {
        "site": SITE, "lb": HOST, "role": role, "ts": int(time.time()),
        "services": {"haproxy": svc_active("haproxy"), "keepalived": svc_active("keepalived")},
        "lb_host": lb_host_metrics(),
    }
    if role != "MASTER":
        return st

    peers = [ip for ip in LB_IPS if ip not in ips]
    st["peer"] = {"ip": peers[0] if peers else None,
                  "hec_port_ok": tcp_ok(peers[0], HEC_PORT) if peers else None}
    hap = haproxy_servers()
    st["haproxy_stats_ok"] = hap is not None
    hap = hap or {}
    pools = ipvs_pools()
    hfs = []
    for name, ip in HF_NODES:
        sy_code, sy = readyz(ip, "/readyz/syslog")
        he_code, he = readyz(ip, "/readyz/hec")
        host = sy.get("host") or he.get("host") or {}
        srv = hap.get(name, {})
        tcp, udp = pools["TCP"].get(ip), pools["UDP"].get(ip)
        hfs.append({
            "name": name, "ip": ip,
            "hec_status": srv.get("status", "?"), "hec_check": srv.get("check_status", ""),
            "hec_rate": srv.get("rate"), "hec_scur": srv.get("scur"),
            "hec_lastchg_s": srv.get("lastchg_s"),
            "syslog_tcp_in_pool": tcp is not None, "syslog_udp_in_pool": udp is not None,
            "syslog_inpps": (tcp or {}).get("inpps", 0) + (udp or {}).get("inpps", 0),
            "readyz_reachable": sy_code is not None,
            "readyz_syslog_ok": sy_code == 200, "readyz_hec_ok": he_code == 200,
            "readyz_syslog_reason": sy.get("reason"), "readyz_hec_reason": he.get("reason"),
            "disk_free_pct": host.get("data_dir_free_pct"), "disk_free_mb": host.get("data_dir_free_mb"),
            "load1": host.get("load1"), "mem_avail_pct": host.get("mem_avail_pct"),
        })
    st["hfs"] = hfs
    return st


# --------------------------------------------------------------------- sorunlar
def problems(st):
    """{key: {"sev": "crit"|"warn", "text": str, "alert": bool}}"""
    p = {}

    def add(key, sev, text, alert=True):
        p[key] = {"sev": sev, "text": text, "alert": alert}

    for svc, ok in st["services"].items():
        if not ok:
            add("svc:" + svc, "crit", "{} servisi calismiyor ({})".format(svc, HOST))
    used = st["lb_host"].get("root_used_pct")
    if used is not None and used >= LB_DISK_WARN_USED_PCT:
        add("lbdisk", "warn", "LB {} kok disk %{:.0f} dolu".format(HOST, used))

    if st["role"] != "MASTER":
        return p
    peer = st.get("peer") or {}
    if peer.get("ip") and peer.get("hec_port_ok") is False:
        add("peer", "warn", "Yedek LB {} HAProxy/HEC portuna ulasilamiyor -- failover olursa VIP bakimsiz kalabilir".format(peer["ip"]))
    if not st.get("haproxy_stats_ok"):
        add("hapstats", "warn", "HAProxy stats okunamadi (127.0.0.1:8404)")
    hfs = st.get("hfs", [])
    hec_up = [h for h in hfs if h["hec_status"].startswith("UP")]
    if hfs and not hec_up and st.get("haproxy_stats_ok"):
        add("hec:none", "crit", "HEC havuzunda HIC HF KALMADI -- VIP:{} HEC istekleri basarisiz".format(HEC_PORT))
    for h in hfs:
        n = h["name"]
        if st.get("haproxy_stats_ok") and not h["hec_status"].startswith("UP"):
            add("hec:" + n, "crit", "HF {} HEC {} ({})".format(n, h["hec_status"], h["readyz_hec_reason"] or h["hec_check"] or "?"))
        if not h["readyz_reachable"]:
            add("readyz:" + n, "crit", "HF {} readyz'e ulasilamiyor ({}:{})".format(n, h["ip"], READYZ_PORT))
        if h["disk_free_pct"] is not None and h["disk_free_pct"] < DISK_WARN_PCT:
            add("disk:" + n, "warn", "HF {} DATA_DIR diskinde bos alan %{:.0f} ({} MB) < uyari esigi %{:.0f}".format(
                n, h["disk_free_pct"], h["disk_free_mb"], DISK_WARN_PCT))
        # notify.sh bunlari zaten anlik bildiriyor -> sadece raporda
        for proto in ("tcp", "udp"):
            if not h["syslog_{}_in_pool".format(proto)]:
                why = h["readyz_syslog_reason"]
                add("pool:{}:{}".format(proto, n), "crit",
                    "HF {} syslog/{} havuzunda degil{}".format(
                        n, proto, " ({})".format(why) if why and why != "ok" else ""), alert=False)
    return p


# --------------------------------------------------------------------- gonderim
def slack(text):
    if DRY_RUN:
        print("--- SLACK{} ---\n{}".format("" if SLACK_ENABLED else " (KAPALI, gonderilmez)", text))
        return
    if not SLACK_ENABLED:
        return
    url = read_secret("slack-webhook")
    if not url:
        return
    proxy = read_secret("slack-proxy")
    handlers = [urllib.request.ProxyHandler({"http": proxy, "https": proxy})] if proxy else []
    req = urllib.request.Request(url, data=json.dumps({"text": text}).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        urllib.request.build_opener(*handlers).open(req, timeout=5).read()
    except Exception as exc:
        sh(["logger", "-t", "lb-status", "Slack gonderilemedi: {}".format(exc)])


def hec(events):
    """events: [(sourcetype, dict)]. Tek istekte (HEC batch) gonderilir."""
    if not STATUS_INDEX or not events:
        return
    body = "".join(json.dumps({"time": int(time.time()), "host": HOST, "source": "lb-status",
                               "sourcetype": stype, "index": STATUS_INDEX, "event": ev})
                   for stype, ev in events)
    if DRY_RUN:
        print("--- HEC ---\n" + body.replace("}{\"time\"", "}\n{\"time\""))
        return
    token = read_secret("status-hec-token")
    if not token:
        return
    scheme = "https" if HEC_SSL else "http"
    # localhost / HF IP'siyle baglaniliyor: sertifika adi eslesmez
    ctx = ssl._create_unverified_context() if HEC_SSL else None
    last_err = None
    # Yerel HAProxy coktuyse (VRRP FAULT) dogrudan HF'lere dene
    for target in ["127.0.0.1"] + [ip for _, ip in HF_NODES]:
        req = urllib.request.Request(
            "{}://{}:{}/services/collector/event".format(scheme, target, HEC_PORT),
            data=body.encode(), headers={"Authorization": "Splunk " + token})
        try:
            urllib.request.urlopen(req, timeout=3, context=ctx).read()
            return
        except Exception as exc:
            last_err = "{}: {}".format(target, exc)
    sh(["logger", "-t", "lb-status", "HEC'e gonderilemedi (tum hedefler): {}".format(last_err)])


# --------------------------------------------------------------------- modlar
def load_state():
    try:
        with open(STATE_FILE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def save_state(role, probs):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump({"role": role, "problems": probs}, fh)
    os.replace(tmp, STATE_FILE)


def icon(sev):
    return ":rotating_light:" if sev == "crit" else ":warning:"


def cmd_check():
    st = collect()
    cur = problems(st)
    prev = load_state()
    new, resolved = {}, {}
    if prev is None:
        new = {k: v for k, v in cur.items() if v["alert"]}
    # Rol degistiyse (failover) onceki listeyi karsilastirma: MASTER'a ozel
    # sorunlar "duzeldi" gibi gorunurdu. Gecisi notify.sh zaten bildirdi.
    elif prev.get("role") == st["role"]:
        old = prev.get("problems", {})
        new = {k: v for k, v in cur.items() if v["alert"] and k not in old}
        resolved = {k: v for k, v in old.items() if v.get("alert") and k not in cur}
    lines = ["{} {} {}".format(icon(v["sev"]), PREFIX, v["text"]) for v in new.values()]
    lines += [":white_check_mark: {} DUZELDI: {}".format(PREFIX, v["text"]) for v in resolved.values()]
    if lines:
        slack("\n".join(lines))
    save_state(st["role"], cur)

    st["problems"] = sorted(cur)
    events = [("lb:status:hec", st)]
    for state, group in (("new", new), ("resolved", resolved)):
        for k, v in group.items():
            events.append(("lb:event:hec", {"site": SITE, "lb": HOST, "type": "problem", "state": state,
                                        "key": k, "severity": v["sev"], "message": v["text"]}))
    hec(events)


def publish_report(cur, text):
    """Rapor: Slack'e (SLACK_ENABLED ise) ve Splunk'a lb:event:hec type=report
    olarak -- sunucudan Slack kapaliyken rapor Splunk alert'iyle Slack'e iletilir."""
    slack(text)
    hec([("lb:event:hec", {"site": SITE, "lb": HOST, "type": "report",
                           "state": "ok" if not cur else "problems",
                           "severity": "info" if not cur else max(
                               (v["sev"] for v in cur.values()), key=["warn", "crit"].index),
                           "problems": sorted(cur), "message": text})])


def cmd_report():
    st = collect()
    if st["role"] != "MASTER":
        return
    cur = problems(st)
    hfs = st["hfs"]
    peer = st.get("peer") or {}
    peer_txt = "yedek {} {}".format(peer.get("ip"), "erisilebilir" if peer.get("hec_port_ok") else "ERISILEMIYOR")
    if not cur:
        disks = [h for h in hfs if h["disk_free_pct"] is not None]
        low = min(disks, key=lambda h: h["disk_free_pct"]) if disks else None
        publish_report(cur, ":white_check_mark: {} {}/{} HF saglikli | syslog {} pkt/s | HEC {} istek/s | en dusuk disk: {} | {}".format(
            PREFIX, len(hfs), len(hfs),
            human(sum(h["syslog_inpps"] or 0 for h in hfs)),
            human(sum(h["hec_rate"] or 0 for h in hfs)),
            "{} %{:.0f}".format(low["name"], low["disk_free_pct"]) if low else "-",
            peer_txt))
        return

    def yn(b):
        return "UP" if b else "DOWN"
    rows = [("HF", "HEC", "sys-tcp", "sys-udp", "disk bos", "load", "sys pkt/s", "HEC/s")]
    for h in hfs:
        rows.append((
            h["name"], h["hec_status"].split()[0],
            yn(h["syslog_tcp_in_pool"]), yn(h["syslog_udp_in_pool"]),
            "%{:.0f} {:.0f}G".format(h["disk_free_pct"], (h["disk_free_mb"] or 0) / 1024.0)
            if h["disk_free_pct"] is not None else "-",
            "-" if h["load1"] is None else "{:.1f}".format(h["load1"]),
            human(h["syslog_inpps"]), human(h["hec_rate"]),
        ))
    widths = [max(len(str(r[i])) for r in rows) for i in range(len(rows[0]))]
    table = "\n".join("  ".join(str(c).ljust(w) for c, w in zip(r, widths)).rstrip() for r in rows)
    lb = st["lb_host"]
    probs = "\n".join("{} {}".format(icon(v["sev"]), v["text"]) for v in cur.values())
    publish_report(cur, ":bar_chart: {} Durum raporu -- {} {} | {}\n{}\n```\n{}\n```\nLB: load {} | mem bos %{} | disk %{} dolu | haproxy {} | keepalived {}".format(
        PREFIX, HOST, st["role"], peer_txt, probs, table,
        lb.get("load1", "-"), lb.get("mem_avail_pct", "-"), lb.get("root_used_pct", "-"),
        "up" if st["services"]["haproxy"] else "DOWN", "up" if st["services"]["keepalived"] else "DOWN"))


if __name__ == "__main__":
    mode = next((a for a in sys.argv[1:] if not a.startswith("--")), "")
    if mode == "check":
        cmd_check()
    elif mode == "report":
        cmd_report()
    else:
        print(__doc__)
        sys.exit(2)
