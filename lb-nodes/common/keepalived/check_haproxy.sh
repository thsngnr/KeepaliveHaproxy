#!/bin/bash
# keepalived vrrp_script target. Root-owned, not group/world-writable
# (chmod 700, chown root:root after install).
# Healthy = haproxy process running AND locally listening on HEC port.
# Syslog 514/tcp+udp is owned by IPVS-DR, not haproxy, so this check does
# not look at 514 at all.
# Exit 0 = healthy, non-zero = unhealthy (keepalived treats non-zero as
# check failure).
set -euo pipefail

HEC_PORT="<HEC_PORT>"

if ! pgrep -x haproxy >/dev/null 2>&1; then
    exit 1
fi

if ! ss -H -ltn "sport = :${HEC_PORT}" | grep -q '^LISTEN'; then
    exit 1
fi

exit 0
