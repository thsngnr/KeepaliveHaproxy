#!/bin/bash
# HF node (hf1/hf2/hf3 -- hepsi aynı) kurulum script'i. Bu repo'nun kök
# dizininden çalıştır:
#
#   ./scripts/install-hf-node.sh
#
# Splunk'ın HEC token'ı ve outputs.conf/inputs.conf'un ilgili kısımlarını
# bu script OTOMATİK yazmaz (Splunk config'ine dokunmak hassas) -- sadece
# doldurulmuş snippet'i bastırır, sen elle ekleyip splunk'ı restart edersin.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/variables.env"

PRIMARY_IF="${1:-eth0}"   # DR sysctl dosyasındaki per-interface satırları için

render() {
    sed \
        -e "s/<VIP_IP>/${VIP_IP}/g" \
        -e "s/<LB1_IP>/${LB1_IP}/g" \
        -e "s/<LB2_IP>/${LB2_IP}/g" \
        -e "s/<HF1_IP>/${HF1_IP}/g" \
        -e "s/<HF2_IP>/${HF2_IP}/g" \
        -e "s/<HF3_IP>/${HF3_IP}/g" \
        -e "s/<INDEXER_IP>/${INDEXER_IP}/g" \
        -e "s/<HEC_TOKEN>/${HEC_TOKEN}/g" \
        -e "s/<SYSLOG_PORT>/${SYSLOG_PORT}/g" \
        -e "s/<HEC_PORT>/${HEC_PORT}/g" \
        -e "s/<READYZ_PORT>/${READYZ_PORT}/g" \
        -e "s/<INDEXER_RECEIVING_PORT>/${INDEXER_RECEIVING_PORT}/g" \
        -e "s|<DATA_DIR>|${DATA_DIR}|g" \
        "$1" > "$2"
}

echo "== paketler =="
if command -v apt-get >/dev/null; then
    apt-get update -qq
    apt-get install -y rsyslog python3
fi

echo "== VIP loopback alias (DR) + ARP suppression =="
render "$HERE/hf-nodes/sysctl.d/60-lvs-dr-realserver.conf" /tmp/60-lvs-dr-realserver.conf
sed -i "s/eth0/${PRIMARY_IF}/g" /tmp/60-lvs-dr-realserver.conf
mv /tmp/60-lvs-dr-realserver.conf /etc/sysctl.d/60-lvs-dr-realserver.conf
sysctl --system >/dev/null

render "$HERE/hf-nodes/systemd/lvs-realserver-vip.service" /etc/systemd/system/lvs-realserver-vip.service

echo "== rsyslog listener =="
render "$HERE/hf-nodes/rsyslog.d/49-hf-syslog-listener.conf" /etc/rsyslog.d/49-hf-syslog-listener.conf

echo "== ${DATA_DIR} + rsyslog AppArmor izni =="
# rsyslog'un per-source-IP dosyalari yazdigi dizin (${DATA_DIR}/<kaynak-ip>/).
# Ubuntu'nun rsyslogd AppArmor profili sadece /var/log/**'a yazmaya izin
# verir; bu izin olmadan rsyslog ${DATA_DIR} altinda dizin/dosya
# olusturamaz ve TUM loglar sessizce kaybolur (journal'da "Permission denied").
# rsyslog syslog kullanicisina privilege-drop yaptigi icin dizin ona ait olmali.
install -d -m 0755 -o syslog -g adm "${DATA_DIR}"
if [ -d /etc/apparmor.d/local ] && [ -f /etc/apparmor.d/usr.sbin.rsyslogd ]; then
    grep -qF "  ${DATA_DIR}/** rwk," /etc/apparmor.d/local/usr.sbin.rsyslogd 2>/dev/null || \
        printf '  %s/ rw,\n  %s/** rwk,\n' "${DATA_DIR}" "${DATA_DIR}" >> /etc/apparmor.d/local/usr.sbin.rsyslogd
    apparmor_parser -r /etc/apparmor.d/usr.sbin.rsyslogd
fi

echo "== hf-readyz health servisi (port ${READYZ_PORT}) =="
install -d -m 0755 /opt/hf-readyz
render "$HERE/hf-nodes/hf-readyz/readyz.py" /opt/hf-readyz/readyz.py
render "$HERE/hf-nodes/systemd/hf-readyz.service" /etc/systemd/system/hf-readyz.service

echo "== servisler =="
systemctl daemon-reload
systemctl enable --now lvs-realserver-vip.service
systemctl enable --now hf-readyz.service
systemctl restart rsyslog

echo "== durum =="
systemctl is-active lvs-realserver-vip.service hf-readyz.service rsyslog
ip addr show lo | grep "${VIP_IP}" || echo "UYARI: VIP lo'ya eklenmedi, kontrol et"
curl -s "http://127.0.0.1:${READYZ_PORT}/readyz/syslog" | head -c 300; echo
echo
echo "== Splunk tarafı (ELLE YAP) =="
echo "Aşağıdaki snippet'i doldurup gösteriyorum -- bunu Splunk'ın"
echo "\$SPLUNK_HOME/etc/system/local/inputs.conf ve outputs.conf dosyalarına"
echo "ELLE ekle, sonra Splunk'ı restart et:"
echo "-----------------------------------------------------------"
render "$HERE/hf-nodes/splunk/inputs.conf.snippet" /tmp/inputs.conf.rendered
cat /tmp/inputs.conf.rendered
rm -f /tmp/inputs.conf.rendered
echo "-----------------------------------------------------------"
