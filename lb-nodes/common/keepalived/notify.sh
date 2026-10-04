#!/bin/bash
# keepalived durum degisikligi bildirimi: her zaman syslog'a (logger), webhook
# tanimliysa Slack'e. Root'a ait, baskasi yazamaz (chmod 700) -- keepalived
# enable_script_security bunu sart kosar.
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
WEBHOOK_FILE="/etc/keepalived/keys/slack-webhook"
PROXY_FILE="/etc/keepalived/keys/slack-proxy"

HOST="$(hostname -s)"
PREFIX="[${SITE:+${SITE} / }${HOST}]"

holds_vip() { ip -4 -o addr show | grep -q "inet ${VIP}/"; }

msg=""
case "${1:-}" in
    INSTANCE|GROUP)
        state="${3:-?}"
        case "$state" in
            MASTER) msg=":large_green_circle: ${PREFIX} VRRP ${2:-?} -> MASTER (VIP ${VIP} bu LB'de)" ;;
            BACKUP) msg=":white_circle: ${PREFIX} VRRP ${2:-?} -> BACKUP" ;;
            FAULT)  msg=":red_circle: ${PREFIX} VRRP ${2:-?} -> FAULT (chk_haproxy basarisiz: HAProxy/HEC dinlemiyor)" ;;
            *)      msg=":warning: ${PREFIX} VRRP ${2:-?} -> ${state}" ;;
        esac
        ;;
    rs)
        dir="${2:-?}"; hf="${3:-?}"; proto="${4:-?}"
        holds_vip || exit 0
        if [ "$dir" = "up" ]; then
            msg=":large_green_circle: ${PREFIX} HF ${hf} syslog/${proto} havuzuna GIRDI"
        else
            msg=":red_circle: ${PREFIX} HF ${hf} syslog/${proto} havuzundan CIKTI"
            flag="-t"; [ "$proto" = "udp" ] && flag="-u"
            # Dusen HF'yi acikca disla: notify_down, real_server IPVS'ten
            # cikarilmadan once de cagrilsa sayi dogru kalir.
            remaining="$(ipvsadm -L -n "$flag" "${VIP}:${SYSLOG_PORT}" 2>/dev/null \
                | grep -- '->.*Route' | grep -vc -- "-> ${hf}:")"
            if [ "${remaining:-0}" -eq 0 ]; then
                msg="${msg}"$'\n'":rotating_light: KRITIK ${PREFIX} syslog/${proto} havuzunda HIC HF KALMADI -- ${VIP}:${SYSLOG_PORT}/${proto} trafigi kayboluyor"
            else
                msg="${msg} (kalan: ${remaining})"
            fi
        fi
        ;;
    *)
        msg=":warning: ${PREFIX} keepalived notify bilinmeyen cagri: $*"
        ;;
esac

logger -t keepalived-notify -- "$msg"

[ -s "$WEBHOOK_FILE" ] || exit 0
url="$(head -n1 "$WEBHOOK_FILE")"
proxy_args=()
[ -s "$PROXY_FILE" ] && proxy_args=(--proxy "$(head -n1 "$PROXY_FILE")")

# JSON icin \ " ve satir sonlarini kacir
json_text="$(printf '%s' "$msg" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk '{printf "%s%s", (NR>1 ? "\\n" : ""), $0}')"

# keepalived'i bekletme: arka planda, kisa zaman asimiyla. Hata syslog'a.
(
    if ! out="$(curl -sS -m 5 "${proxy_args[@]}" -H 'Content-type: application/json' \
            --data "{\"text\":\"${json_text}\"}" "$url" 2>&1)"; then
        logger -t keepalived-notify -- "Slack gonderilemedi: ${out}"
    fi
) </dev/null >/dev/null 2>&1 &
exit 0
