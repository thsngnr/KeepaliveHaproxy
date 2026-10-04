#!/bin/bash
# keepalived durum degisikligi bildirimi. Her olay:
#   - syslog'a (logger -t keepalived-notify), her zaman
#   - Splunk HEC'e (index <STATUS_INDEX>, sourcetype lb:event:hec), token varsa.
#     Once yerel HAProxy (127.0.0.1:<HEC_PORT>), olmazsa sirayla dogrudan
#     HF'lere: FAULT (HAProxy coktu) aninda da olay Splunk'a ulasir.
#   - Slack'e, sadece SLACK_ENABLED=yes ve webhook varsa (varsayilan kapali;
#     Slack uyarisi Splunk alert'lerinden de uretilebilir).
# Root'a ait, baskasi yazamaz (chmod 700) -- keepalived enable_script_security.
#
# Cagrilma bicimleri:
#   VRRP:        notify "/etc/keepalived/notify.sh"
#                -> keepalived ekler: INSTANCE <ad> <MASTER|BACKUP|FAULT|STOP> <oncelik>
#   real_server: notify_up/notify_down "/etc/keepalived/notify.sh rs <up|down> <hf-ip> <tcp|udp>"
#
# real_server olaylarini sadece VIP'i tutan LB gonderir: iki LB de ayni HF'leri
# kontrol ettigi icin aksi halde her olay iki kez gelir. VRRP olaylarini her
# LB kendisi icin gonderir.
set -uo pipefail

VIP="<VIP_IP>"
SYSLOG_PORT="<SYSLOG_PORT>"
SITE="<ALERT_SITE_NAME>"
SLACK_ENABLED="<SLACK_ENABLED>"
STATUS_INDEX="<STATUS_INDEX>"
HEC_PORT="<HEC_PORT>"
HEC_SSL="<HEC_SSL>"
HF_NODES="<HF_NODES>"
KEYS_DIR="/etc/keepalived/keys"

HOST="$(hostname -s)"
PREFIX="[${SITE:+${SITE} / }${HOST}]"

holds_vip() { ip -4 -o addr show | grep -q "inet ${VIP}/"; }
# JSON string icin \ " ve satir sonlarini kacir
json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk '{printf "%s%s", (NR>1 ? "\\n" : ""), $0}'; }

msg=""; ev_type=""; ev_state=""; ev_hf=""; ev_proto=""; ev_remaining=""; sev="info"
case "${1:-}" in
    INSTANCE|GROUP)
        ev_type="vrrp"; ev_state="${3:-?}"
        case "$ev_state" in
            MASTER) msg=":large_green_circle: ${PREFIX} VRRP ${2:-?} -> MASTER (VIP ${VIP} bu LB'de)" ;;
            BACKUP) msg=":white_circle: ${PREFIX} VRRP ${2:-?} -> BACKUP" ;;
            FAULT)  msg=":red_circle: ${PREFIX} VRRP ${2:-?} -> FAULT (chk_haproxy basarisiz: HAProxy/HEC dinlemiyor)"; sev="crit" ;;
            *)      msg=":warning: ${PREFIX} VRRP ${2:-?} -> ${ev_state}"; sev="warn" ;;
        esac
        ;;
    rs)
        ev_type="syslog_pool"; ev_state="${2:-?}"; ev_hf="${3:-?}"; ev_proto="${4:-?}"
        holds_vip || exit 0
        if [ "$ev_state" = "up" ]; then
            msg=":large_green_circle: ${PREFIX} HF ${ev_hf} syslog/${ev_proto} havuzuna GIRDI"
        else
            sev="warn"
            msg=":red_circle: ${PREFIX} HF ${ev_hf} syslog/${ev_proto} havuzundan CIKTI"
            flag="-t"; [ "$ev_proto" = "udp" ] && flag="-u"
            # Dusen HF'yi acikca disla: notify_down, real_server IPVS'ten
            # cikarilmadan once de cagrilsa sayi dogru kalir.
            ev_remaining="$(ipvsadm -L -n "$flag" "${VIP}:${SYSLOG_PORT}" 2>/dev/null \
                | grep -- '->.*Route' | grep -vc -- "-> ${ev_hf}:")"
            if [ "${ev_remaining:-0}" -eq 0 ]; then
                sev="crit"
                msg="${msg}"$'\n'":rotating_light: KRITIK ${PREFIX} syslog/${ev_proto} havuzunda HIC HF KALMADI -- ${VIP}:${SYSLOG_PORT}/${ev_proto} trafigi kayboluyor"
            else
                msg="${msg} (kalan: ${ev_remaining})"
            fi
        fi
        ;;
    *)
        ev_type="unknown"; sev="warn"
        msg=":warning: ${PREFIX} keepalived notify bilinmeyen cagri: $*"
        ;;
esac

logger -t keepalived-notify -- "$msg"

send_hec() {
    [ -n "$STATUS_INDEX" ] || return 0
    local token scheme payload target entry
    token="$(head -n1 "${KEYS_DIR}/status-hec-token" 2>/dev/null)"
    [ -n "$token" ] || return 0
    scheme="http"; [ "$HEC_SSL" = "1" ] && scheme="https"
    payload="$(printf '{"time":%s,"host":"%s","source":"keepalived-notify","sourcetype":"lb:event:hec","index":"%s","event":{"site":"%s","lb":"%s","type":"%s","state":"%s","hf":"%s","proto":"%s","remaining":"%s","severity":"%s","message":"%s"}}' \
        "$(date +%s)" "$HOST" "$STATUS_INDEX" "$(json_str "$SITE")" "$HOST" "$ev_type" \
        "$(json_str "$ev_state")" "$ev_hf" "$ev_proto" "$ev_remaining" "$sev" "$(json_str "$msg")")"
    for target in 127.0.0.1 $(for entry in $HF_NODES; do printf '%s ' "${entry#*:}"; done); do
        # -k: localhost/HF IP ile baglaniliyor, sertifika adi eslesmez
        if curl -sSf -k -m 3 -H "Authorization: Splunk ${token}" \
                --data "$payload" "${scheme}://${target}:${HEC_PORT}/services/collector/event" >/dev/null 2>&1; then
            return 0
        fi
    done
    logger -t keepalived-notify -- "Splunk HEC'e gonderilemedi (yerel HAProxy ve tum HF'ler denendi)"
}

send_slack() {
    [ "$SLACK_ENABLED" = "yes" ] || return 0
    [ -s "${KEYS_DIR}/slack-webhook" ] || return 0
    local url proxy_args=() out
    url="$(head -n1 "${KEYS_DIR}/slack-webhook")"
    [ -s "${KEYS_DIR}/slack-proxy" ] && proxy_args=(--proxy "$(head -n1 "${KEYS_DIR}/slack-proxy")")
    if ! out="$(curl -sS -m 5 "${proxy_args[@]}" -H 'Content-type: application/json' \
            --data "{\"text\":\"$(json_str "$msg")\"}" "$url" 2>&1)"; then
        logger -t keepalived-notify -- "Slack gonderilemedi: ${out}"
    fi
}

# keepalived'i bekletme: gonderimler arka planda.
( send_hec; send_slack ) </dev/null >/dev/null 2>&1 &
exit 0
