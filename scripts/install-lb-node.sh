#!/bin/bash
# LB node (lb1 veya lb2) kurulum script'i. Bu repo'nun kök dizininden
# çalıştır (lb-nodes/ ve variables.env'in göründüğü yerden):
#
#   ./scripts/install-lb-node.sh lb1
#   ./scripts/install-lb-node.sh lb2
#
# Önkoşul: variables.env dolduruldu, VRRP key'i gen-vrrp-key.sh ile
# üretildi ve /etc/keepalived/keys/vrrp200'e yerleştirildi (iki node'da
# aynı dosya).
set -euo pipefail

ROLE="${1:?lb1 veya lb2 ver}"
case "$ROLE" in
    lb1|lb2) ;;
    *) echo "Kullanım: $0 lb1|lb2" >&2; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/variables.env"

render() {
    # $1=src $2=dst -- her <PLACEHOLDER> değerini variables.env'den doldurur
    sed \
        -e "s/<VIP_IP>/${VIP_IP}/g" \
        -e "s/<LB1_IP>/${LB1_IP}/g" \
        -e "s/<LB2_IP>/${LB2_IP}/g" \
        -e "s/<LB1_ROUTER_ID>/${LB1_ROUTER_ID}/g" \
        -e "s/<LB2_ROUTER_ID>/${LB2_ROUTER_ID}/g" \
        -e "s/<VRRP_VIRTUAL_ROUTER_ID>/${VRRP_VIRTUAL_ROUTER_ID}/g" \
        -e "s/<VRRP_INTERFACE>/${VRRP_INTERFACE}/g" \
        -e "s/<HF1_IP>/${HF1_IP}/g" \
        -e "s/<HF2_IP>/${HF2_IP}/g" \
        -e "s/<HF3_IP>/${HF3_IP}/g" \
        -e "s/<HF1_NAME>/${HF1_NAME}/g" \
        -e "s/<HF2_NAME>/${HF2_NAME}/g" \
        -e "s/<HF3_NAME>/${HF3_NAME}/g" \
        -e "s/<SYSLOG_PORT>/${SYSLOG_PORT}/g" \
        -e "s/<HEC_PORT>/${HEC_PORT}/g" \
        -e "s/<READYZ_PORT>/${READYZ_PORT}/g" \
        "$1" > "$2"
}

echo "== $ROLE: paketler =="
if command -v apt-get >/dev/null; then
    apt-get update -qq
    apt-get install -y haproxy keepalived ipvsadm ipset
fi
modprobe ip_vs 2>/dev/null || true

echo "== $ROLE: haproxy.cfg =="
render "$HERE/lb-nodes/common/haproxy/haproxy.cfg" /etc/haproxy/haproxy.cfg

echo "== $ROLE: check_haproxy.sh / check_hf_ready.sh =="
render "$HERE/lb-nodes/common/keepalived/check_haproxy.sh" /etc/keepalived/check_haproxy.sh
render "$HERE/lb-nodes/common/keepalived/check_hf_ready.sh" /etc/keepalived/check_hf_ready.sh
chmod 700 /etc/keepalived/check_haproxy.sh /etc/keepalived/check_hf_ready.sh
chown root:root /etc/keepalived/check_haproxy.sh /etc/keepalived/check_hf_ready.sh

echo "== $ROLE: keepalived.conf =="
if [ ! -f /etc/keepalived/keys/vrrp200 ]; then
    echo "UYARI: /etc/keepalived/keys/vrrp200 yok. Önce gen-vrrp-key.sh çalıştır" \
         "(bir node'da üret, diğerine kopyala), sonra bu script'i tekrar çalıştır." >&2
    exit 1
fi
render "$HERE/lb-nodes/$ROLE/keepalived/keepalived.conf" /etc/keepalived/keepalived.conf

echo "== $ROLE: config doğrulama =="
haproxy -c -f /etc/haproxy/haproxy.cfg
keepalived -t -f /etc/keepalived/keepalived.conf

echo "== $ROLE: servisler =="
systemctl enable --now haproxy
systemctl restart haproxy
systemctl enable --now keepalived
systemctl restart keepalived

echo "== $ROLE: durum =="
systemctl is-active haproxy keepalived
ipvsadm -L -n
echo "Tamam. Diğer node'da da bu script'i çalıştırmayı unutma."
