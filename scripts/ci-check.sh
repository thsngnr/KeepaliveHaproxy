#!/bin/bash
# Repo dogrulamasi -- yerelde ve GitHub Actions'ta (.github/workflows/ci.yml)
# ayni. Gerekli: docker (+ git). Hicbir host'a kurulum yapmaz; her arac kendi
# konteynerinde calisir.
#
#   ./scripts/ci-check.sh
#
# Adimlar:
#   1 shellcheck            tum *.sh
#   2 python                Python 3.6 (RHEL 7-8) soz dizimi, tum *.py
#   3 render                tum sablonlar, birkac variables varyantiyla
#                           (2/3/5 HF, eski HF1_* formati, HEC http/TLS, DS
#                           acik/kapali, VMAC, disk kuyrugu); doldurulmamis
#                           yer tutucu kalirsa hata. install-*.sh'in kullandigi
#                           ayni lib.sh fonksiyonlari.
#   4 haproxy -c            haproxy:3.4, her varyant
#   5 keepalived -t         her varyant, lb1+lb2. NOT: imajdaki keepalived
#                           (Alpine paketi) auth_hmac'i bilmez -- o blok
#                           cikarilip dogrulanir (LB'de 2.4.3 kaynaktan derlenir).
#   6 rsyslogd -N1          rsyslog 8.2312 (Ubuntu 24.04) ve 8.24 (CentOS 7)
#   7 lb-status testi       tests/lb-status (sahte HAProxy/HF/HEC/Slack ile)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
chmod 0777 "$OUT"

step() { printf '\n== %s\n' "$*"; }
dk() { docker run --rm -v "$ROOT":/m:ro -v "$OUT":/out "$@"; }

# name|variables.env.local satirlari (\n ile)
VARIANTS=(
    'default|'
    'hf2-tls-ds-vmac-daq|HF_NODES="a:192.0.2.21 b:192.0.2.22"\nHEC_SSL=1\nDS_IP=192.0.2.60\nUSE_VMAC=yes\nSYSLOG_QUEUE_DISK=yes'
    'hf5-slack|HF_NODES="h1:192.0.2.21 h2:192.0.2.22 h3:192.0.2.23 h4:192.0.2.24 h5:192.0.2.25"\nSLACK_ENABLED=yes\nALERT_SITE_NAME=ci'
    'legacy-hf-vars|HF_NODES=\nHF1_IP=192.0.2.21\nHF2_IP=192.0.2.22\nHF1_NAME=old-1\nHF2_NAME=old-2'
)

step "1/7 shellcheck"
# macOS bash 3.2'de mapfile yok; dosya adlarinda bosluk yok
# shellcheck disable=SC2207
SH=($(cd "$ROOT" && git ls-files '*.sh'))
dk -w /m koalaman/shellcheck:stable -S warning -x "${SH[@]}"
echo "ok (${#SH[@]} dosya)"

step "2/7 python (3.6 soz dizimi)"
# shellcheck disable=SC2207
PY=($(cd "$ROOT" && git ls-files '*.py'))
dk python:3.6-slim python -c '
import ast, sys
for f in sys.argv[1:]:
    ast.parse(open("/m/" + f).read(), f)
print("ok (%d dosya)" % (len(sys.argv) - 1))' "${PY[@]}"

