#!/usr/bin/env python3
"""Sadece TCP syslog yuk testi (VIP:514), parametreli.

Persistent TCP baglantilari + batch write. Thread'ler FLAT olusturulur
(bkz. loadtest_high_volume.py'deki threading notu).

Kullanim:
  python3 loadtest_tcp.py --vip 10.10.42.210 [--port 514] [--sources IP1,IP2,..]
                          [--conns 2] [--per-conn 50000] [--runid X] [--batch 200]

--sources verilmezse OS kendi kaynak IP'sini secer (tek kaynak IP). Verilirse
her IP gondericide tanimli olmalidir (ip addr add <ip>/<prefix> dev <iface>).
Toplam mesaj = len(sources) * conns * per-conn.
Her satir: <130>LTTCP_<RUNID>_<src>_<conn>_<i> payload...
HF'lerde sayim: grep -ho "LTTCP_<RUNID>_" <DATA_DIR>/*/*.log | wc -l
"""
import argparse
import socket
import threading
import time

ap = argparse.ArgumentParser()
ap.add_argument("--vip", required=True)
ap.add_argument("--port", type=int, default=514)
ap.add_argument("--sources", default="")
ap.add_argument("--conns", type=int, default=2, help="kaynak IP basina TCP baglanti sayisi")
ap.add_argument("--per-conn", type=int, default=50000, help="baglanti basina mesaj")
ap.add_argument("--runid", default=str(int(time.time())))
ap.add_argument("--batch", type=int, default=200)
a = ap.parse_args()

sources = [s for s in a.sources.split(",") if s] or [None]
sent = [0] * (len(sources) * a.conns)
errors = []
PAD = "x" * 60


def worker(slot, src, idx):
    tag = src or "default"
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 0)
        if src:
            s.bind((src, 0))
        s.connect((a.vip, a.port))
        buf = []
        for i in range(a.per_conn):
            buf.append("<134>LTTCP_%s_%s_%d_%d %s\n" % (a.runid, tag, idx, i, PAD))
            if len(buf) >= a.batch:
                s.sendall("".join(buf).encode())
                sent[slot] += len(buf)
                buf = []
        if buf:
            s.sendall("".join(buf).encode())
            sent[slot] += len(buf)
        s.shutdown(socket.SHUT_WR)
        s.close()
    except Exception as e:
        errors.append("%s/%d: %s" % (tag, idx, e))


threads = []
slot = 0
for src in sources:
    for idx in range(a.conns):
        threads.append(threading.Thread(target=worker, args=(slot, src, idx)))
        slot += 1

t0 = time.time()
for t in threads:
    t.start()
for t in threads:
    t.join()
dt = time.time() - t0
total = sum(sent)
print("RUNID=%s  gonderilen=%d  sure=%.2fs  eps=%d  hata=%d"
      % (a.runid, total, dt, total / dt if dt else 0, len(errors)))
for e in errors[:10]:
    print("HATA:", e)
print('Dogrula (her HF\'de): grep -ho "LTTCP_%s_" /data/log/splunk/syslog/*/*.log | wc -l' % a.runid)
