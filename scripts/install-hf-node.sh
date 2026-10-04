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
# shellcheck source=scripts/lib.sh
source "$HERE/scripts/lib.sh"
load_vars "$HERE"   # variables.env + varsayilanlar + HF_NODES dogrulamasi

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

# Splunk host_segment: <DATA_DIR>/<kaynak-ip>/... yolunda <kaynak-ip>'nin sirasi
# (/data/log/splunk/syslog -> 4 parca -> kaynak-ip 5. parca).
# shellcheck disable=SC2034  # render() bunu <HOST_SEGMENT> icin dolayli okur
HOST_SEGMENT="$(awk -F/ '{n=0; for (i=1; i<=NF; i++) if ($i != "") n++; print n+1}' <<<"$DATA_DIR")"
SYSLOG_RETENTION_HOURS="${SYSLOG_RETENTION_HOURS:-5}"
case "$SYSLOG_RETENTION_HOURS" in
    ''|*[!0-9]*) echo "HATA: SYSLOG_RETENTION_HOURS sayi olmali ('${SYSLOG_RETENTION_HOURS}')" >&2; exit 1 ;;
esac
SYSLOG_UDP_RMEM_BYTES="${SYSLOG_UDP_RMEM_BYTES:-33554432}"
case "$SYSLOG_UDP_RMEM_BYTES" in
    ''|*[!0-9]*) echo "HATA: SYSLOG_UDP_RMEM_BYTES sayi olmali ('${SYSLOG_UDP_RMEM_BYTES}')" >&2; exit 1 ;;
esac


echo "== paketler =="
if command -v apt-get >/dev/null; then
    apt-get update -qq
    apt-get install -y rsyslog python3
elif command -v dnf >/dev/null; then
    # RHEL 8+/Rocky/Alma: semanage policycoreutils-python-utils icinde
    dnf install -y rsyslog python3 policycoreutils-python-utils
elif command -v yum >/dev/null; then
    # RHEL/CentOS 7: semanage policycoreutils-python icinde
    yum install -y rsyslog python3 policycoreutils-python
fi

echo "== VIP loopback alias (DR) + ARP suppression =="
render "$HERE/hf-nodes/sysctl.d/60-lvs-dr-realserver.conf" /tmp/60-lvs-dr-realserver.conf
sed -i "s/eth0/${PRIMARY_IF}/g" /tmp/60-lvs-dr-realserver.conf
mv -f /tmp/60-lvs-dr-realserver.conf /etc/sysctl.d/60-lvs-dr-realserver.conf

echo "== UDP alma buffer'i (rmem) =="
# rsyslog imudp buffer boyutu belirtmez, soket net.core.rmem_default ile acilir.
# Buffer soket acilirken belirlenir: asagidaki "systemctl restart rsyslog"
# sonrasi gecerli olur. rmem_max sadece buyutulur, mevcut daha buyukse korunur.
RMEM_SYSCTL=/etc/sysctl.d/62-hf-udp-rmem.conf
if [ "$SYSLOG_UDP_RMEM_BYTES" -gt 0 ]; then
    rmem_max="$(sysctl -n net.core.rmem_max)"
    [ "$rmem_max" -lt "$SYSLOG_UDP_RMEM_BYTES" ] && rmem_max="$SYSLOG_UDP_RMEM_BYTES"
    cat > "$RMEM_SYSCTL" <<EOF
# install-hf-node.sh tarafindan yazildi (variables.env SYSLOG_UDP_RMEM_BYTES)
net.core.rmem_default = ${SYSLOG_UDP_RMEM_BYTES}
net.core.rmem_max = ${rmem_max}
EOF
    echo "rmem_default=${SYSLOG_UDP_RMEM_BYTES} rmem_max=${rmem_max}"
else
    rm -f "$RMEM_SYSCTL"
    echo "SYSLOG_UDP_RMEM_BYTES=0: rmem'e dokunulmadi (onceki deger reboot'a kadar aktif kalabilir)"
fi
sysctl --system >/dev/null

render "$HERE/hf-nodes/systemd/lvs-realserver-vip.service" /etc/systemd/system/lvs-realserver-vip.service

echo "== rsyslog listener =="
render "$HERE/hf-nodes/rsyslog.d/49-hf-syslog-listener.conf" /etc/rsyslog.d/49-hf-syslog-listener.conf
if [ "${SYSLOG_QUEUE_DISK:-no}" = "yes" ]; then
    sed -i 's/^#DAQ# //' /etc/rsyslog.d/49-hf-syslog-listener.conf
    echo "rsyslog disk destekli kuyruk ACIK (max ${SYSLOG_QUEUE_MAX_DISK:-2g})"
else
    sed -i '/^#DAQ#/d' /etc/rsyslog.d/49-hf-syslog-listener.conf
    echo "rsyslog disk destekli kuyruk KAPALI"
