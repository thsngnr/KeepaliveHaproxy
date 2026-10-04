"""Fake HAProxy stats / HF readyz / HEC / Slack servers driven by files in /fx."""
import http.server, json, os, socketserver, threading

FX = "/fx"
HF = {"127.0.0.2": "hf-1", "127.0.0.3": "hf-2", "127.0.0.4": "hf-3"}


def fx(name, default=""):
    try:
        return open(os.path.join(FX, name)).read().strip()
    except OSError:
        return default


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body, ctype="application/json"):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        host, port = self.server.server_address
        if port == 8404:
            rows = ["# pxname,svname,scur,status,check_status,lastchg,rate,req_rate,"]
            for ip, n in HF.items():
                st = fx("hec_" + n, "UP")
                rows.append("hec_hfs,{},3,{},L7OK,120,0,{},".format(n, st, 40 if st == "UP" else 0))
            rows.append("hec_hfs,BACKEND,9,UP,,120,0,120,")
            return self.reply(200, "\n".join(rows) + "\n", "text/csv")
        if port == 9099:
            n = HF[host]
            free = float(fx("disk_" + n, "40"))
            ok = fx("syslog_" + n, "ok") == "ok"
            body = {"ready": ok, "reason": "ok" if ok else "failed:disk_ok",
                    "host": {"load1": 0.5, "mem_avail_pct": 60.0,
                             "data_dir_free_pct": free, "data_dir_free_mb": int(free * 5000)}}
            if self.path == "/readyz/hec":
                hok = fx("hec_" + n, "UP") == "UP"
                body.update(ready=hok, reason="ok" if hok else "failed:hec_healthy")
                return self.reply(200 if hok else 503, json.dumps(body))
            return self.reply(200 if ok else 503, json.dumps(body))
        self.reply(404, "{}")

    def do_POST(self):
        host, port = self.server.server_address
        data = self.rfile.read(int(self.headers["Content-Length"])).decode()
        if port == 8099:
            with open("/out/slack", "a") as fh:
                fh.write(json.loads(data)["text"] + "\n=====\n")
        elif port == 8088:
            assert self.headers["Authorization"] == "Splunk TESTTOKEN"
            with open("/out/hec", "a") as fh:
                fh.write("{} {}\n".format(host, data))
        self.reply(200, '{"text":"Success","code":0}')


class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


addrs = [("127.0.0.1", 8404), ("127.0.0.1", 8099)] + [(ip, 9099) for ip in HF] + [(ip, 8088) for ip in HF]
if fx("local_hec", "up") == "up":
    addrs.append(("127.0.0.1", 8088))
for a in addrs:
    threading.Thread(target=S(a, H).serve_forever, daemon=True).start()
threading.Event().wait()
