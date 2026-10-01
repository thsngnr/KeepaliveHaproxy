#!/bin/bash
# VRRP auth_hmac anahtarını üretir. SADECE BİR KEZ, bir node'da çalıştır,
# sonra çıkan dosyayı diğer LB node'una kopyala (iki node'da da AYNI key
# olmak zorunda, yoksa auth_hmac handshake başarısız olur).
#
# Kullanım:  ./gen-vrrp-key.sh
# Çıktı:     /etc/keepalived/keys/vrrp200
set -euo pipefail

KEY_DIR="/etc/keepalived/keys"
KEY_FILE="${KEY_DIR}/vrrp200"

if [ -f "$KEY_FILE" ]; then
    echo "UYARI: $KEY_FILE zaten var, üzerine yazılmıyor." >&2
    exit 1
fi

install -d -m 0700 -o root -g root "$KEY_DIR"
# 32 byte rastgele anahtar, hex encode
openssl rand -hex 32 > "$KEY_FILE"
chmod 0600 "$KEY_FILE"
chown root:root "$KEY_FILE"

echo "Üretildi: $KEY_FILE"
echo "Bu dosyayı diğer LB node'una AYNEN kopyala, örn:"
echo "  scp $KEY_FILE root@<diger-lb-ip>:$KEY_FILE"