fi
rsyslogd -N1 >/dev/null || { echo "HATA: rsyslog config dogrulamasi basarisiz (rsyslogd -N1)" >&2; exit 1; }

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
# RHEL ailesi: AppArmor yerine SELinux. rsyslogd (rsyslogd_t) sadece log
# tiplerine (var_log_t vb.) yazabilir; /data altinda olusturulan dizin
# default_t etiketi alir ve rsyslog oraya yazamaz -- yine TUM loglar sessizce
# kaybolur (audit.log'da AVC denied). DATA_DIR'e kalici var_log_t etiketi ver.
# Splunk (unconfined) ve hf-readyz / cleanup servisleri bu etiketi okuyup
# yazabilir. 514/tcp+udp zaten syslogd_port_t, port etiketi gerekmez.
if command -v selinuxenabled >/dev/null && selinuxenabled; then
    command -v semanage >/dev/null || {
        echo "HATA: SELinux acik ama semanage yok (policycoreutils-python[-utils] kur)" >&2; exit 1; }
    if semanage fcontext -l | grep -qF "${DATA_DIR}(/.*)?"; then
        semanage fcontext -m -t var_log_t "${DATA_DIR}(/.*)?"
    else
        semanage fcontext -a -t var_log_t "${DATA_DIR}(/.*)?"
    fi
    restorecon -R "${DATA_DIR}"
    echo "SELinux: ${DATA_DIR} -> var_log_t ($(stat -c %C "${DATA_DIR}"))"
fi

echo "== hf-readyz health servisi (port ${READYZ_PORT}) =="
install -d -m 0755 /opt/hf-readyz
render "$HERE/hf-nodes/hf-readyz/readyz.py" /opt/hf-readyz/readyz.py
render "$HERE/hf-nodes/systemd/hf-readyz.service" /etc/systemd/system/hf-readyz.service

echo "== syslog retention temizligi (${SYSLOG_RETENTION_HOURS} saat) =="
render "$HERE/hf-nodes/cleanup/hf-syslog-cleanup.sh" /usr/local/sbin/hf-syslog-cleanup.sh
chmod 0755 /usr/local/sbin/hf-syslog-cleanup.sh
render "$HERE/hf-nodes/systemd/hf-syslog-cleanup.service" /etc/systemd/system/hf-syslog-cleanup.service
cp "$HERE/hf-nodes/systemd/hf-syslog-cleanup.timer" /etc/systemd/system/hf-syslog-cleanup.timer

echo "== servisler =="
systemctl daemon-reload
systemctl enable --now lvs-realserver-vip.service
systemctl enable --now hf-readyz.service
if [ "$SYSLOG_RETENTION_HOURS" -gt 0 ]; then
    systemctl enable --now hf-syslog-cleanup.timer
else
    # 0 = bu HF'nin temizligini baska bir mekanizma (cron/logrotate) yapiyor
    systemctl disable --now hf-syslog-cleanup.timer 2>/dev/null || true
    echo "SYSLOG_RETENTION_HOURS=0: hf-syslog-cleanup.timer KAPALI"
fi
systemctl restart rsyslog

echo "== durum =="
systemctl is-active lvs-realserver-vip.service hf-readyz.service rsyslog
if [ "$SYSLOG_RETENTION_HOURS" -gt 0 ]; then
    systemctl list-timers hf-syslog-cleanup.timer --no-pager || true
fi
ip addr show lo | grep "${VIP_IP}" || echo "UYARI: VIP lo'ya eklenmedi, kontrol et"
# RHEL'de firewalld varsayilan acik: syslog/HEC/readyz portlari kapaliysa LB'ler
# HF'ye ulasamaz. Guvenlik duvarini otomatik degistirmiyoruz, sadece uyariyoruz.
if command -v firewall-cmd >/dev/null && systemctl is-active -q firewalld; then
    for p in "${SYSLOG_PORT}/tcp" "${SYSLOG_PORT}/udp" "${HEC_PORT}/tcp" "${READYZ_PORT}/tcp"; do
        firewall-cmd -q --query-port="$p" || \
            echo "UYARI: firewalld ${p} kapali. Ac: firewall-cmd --permanent --add-port=${p} && firewall-cmd --reload"
    done
fi
curl -s "http://127.0.0.1:${READYZ_PORT}/readyz/syslog" | head -c 300; echo
echo
echo "== Splunk tarafı (ELLE YAP) =="
echo "Aşağıdaki snippet'leri doldurup gösteriyorum -- Splunk'ın"
echo "\$SPLUNK_HOME/etc/system/local/ altındaki ilgili dosyalara ELLE ekle,"
echo "sonra Splunk'ı restart et:"
for s in inputs.conf deploymentclient.conf; do
    echo "----- ${s} -----"
    render "$HERE/hf-nodes/splunk/${s}$([ "$s" = inputs.conf ] && echo .snippet)" /dev/stdout
done
echo "-----------------------------------------------------------"
