#!/bin/bash
# HF node (hf1/hf2/hf3 -- hepsi aynı) kurulum script'i. Bu repo'nun kök
# dizininden çalıştır:
#
#   ./scripts/install-hf-node.sh
#
# Splunk'ın HEC token'ı ve outputs.conf/inputs.conf'un ilgili kısımlarını
# bu script OTOMATİK yazmaz (Splunk config'ine dokunmak hassas) -- sadece
# doldurulmuş snippet'i bastırır, sen elle ekleyip splunk'ı restart edersin.
# source ile calistirilirsa set -e/exit mevcut shell'i oldurur -- bash ile calistir.
(return 0 2>/dev/null) && { echo "HATA: bu script source edilmemeli. Calistir: bash scripts/install-hf-node.sh" >&2; return 1; }
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/variables.env"

PRIMARY_IF="${1:-eth0}"   # DR sysctl dosyasındaki per-interface satırları için

# Servis kullanicisi: Debian/Ubuntu'da rsyslog "syslog:adm" ile calisir; RHEL
# ailesinde bu kullanici/grup yoktur ve rsyslog root calisir. Ikisi de varsa
# syslog:adm, yoksa root:root kullan (aksi halde systemd 217/USER hatasi verir).
if getent passwd syslog >/dev/null 2>&1 && getent group adm >/dev/null 2>&1; then
    SVC_USER=syslog; SVC_GROUP=adm
else
    SVC_USER=root; SVC_GROUP=root
fi
echo "Servis kullanicisi: ${SVC_USER}:${SVC_GROUP}"

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
        -e "s/<HEC_SSL>/${HEC_SSL:-0}/g" \
        -e "s/<UDP_RCVBUF>/${UDP_RCVBUF:-25m}/g" \
        -e "s/<DYNAFILE_CACHE_SIZE>/${DYNAFILE_CACHE_SIZE:-1000}/g" \
        -e "s/<SVC_USER>/${SVC_USER}/g" \
        -e "s/<SVC_GROUP>/${SVC_GROUP}/g" \
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
mv -f /tmp/60-lvs-dr-realserver.conf /etc/sysctl.d/60-lvs-dr-realserver.conf
sysctl --system >/dev/null

echo "== UDP alim tamponu (rmem) + rsyslog fd limiti =="
install -m 0644 "$HERE/hf-nodes/sysctl.d/62-udp-rcvbuf.conf" /etc/sysctl.d/62-udp-rcvbuf.conf
sysctl --system >/dev/null
# dynaFileCacheSize her acik dosya icin 1 fd tutar; varsayilan 1024 soft limit yetmeyebilir.
install -d -m 0755 /etc/systemd/system/rsyslog.service.d
printf '[Service]\nLimitNOFILE=65536\n' > /etc/systemd/system/rsyslog.service.d/limits.conf
systemctl daemon-reload

render "$HERE/hf-nodes/systemd/lvs-realserver-vip.service" /etc/systemd/system/lvs-realserver-vip.service

echo "== rsyslog listener =="
render "$HERE/hf-nodes/rsyslog.d/49-hf-syslog-listener.conf" /etc/rsyslog.d/49-hf-syslog-listener.conf

echo "== ${DATA_DIR} + rsyslog AppArmor izni =="
# rsyslog'un per-source-IP dosyalari yazdigi dizin (${DATA_DIR}/<kaynak-ip>/).
# Ubuntu'nun rsyslogd AppArmor profili sadece /var/log/**'a yazmaya izin
# verir; bu izin olmadan rsyslog ${DATA_DIR} altinda dizin/dosya
# olusturamaz ve TUM loglar sessizce kaybolur (journal'da "Permission denied").
# rsyslog syslog kullanicisina privilege-drop yaptigi icin dizin ona ait olmali.
install -d -m 0755 -o "${SVC_USER}" -g "${SVC_GROUP}" "${DATA_DIR}"
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
