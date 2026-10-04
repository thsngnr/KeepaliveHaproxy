#!/usr/bin/env python3
"""Yuksek hacimli (1M+), coklu source-IP TCP+UDP syslog yuk testi.

loadtest.py'nin daha agresif versiyonu: persistent TCP baglantilari +
batch write ile >200k eps gonderim hizina ulasir. Varsayilan: --sources'taki
her IP, IP+protokol basina 100,000 mesaj (5 kaynakla toplam 1,000,000 --
500k TCP + 500k UDP).

ONEMLI -- THREADING DERSI (bu script'i yazarken bulundu, 2026-10-02):
Tum gonderici thread'lerini FLAT olustur: hepsini ayni dongude yarat,
sonra hepsini birlikte start() + join() et. NESTED thread spawning
(bir "parent" thread'in kendi icinde yeni thread'ler yaratip onlari
join etmesi -- ornegin "her IP icin bir thread, o thread de kendi
icinde 2 TCP-connection thread'i yaratip bekliyor" gibi) GIL rekabeti
yuzunden TCP connect()/sendall() zamanlamasini bozup veri "gonderildi"
sayilsa da bir kismi gercekte iletilmemis gibi davraniyor (bu ortamda
olculen etki: TCP teslimat %28-33'e dustu, flat yapiyla %100'e cikti;
UDP her iki yapida da ~%99.7-99.9 ile degismedi). Asagidaki main()
bu yuzden TUM thread'leri (TCP+UDP, her kaynak icin) once bir listeye
ekleyip SONRA hepsini start/join ediyor -- bu deseni degistirme.

Kullanim:
  python3 loadtest_high_volume.py --vip <VIP> --sources IP1,IP2,.. [runid] [per_ip_per_proto] [tcp_conns_per_ip]
  python3 loadtest_high_volume.py --vip 192.0.2.50 --sources 192.0.2.231,192.0.2.232
  python3 loadtest_high_volume.py --vip 192.0.2.50 --sources 192.0.2.231 myrun 50000 1

--sources'taki her IP gonderici makinede tanimli olmali, ornegin:
  ip addr add 192.0.2.231/24 dev eth0
"""
import argparse
import socket
import threading
import time

ap = argparse.ArgumentParser(description="Yuksek hacimli coklu source-IP syslog yuk testi")
ap.add_argument("--vip", required=True, help="hedef VIP (variables.env VIP_IP)")
ap.add_argument("--port", type=int, default=514)
ap.add_argument("--sources", required=True,
                help="virgulle ayrilmis kaynak IP'ler (gondericide alias olarak tanimli)")
ap.add_argument("runid", nargs="?", default=str(int(time.time())))
ap.add_argument("per_ip_per_proto", nargs="?", type=int, default=100000)
ap.add_argument("tcp_conns_per_ip", nargs="?", type=int, default=2)
_a = ap.parse_args()

RUNID = _a.runid
PER_IP_PER_PROTO = _a.per_ip_per_proto
TCP_CONNS_PER_IP = _a.tcp_conns_per_ip
VIP = _a.vip
PORT = _a.port
SRC_IPS = [ip.strip() for ip in _a.sources.split(",") if ip.strip()]
TCP_BATCH = 500

counters = {"tcp": 0, "udp": 0}
lock = threading.Lock()


def tcp_worker(src, n, offset):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind((src, 0))
    s.settimeout(10)
    s.connect((VIP, PORT))
    sent = 0
    buf = []
    while sent < n:
        i = offset + sent
        buf.append(f"<34>loadtest-hv testprog: LTHV_{RUNID}_TCP_{src}_{i}")
        sent += 1
        if len(buf) >= TCP_BATCH:
            s.sendall(("\n".join(buf) + "\n").encode())
            with lock:
                counters["tcp"] += len(buf)
            buf = []
    if buf:
        s.sendall(("\n".join(buf) + "\n").encode())
        with lock:
            counters["tcp"] += len(buf)
    s.shutdown(socket.SHUT_WR)
    s.close()


def udp_worker(src, count):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((src, 0))
    for i in range(count):
        msg = f"<34>loadtest-hv testprog: LTHV_{RUNID}_UDP_{src}_{i}"
        s.sendto(msg.encode(), (VIP, PORT))
    with lock:
        counters["udp"] += count
    s.close()


def main():
    total_expected = len(SRC_IPS) * PER_IP_PER_PROTO * 2
    print(f"RUNID={RUNID} sources={len(SRC_IPS)} "
          f"per_ip_per_proto={PER_IP_PER_PROTO} tcp_conns_per_ip={TCP_CONNS_PER_IP} "
          f"total={total_expected}")

    # FLAT: hepsini once olustur, sonra hepsini birlikte baslat (bkz. yukaridaki not).
    threads = []
    per_conn = PER_IP_PER_PROTO // TCP_CONNS_PER_IP
    for src in SRC_IPS:
        for c in range(TCP_CONNS_PER_IP):
            threads.append(threading.Thread(target=tcp_worker,
                                              args=(src, per_conn, c * per_conn)))
        threads.append(threading.Thread(target=udp_worker,
                                          args=(src, PER_IP_PER_PROTO)))

    t0 = time.time()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    elapsed = time.time() - t0

    total = counters["tcp"] + counters["udp"]
    eps = total / elapsed if elapsed > 0 else 0
    print(f"DONE total_sent={total} tcp={counters['tcp']} udp={counters['udp']} "
          f"elapsed={elapsed:.2f}s eps={eps:.0f}")
    print(f"Dogrulama (her HF'de): grep -o LTHV_{RUNID}_TCP /data/log/splunk/syslog/*/*.log | wc -l")
    print(f"                       grep -o LTHV_{RUNID}_UDP /data/log/splunk/syslog/*/*.log | wc -l")


if __name__ == "__main__":
    main()
