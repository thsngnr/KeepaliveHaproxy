#!/bin/bash
# IPVS dagilim kontrolu (LB node). systemd timer ile periyodik calisir.
#
# Sorun: bir HF kisa sureligine havuzdan cikarsa akislari diger HF'lere kayar;
# HF geri dondugunde IPVS mevcut akislari geri tasimaz ve yuk tek HF'te kalir.
# Bu script master LB'de HF basina baglanti sayisini olcer; TUM HF'ler havuzdaysa
# ve dagilim bozuksa uyari verir (REBALANCE_MODE=alert) veya master'da keepalived'i
# yeniden baslatarak VRRP'yi karsi node'a gecirir (REBALANCE_MODE=auto): yeni
# master'in baglanti tablosu bostur, TCP istemcileri yeniden baglanir, akislar
# yeniden dagilir.
#
# Ayarlar: /etc/ipvs-rebalance.env (install-lb-node.sh yazar). Log: logger -t ipvs-rebalance
set -uo pipefail
source /etc/ipvs-rebalance.env

MODE="${REBALANCE_MODE:-alert}"            # off | alert | auto
SKEW_RATIO="${REBALANCE_SKEW_RATIO:-0.5}"  # en az yuklu HF < SKEW_RATIO * adil pay ise dengesiz
MIN_CONNS="${REBALANCE_MIN_CONNS:-30}"     # toplam akis bundan azsa karar verme
STABLE_SECS="${REBALANCE_STABLE_SECS:-600}" # master olduktan bu kadar sn sonra degerlendir
COOLDOWN_SECS="${REBALANCE_COOLDOWN_SECS:-21600}" # iki otomatik islem arasi min sure
NEED_BAD_CHECKS="${REBALANCE_BAD_CHECKS:-2}"  # ust uste kac olcumde dengesiz olmali
STATE=/run/ipvs-rebalance
mkdir -p "$STATE"
log() { logger -t ipvs-rebalance -p daemon.warning -- "$*"; echo "$*"; }

[ "$MODE" = "off" ] && exit 0

# Sadece VIP'i tutan (master) node degerlendirir.
if ! ip -4 -o addr show | grep -q "inet ${VIP_IP}/"; then
    rm -f "$STATE/master_since" "$STATE/bad_count"; exit 0
fi
NOW=$(date +%s)
[ -f "$STATE/master_since" ] || echo "$NOW" > "$STATE/master_since"
if [ $(( NOW - $(cat "$STATE/master_since") )) -lt "$STABLE_SECS" ]; then exit 0; fi

# Tum HF'ler hem TCP hem UDP havuzunda olmali; biri havuz disindaysa bu
# dagilim sorunu degil arizadir (o durumda islem yapma).
POOL=$(ipvsadm -L -n)
for hf in $HF_IPS; do
    n=$(echo "$POOL" | grep -c "${hf}:${SYSLOG_PORT}")
    if [ "$n" -lt 2 ]; then echo "HF ${hf} havuzda degil, degerlendirme atlandi"; echo 0 > "$STATE/bad_count"; exit 0; fi
done

# HF basina akis sayisi: TCP sadece ESTABLISHED, UDP tum kayitlar.
CONNS=$(ipvsadm -L -n -c | awk -v v="${VIP_IP}:${SYSLOG_PORT}" '
    ($1=="TCP" && $3=="ESTABLISHED" && $5==v) || ($1=="UDP" && $5==v) {split($6,d,":"); c[d[1]]++}
    END {for (k in c) print k, c[k]}')
TOTAL=0; MIN=999999999; NHF=0; SUMMARY=""
for hf in $HF_IPS; do
    c=$(echo "$CONNS" | awk -v h="$hf" '$1==h {print $2}'); c=${c:-0}
    TOTAL=$((TOTAL + c)); NHF=$((NHF + 1)); SUMMARY="$SUMMARY $hf=$c"
    [ "$c" -lt "$MIN" ] && MIN=$c
done
echo "$SUMMARY total=$TOTAL" > "$STATE/last_summary"
[ "$TOTAL" -lt "$MIN_CONNS" ] && { echo 0 > "$STATE/bad_count"; exit 0; }

# dengesiz mi: min < SKEW_RATIO * (TOTAL/NHF)  (tamsayi aritmetigi, x1000)
if [ $(( MIN * 1000 * NHF )) -ge "$(awk -v r="$SKEW_RATIO" -v t="$TOTAL" 'BEGIN{printf "%d", r*t*1000}')" ]; then
    echo 0 > "$STATE/bad_count"; exit 0
fi
BAD=$(( $(cat "$STATE/bad_count" 2>/dev/null || echo 0) + 1 )); echo "$BAD" > "$STATE/bad_count"
log "DAGILIM DENGESIZ (${BAD}/${NEED_BAD_CHECKS}):${SUMMARY} total=${TOTAL} (mode=${MODE})"
[ "$BAD" -lt "$NEED_BAD_CHECKS" ] && exit 0
[ "$MODE" = "alert" ] && exit 0

# --- auto: guvenlik kontrolleri ---
LAST=$(cat "$STATE/last_action" 2>/dev/null || echo 0)
if [ $(( NOW - LAST )) -lt "$COOLDOWN_SECS" ]; then log "cooldown aktif, islem yapilmadi"; exit 0; fi
if ! ping -c1 -W2 "$PEER_IP" >/dev/null 2>&1 || ! timeout 3 bash -c "</dev/tcp/${PEER_IP}/${HEC_PORT}" 2>/dev/null; then
    log "karsi LB (${PEER_IP}) hazir degil (ping/haproxy:${HEC_PORT}); gecis YAPILMADI"; exit 0
fi
echo "$NOW" > "$STATE/last_action"
log "yeniden dengeleme: keepalived yeniden baslatiliyor, VRRP ${PEER_IP}'e gececek"
systemctl restart keepalived
