#!/bin/bash
# LB node (lb1 veya lb2) kurulum script'i. Bu repo'nun kök dizininden
# çalıştır (lb-nodes/ ve variables.env'in göründüğü yerden):
#
#   ./scripts/install-lb-node.sh lb1
#   ./scripts/install-lb-node.sh lb2
#
# İnternete çıkamayan (air-gapped) bir host için OFFLINE MOD:
#   ./scripts/install-lb-node.sh lb1 /path/to/offline-bundle
#
# offline-bundle klasörü scripts/prepare-offline-bundle.sh ile internetli,
# HEDEFLE AYNI Ubuntu sürümündeki bir makinede önceden hazırlanır, sonra
# scp/usb/vb. ile air-gapped host'a taşınır. İçeriği:
#   offline-bundle/debs/*.deb              (apt paketleri + bağımlılıkları)
#   offline-bundle/keepalived-2.4.3.tar.gz (kaynak tarball)
# Offline modda apt-get update/curl HİÇ çalıştırılmaz.
#
# Önkoşul: variables.env dolduruldu, VRRP key'i gen-vrrp-key.sh ile
# üretildi ve /etc/keepalived/keys/vrrp200'e yerleştirildi (iki node'da
# aynı dosya).
set -euo pipefail

ROLE="${1:?lb1 veya lb2 ver}"
case "$ROLE" in
    lb1|lb2) ;;
    *) echo "Kullanım: $0 lb1|lb2 [offline-bundle-klasörü]" >&2; exit 1 ;;
esac

OFFLINE_DIR="${2:-}"
if [ -n "$OFFLINE_DIR" ]; then
    OFFLINE_DIR="$(cd "$OFFLINE_DIR" && pwd)"
    [ -d "$OFFLINE_DIR/debs" ] || { echo "HATA: $OFFLINE_DIR/debs klasörü yok." >&2; exit 1; }
    echo "Offline mod: $OFFLINE_DIR kullanılıyor (apt-get update / curl indirme YOK)"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/variables.env"

# Yanlis doldurulmus variables.env, VRRP'yi sessizce bozar (unicast_src_ip
# baska makinenin IP'si olursa node'lar birbirinin advert'ini gormez ->
# split-brain). Baslamadan once dogrula.
if [ "$LB1_IP" = "$LB2_IP" ]; then
    echo "HATA: LB1_IP ve LB2_IP ayni (${LB1_IP}). variables.env'i duzelt." >&2; exit 1
fi
if [ "$ROLE" = "lb1" ]; then OWN_IP="$LB1_IP"; else OWN_IP="$LB2_IP"; fi
if ! ip -4 -o addr show | grep -q "inet ${OWN_IP}/"; then
    echo "HATA: rol=${ROLE} icin beklenen IP ${OWN_IP} bu makinede tanimli degil." >&2
    echo "      variables.env'deki LB1_IP/LB2_IP degerlerini ve bu script'e verdigin rolu (lb1|lb2) kontrol et." >&2
    exit 1
fi

# HF listesi: variables.env'de HF_IPS (bosluk ayrili) ve opsiyonel HF_NAMES.
# HF sayisi serbest (en az 1); sabit HF1/HF2/HF3 degiskenleri YOK.
HF_IPS="${HF_IPS:-}"
read -r -a HF_IP_ARR <<< "$HF_IPS"
if [ "${#HF_IP_ARR[@]}" -lt 1 ]; then
    echo "HATA: variables.env'de HF_IPS bos. Ornek: HF_IPS=\"10.0.0.21 10.0.0.22\"" >&2; exit 1
fi
if [ -z "${HF_NAMES:-}" ]; then
    HF_NAMES=""; i=1
    for _ in "${HF_IP_ARR[@]}"; do HF_NAMES="$HF_NAMES splunk-hf-$i"; i=$((i + 1)); done
    HF_NAMES="${HF_NAMES# }"
