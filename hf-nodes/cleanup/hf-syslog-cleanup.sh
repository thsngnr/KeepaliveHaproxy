#!/bin/bash
# <DATA_DIR>/<kaynak-ip>/*.log dosyalarindan son yazimi <SYSLOG_RETENTION_HOURS>
# saatten eski olanlari siler, sonra ayni sureden eski bos kaynak-IP
# klasorlerini kaldirir. hf-syslog-cleanup.timer her ceyrek saatte calistirir.
#
# Dosyalar ceyreklik (rsyslog %$QHOUR%): bir ceyregin dosyasina o ceyrek
# bitince yazilmaz, mtime'i ceyregin sonunda kalir. Yani dosya, ceyregi
# bittikten <SYSLOG_RETENTION_HOURS> saat sonraki ilk calismada silinir.
#
# Temizlik olmadan disk dolar -> readyz disk_ok dusmeye baslar -> HF syslog
# havuzundan cikar; hepsi dolarsa syslog tamamen durur.
set -euo pipefail

DATA_DIR="<DATA_DIR>"
RETENTION_HOURS="<SYSLOG_RETENTION_HOURS>"

# Bos/"/" DATA_DIR ile find ... -delete calistirmak felaket olur.
case "$DATA_DIR" in
    ""|"/") logger -t hf-syslog-cleanup "HATA: DATA_DIR gecersiz ('${DATA_DIR}')"; exit 1 ;;
esac
case "$RETENTION_HOURS" in
    ''|*[!0-9]*|0) logger -t hf-syslog-cleanup "HATA: SYSLOG_RETENTION_HOURS gecersiz ('${RETENTION_HOURS}')"; exit 1 ;;
esac
[ -d "$DATA_DIR" ] || exit 0

AGE_MIN=$((RETENTION_HOURS * 60))

deleted="$(find "$DATA_DIR" -mindepth 2 -maxdepth 2 -type f -name '*.log' \
    -mmin +"$AGE_MIN" -print -delete | wc -l)"
# Sadece uzun suredir bos olan klasorler: yeni olusmus bos bir klasoru
# rsyslog'un altina dosya acmasindan hemen once silmeyelim.
removed_dirs="$(find "$DATA_DIR" -mindepth 1 -maxdepth 1 -type d -empty \
    -mmin +"$AGE_MIN" -print -delete | wc -l)"

logger -t hf-syslog-cleanup "retention=${RETENTION_HOURS}s: ${deleted} dosya, ${removed_dirs} bos klasor silindi"