step "3/7 render (varyantlar: ${#VARIANTS[@]})"
printf '%s\n' "${VARIANTS[@]}" > "$OUT/variants"
(cd "$ROOT" && git ls-files lb-nodes hf-nodes) > "$OUT/templates"
dk ubuntu:24.04 bash -c '
set -uo pipefail
fail=0
while IFS="|" read -r name overrides; do
    rm -rf /w; cp -r /m /w; rm -f /w/variables.env.local
    printf "%b\n" "$overrides" > /w/variables.env.local
    mkdir -p "/out/$name"
    while read -r f; do
        dst="/out/$name/$(echo "$f" | tr / _)"
        if ( cd /w; source scripts/lib.sh; load_vars /w 2>/dev/null
             # install-hf-node.sh bunlari makineye gore hesaplar
             SVC_USER=syslog SVC_GROUP=adm HOST_SEGMENT=5
             case "$f" in
                 */haproxy.cfg)            render_haproxy_cfg "$f" "$dst" ;;
                 */keepalived.conf)        render_keepalived_conf "$f" "$dst" ;;
                 */49-hf-syslog-listener.conf) render_rsyslog_conf "$f" "$dst" ;;
                 *)                        render "$f" "$dst" ;;
             esac ) 2>/tmp/err; then :; else
            echo "FAIL [$name] $f"; sed "s/^/    /" /tmp/err; fail=1
        fi
    done < /out/templates
    echo "ok [$name] $(ls /out/$name | wc -l) dosya"
done < /out/variants
exit $fail'

step "4/7 haproxy -c (haproxy:3.4)"
for v in "${VARIANTS[@]}"; do
    name="${v%%|*}"
    # stats socket dizini (/run/haproxy) konteynerde yok
    sed '/stats socket/d' "$OUT/$name/lb-nodes_common_haproxy_haproxy.cfg" > "$OUT/$name/haproxy-ci.cfg"
    dk haproxy:3.4 haproxy -c -q -f "/out/$name/haproxy-ci.cfg"
    echo "ok [$name]"
done

step "5/7 keepalived -t (auth_hmac haric)"
dk alpine:3 sh -c '
set -e
apk add -q keepalived >/dev/null 2>&1
mkdir -p /etc/keepalived
for s in check_haproxy.sh check_hf_ready.sh notify.sh; do printf "#!/bin/sh\nexit 0\n" > /etc/keepalived/$s; done
chmod 700 /etc/keepalived/*.sh
for f in /out/*/lb-nodes_lb[12]_keepalived_keepalived.conf; do
    sed "/auth_hmac {/,/^    }/d" "$f" > /tmp/k.conf
    out="$(keepalived -t -f /tmp/k.conf 2>&1)" || { echo "FAIL $f"; echo "$out"; exit 1; }
    [ -z "$out" ] || { echo "FAIL (uyari) $f"; echo "$out"; exit 1; }
    echo "ok $(basename "$(dirname "$f")")/$(basename "$f" | sed "s/_keepalived_keepalived.conf//;s/lb-nodes_//")"
done'

step "6/7 rsyslogd -N1"
dk ubuntu:24.04 bash -c '
set -e
apt-get -qq update >/dev/null && apt-get -qq install -y rsyslog >/dev/null 2>&1
for f in /out/*/hf-nodes_rsyslog.d_49-hf-syslog-listener.conf; do
    cp "$f" /etc/rsyslog.d/49-ci.conf; rsyslogd -N1 >/dev/null 2>&1 || { rsyslogd -N1; exit 1; }
    echo "ok rsyslog $(rsyslogd -v | head -1 | cut -d, -f1) $(basename "$(dirname "$f")")"
done'
dk centos:7 bash -c '
set -e
sed -i -e "s/^mirrorlist/#mirrorlist/" -e "s|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|" /etc/yum.repos.d/*.repo
yum install -y -q rsyslog >/dev/null 2>&1
sed -i "/imjournal/d;/IMJournalStateFile/d" /etc/rsyslog.conf
for f in /out/*/hf-nodes_rsyslog.d_49-hf-syslog-listener.conf; do
    cp "$f" /etc/rsyslog.d/49-ci.conf; rsyslogd -N1 >/dev/null 2>&1 || { rsyslogd -N1; exit 1; }
    echo "ok rsyslog $(rsyslogd -v | head -1 | cut -d, -f1) $(basename "$(dirname "$f")")"
done'

step "7/7 lb-status uctan uca testi"
docker run --rm -v "$ROOT":/m:ro -v "$ROOT/tests/lb-status":/t:ro ubuntu:24.04 bash /t/run.sh

printf '\nTUM KONTROLLER GECTI\n'