fi
read -r -a HF_NAME_ARR <<< "$HF_NAMES"
if [ "${#HF_NAME_ARR[@]}" -ne "${#HF_IP_ARR[@]}" ]; then
    echo "HATA: HF_IPS (${#HF_IP_ARR[@]}) ve HF_NAMES (${#HF_NAME_ARR[@]}) eleman sayisi esit olmali." >&2; exit 1
fi
if [ "$(printf '%s\n' "${HF_IP_ARR[@]}" | sort | uniq -d | wc -l)" -ne 0 ] || \
   [ "$(printf '%s\n' "${HF_NAME_ARR[@]}" | sort | uniq -d | wc -l)" -ne 0 ]; then
    echo "HATA: HF_IPS / HF_NAMES icinde tekrar eden deger var." >&2; exit 1
fi
for ip in "${HF_IP_ARR[@]}"; do
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "HATA: gecersiz HF IP: $ip" >&2; exit 1; }
done
echo "HF sayisi: ${#HF_IP_ARR[@]} (${HF_IPS})"

# Sablondaki #HF_EACH_BEGIN# ... #HF_EACH_END# bloklarini her HF icin cogaltir;
# blok icinde <HF_IP> ve <HF_NAME> doldurulur.
expand_hf() {
    awk -v ips="$HF_IPS" -v names="$HF_NAMES" '
        BEGIN { n = split(ips, ip, " "); split(names, nm, " ") }
        /#HF_EACH_BEGIN#/ { inb = 1; blk = ""; next }
        /#HF_EACH_END#/   { inb = 0
                            for (i = 1; i <= n; i++) { b = blk; gsub(/<HF_IP>/, ip[i], b); gsub(/<HF_NAME>/, nm[i], b); printf "%s", b }
                            next }
        inb { blk = blk $0 "\n"; next }
        { print }' "$1"
}

render() {
    # $1=src $2=dst -- her <PLACEHOLDER> değerini variables.env'den doldurur
    expand_hf "$1" | sed \
        -e "s/<VIP_IP>/${VIP_IP}/g" \
        -e "s/<VIP_PREFIX>/${VIP_PREFIX:-32}/g" \
        -e "s/<LB1_IP>/${LB1_IP}/g" \
        -e "s/<LB2_IP>/${LB2_IP}/g" \
        -e "s/<LB1_ROUTER_ID>/${LB1_ROUTER_ID}/g" \
        -e "s/<LB2_ROUTER_ID>/${LB2_ROUTER_ID}/g" \
        -e "s/<VRRP_VIRTUAL_ROUTER_ID>/${VRRP_VIRTUAL_ROUTER_ID}/g" \
        -e "s/<VRRP_INTERFACE>/${VRRP_INTERFACE}/g" \
        -e "s/<SYSLOG_PORT>/${SYSLOG_PORT}/g" \
        -e "s/<HEC_PORT>/${HEC_PORT}/g" \
        -e "s/<READYZ_PORT>/${READYZ_PORT}/g" \
        -e "s/<DS_IP>/${DS_IP:-}/g" \
        -e "s/<DS_PORT>/${DS_PORT:-8089}/g" \
        -e "s/<DS_LISTEN_PORT>/${DS_LISTEN_PORT:-8089}/g" \
        > "$2"
}

# haproxy hariç -- o ayrıca (en güncel uygun seri) kuruluyor,
# bkz. aşağıdaki "haproxy" bölümü. Gerisi ipvsadm/ipset (LB için) ve
# keepalived'i kaynaktan derlemek için gerekenler.
PACKAGES=(ipvsadm ipset build-essential libssl-dev libnl-3-dev
    libnl-genl-3-dev libnfnetlink-dev libipset-dev libsnmp-dev libmagic-dev
    pkg-config libxtables-dev libip4tc-dev libip6tc-dev)

