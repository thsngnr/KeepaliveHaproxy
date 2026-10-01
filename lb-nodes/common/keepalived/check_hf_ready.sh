#!/bin/bash
# Keepalived MISC_CHECK for a single HF's UDP/514 readiness.
# Usage: check_hf_ready.sh <target-ip> [port]
#
# LVS/Keepalived's checker subsystem has no native "rise" (consecutive
# successes required before marking a real_server back up) -- a single
# successful check brings it straight back into the pool. `retry`/
# `delay_before_retry` on the MISC_CHECK block cover the "fall" side
# (consecutive failures before marking down) but there is no equivalent
# knob for recovery. This script implements rise=2 itself: it only
# reports success (exit 0) once the underlying readyz check has passed on
# two consecutive invocations. Any single failure resets the counter to 0
# and reports failure immediately.
set -euo pipefail

TARGET="${1:?target IP required}"
PORT="${2:-<READYZ_PORT>}"
# Syslog and HEC track independent health -- this script is wired into the
# syslog UDP virtual_server only, so it always hits the syslog-only endpoint.
URL="http://${TARGET}:${PORT}/readyz/syslog"
RISE_THRESHOLD=2

STATE_DIR="/run/keepalived-misc"
STATE_FILE="${STATE_DIR}/${TARGET}.successes"
LOCK_FILE="${STATE_DIR}/${TARGET}.lock"
install -d -m 0755 "$STATE_DIR" 2>/dev/null || true

TMPFILE="$(mktemp /tmp/readyz_XXXXXX.json)"
trap 'rm -f "$TMPFILE"' EXIT

if HTTP_CODE="$(curl -s -m 2 -o "$TMPFILE" -w '%{http_code}' "$URL" 2>/dev/null)"; then
    CURL_EXIT=0
else
    CURL_EXIT=$?
fi

underlying_ok=0
if [ "$CURL_EXIT" -eq 0 ] && [ "$HTTP_CODE" = "200" ]; then
    underlying_ok=1
fi

exec 9>"$LOCK_FILE"
flock 9

count=0
[ -f "$STATE_FILE" ] && count="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
case "$count" in ''|*[!0-9]*) count=0 ;; esac

if [ "$underlying_ok" -eq 1 ]; then
    count=$((count + 1))
    if [ "$count" -gt "$RISE_THRESHOLD" ]; then
        count=$RISE_THRESHOLD
    fi
    echo "$count" > "$STATE_FILE"
    flock -u 9

    if [ "$count" -ge "$RISE_THRESHOLD" ]; then
        logger -t keepalived-misc "HF ${TARGET} ready (consecutive successes: ${count}/${RISE_THRESHOLD})"
        exit 0
    else
        logger -t keepalived-misc "HF ${TARGET} underlying check passed but rise threshold not yet met (${count}/${RISE_THRESHOLD})"
        exit 1
    fi
else
    echo 0 > "$STATE_FILE"
    flock -u 9

    if [ "$CURL_EXIT" -ne 0 ]; then
        logger -t keepalived-misc "HF ${TARGET} curl error (exit ${CURL_EXIT}), success counter reset"
    else
        REASON="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason","unknown"))' <"$TMPFILE" 2>/dev/null)"
        logger -t keepalived-misc "HF ${TARGET} not ready: http=${HTTP_CODE} reason=${REASON:-unparseable}, success counter reset"
    fi
    exit 1
fi
