#!/usr/bin/env python3
"""Çoklu kaynak-IP TCP+UDP syslog yük testi.

Kullanım:
  # Gerçekten farklı IP'lerden test etmek için, önce test makinesine
  # birkaç geçici IP alias ekle (aynı subnette):
  #   ip addr add 192.0.2.231/24 dev eth0
  #   ip addr add 192.0.2.232/24 dev eth0
  # Sonra:
  python3 loadtest.py --vip 192.0.2.50 --sources 192.0.2.231,192.0.2.232 --n 10

Her (source, protokol) kombinasyonu ayrı thread'de --n mesaj gönderir.
Sonra HF'lerde doğrulama için:
  grep -o LOADTEST_<runid> /data/log/splunk/syslog/<source-ip>/*.log | wc -l
"""
import argparse
import socket
import threading
import time


def send_tcp(vip, port, src, runid, n):
    for i in range(n):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind((src, 0))
        s.settimeout(3)
        try:
            s.connect((vip, port))
            msg = f"<34>loadtest testprog: LOADTEST_{runid}_TCP_{src}_{i}\n"
            s.sendall(msg.encode())
        except Exception as exc:
            print(f"TCP FAIL {src} {i}: {exc}")
        finally:
            s.close()


def send_udp(vip, port, src, runid, n):
    for i in range(n):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind((src, 0))
        try:
            msg = f"<34>loadtest testprog: LOADTEST_{runid}_UDP_{src}_{i}"
            s.sendto(msg.encode(), (vip, port))
        except Exception as exc:
            print(f"UDP FAIL {src} {i}: {exc}")
        finally:
            s.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vip", required=True)
    ap.add_argument("--port", type=int, default=514)
    ap.add_argument("--sources", required=True, help="virgülle ayrılmış kaynak IP listesi")
    ap.add_argument("--n", type=int, default=10, help="her (source,protokol) için mesaj sayısı")
    args = ap.parse_args()

    runid = str(int(time.time()))
    sources = args.sources.split(",")

    threads = []
    for src in sources:
        threads.append(threading.Thread(target=send_tcp, args=(args.vip, args.port, src, runid, args.n)))
        threads.append(threading.Thread(target=send_udp, args=(args.vip, args.port, src, runid, args.n)))

    for t in threads:
        t.start()
    for t in threads:
        t.join()

    print(f"DONE runid={runid} sources={len(sources)} per_proto={args.n} "
          f"total_sent={len(sources) * args.n * 2}")
    print(f"Doğrulama (her HF'de): grep -o LOADTEST_{runid} /data/log/splunk/syslog/*/*.log | wc -l")


if __name__ == "__main__":
    main()