echo "== $ROLE: paketler =="
if [ -n "$OFFLINE_DIR" ]; then
    # apt-get update/network YOK -- sadece offline-bundle/debs içindeki
    # .deb dosyalarını kur (haproxy dahil -- bundle'da hazırlanan sürüm).
    # Bağımlılık çözümü için modern apt'ın yerel .deb dosyalarını doğrudan
    # kabul etmesine güveniyoruz; bundle'da transitive bağımlılıklar da
    # olmalı (prepare-offline-bundle.sh zaten hepsini indiriyor).
    apt-get install -y "$OFFLINE_DIR"/debs/*.deb
else
    apt-get update -qq
    apt-get install -y "${PACKAGES[@]}"

    echo "== $ROLE: haproxy (en guncel uygun seri) =="
    # Ubuntu'nun kendi reposu eski haproxy tasir (noble'da 2.8); guncel seri
    # vbernat PPA'sindan veya haproxy.debian.net'ten, kod adina uygun olan secilir.
    source "$HERE/scripts/lib-haproxy-repo.sh"
    setup_haproxy_repo
    apt-get install -y "$HAPROXY_PKG"
fi
modprobe ip_vs 2>/dev/null || true
# ip_vs acilista yuklenmezse systemd-sysctl, net.ipv4.vs.* anahtarlari henuz
# yokken calisir ve 61-ipvs-expire-nodest.conf SESSIZCE uygulanmaz (reboot
# sonrasi expire_nodest_conn=0'a doner). modules-load, sysctl'den once calisir.
echo ip_vs > /etc/modules-load.d/ip_vs.conf

echo "== $ROLE: expire_nodest_conn (IPVS'in dusen real_server'a sabitlenmis akislari kurtarmasi) =="
cp "$HERE/lb-nodes/common/sysctl/61-ipvs-expire-nodest.conf" /etc/sysctl.d/61-ipvs-expire-nodest.conf
sysctl --system >/dev/null 2>&1

echo "== $ROLE: keepalived (kaynaktan derleme) =="
# Ubuntu'nun apt reposundaki keepalived (ör. 24.04/26.04'te 1:2.3.4-1)
# auth_hmac / use_vmac / vmac_xmit_base gibi bu config'in kullandığı
# özellikleri desteklemiyor (bunlar daha yeni keepalived sürümlerinde
# geldi). Bu yüzden apt'tan KURMUYORUZ -- 2.4.3'ü kaynaktan derliyoruz.
# (apt'ın kendi keepalived paketi offline bundle'a da dahil DEĞİL --
# prepare-offline-bundle.sh onu bilerek indirmez.)
KA_VERSION="2.4.3"
if ! keepalived --version 2>&1 | grep -q "v${KA_VERSION}"; then
    apt-get purge -y keepalived >/dev/null 2>&1 || true
    mkdir -p /usr/src
    cd /usr/src
    if [ -n "$OFFLINE_DIR" ]; then
        [ -f "$OFFLINE_DIR/keepalived-${KA_VERSION}.tar.gz" ] || {
            echo "HATA: $OFFLINE_DIR/keepalived-${KA_VERSION}.tar.gz yok." >&2
            exit 1
        }
        cp -f "$OFFLINE_DIR/keepalived-${KA_VERSION}.tar.gz" .
    elif [ ! -f "keepalived-${KA_VERSION}.tar.gz" ]; then
        curl -fsSLO "https://www.keepalived.org/software/keepalived-${KA_VERSION}.tar.gz"
    fi
    rm -rf "keepalived-${KA_VERSION}"
    tar xzf "keepalived-${KA_VERSION}.tar.gz"
    cd "keepalived-${KA_VERSION}"
    ./configure --prefix=/usr --sysconfdir=/etc --with-init=systemd \
        --with-systemdsystemunitdir=/usr/lib/systemd/system
    make -j"$(nproc)"
    make install
    systemctl daemon-reload
    cd "$HERE"
fi
keepalived --version | head -1

echo "== $ROLE: haproxy.cfg =="
render "$HERE/lb-nodes/common/haproxy/haproxy.cfg" /etc/haproxy/haproxy.cfg
# Opsiyonel Deployment Server yonlendirmesi: DS_IP doluysa #DS# satirlari aktif,
# bos ise silinir.
if [ -n "${DS_IP:-}" ]; then
    sed -i 's/^#DS# \?//' /etc/haproxy/haproxy.cfg
    echo "Deployment Server yonlendirme ACIK: ${VIP_IP}:${DS_LISTEN_PORT:-8089} -> ${DS_IP}:${DS_PORT:-8089}"
else
    sed -i '/^#DS#/d' /etc/haproxy/haproxy.cfg
    echo "Deployment Server yonlendirme KAPALI (DS_IP bos)"
fi

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
systemctl stop keepalived 2>/dev/null || true
ip link del vrrp200 2>/dev/null || true   # eski kurulumdan kalan VMAC arayuzu
render "$HERE/lb-nodes/$ROLE/keepalived/keepalived.conf" /etc/keepalived/keepalived.conf
# UDP one-packet scheduling (ops): her datagram ayri zamanlanir, tek buyuk UDP
# akisi HF'lere bolunur ve HF donunce dagilim aninda toparlanir (bkz. variables.env UDP_OPS).
if [ "${UDP_OPS:-no}" = "yes" ]; then
    sed -i 's/^    #OPS# /    /' /etc/keepalived/keepalived.conf
    echo "UDP one-packet scheduling (ops) ACIK"
else
    sed -i '/^    #OPS# /d' /etc/keepalived/keepalived.conf
    echo "UDP one-packet scheduling KAPALI (akis basina sabit HF)"
fi
# Sanal MAC opsiyonel: ESXi "Forged Transmits/MAC Changes" Reject ise VMAC
# cikista dusurulur (bkz. variables.env USE_VMAC).
if [ "${USE_VMAC:-no}" = "yes" ]; then
    sed -i 's/^    #VMAC# /    /' /etc/keepalived/keepalived.conf
    echo "VRRP sanal MAC (use_vmac) ACIK"
else
    sed -i '/^    #VMAC# /d' /etc/keepalived/keepalived.conf
    echo "VRRP sanal MAC KAPALI -- VIP ${VRRP_INTERFACE} uzerinde, gercek MAC ile"
fi

echo "== $ROLE: IPVS dagilim kontrolu (ipvs-rebalance, mod: ${REBALANCE_MODE:-alert}) =="
if [ "$ROLE" = "lb1" ]; then PEER_IP="$LB2_IP"; else PEER_IP="$LB1_IP"; fi
install -m 0755 "$HERE/lb-nodes/common/rebalance/ipvs-rebalance.sh" /usr/local/sbin/ipvs-rebalance.sh
cp "$HERE/lb-nodes/common/rebalance/ipvs-rebalance.service" /etc/systemd/system/ipvs-rebalance.service
cp "$HERE/lb-nodes/common/rebalance/ipvs-rebalance.timer" /etc/systemd/system/ipvs-rebalance.timer
cat > /etc/ipvs-rebalance.env <<EOF
VIP_IP=${VIP_IP}
SYSLOG_PORT=${SYSLOG_PORT}
HEC_PORT=${HEC_PORT}
HF_IPS="${HF_IPS}"
PEER_IP=${PEER_IP}
REBALANCE_MODE=${REBALANCE_MODE:-alert}
REBALANCE_SKEW_RATIO=${REBALANCE_SKEW_RATIO:-0.5}
REBALANCE_MIN_CONNS=${REBALANCE_MIN_CONNS:-30}
REBALANCE_STABLE_SECS=${REBALANCE_STABLE_SECS:-600}
REBALANCE_COOLDOWN_SECS=${REBALANCE_COOLDOWN_SECS:-21600}
EOF
systemctl daemon-reload
if [ "${REBALANCE_MODE:-alert}" = "off" ]; then
    systemctl disable --now ipvs-rebalance.timer 2>/dev/null || true
else
    systemctl enable --now ipvs-rebalance.timer
fi

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
