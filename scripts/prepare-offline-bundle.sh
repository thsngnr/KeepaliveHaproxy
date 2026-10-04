#!/bin/bash
# İNTERNETİ OLAN, hedef air-gapped LB node ile AYNI Ubuntu sürümündeki
# bir makinede çalıştır (ideal: aynı golden image/template'ten açılmış
# boş bir VM -- böylece "zaten kurulu" varsayılan paketler yüzünden bir
# bağımlılığın bundle'dan eksik kalması riski en aza iner).
#
# Kullanım:
#   ./scripts/prepare-offline-bundle.sh [çıkış-klasörü]
# Varsayılan çıkış: ./offline-bundle
#
# Çıkan klasörü scp/usb/vb. ile air-gapped LB node'a taşı, sonra orada:
#   ./scripts/install-lb-node.sh lb1 /path/to/offline-bundle
set -euo pipefail

OUT="${1:-./offline-bundle}"
KA_VERSION="2.4.3"

mkdir -p "$OUT/debs"
OUT="$(cd "$OUT" && pwd)"

PACKAGES=(ipvsadm ipset build-essential libssl-dev libnl-3-dev
    libnl-genl-3-dev libnfnetlink-dev libipset-dev libsnmp-dev libmagic-dev
    pkg-config libxtables-dev libip4tc-dev libip6tc-dev python3 curl)

echo "== vbernat haproxy-3.4 PPA ekleniyor =="
apt-get update -qq
apt-get install --no-install-recommends -y software-properties-common
add-apt-repository -y ppa:vbernat/haproxy-3.4
apt-get update -qq

echo "== apt paketleri indiriliyor (kurulum yapılmıyor, sadece indirme) =="
# --download-only + Dir::Cache::Archives: paketleri kurmadan, bağımlılık
# çözümünü apt'a bırakarak doğrudan hedef klasöre indirir.
apt-get install -y --download-only -o "Dir::Cache::Archives=${OUT}/debs" \
    "${PACKAGES[@]}" software-properties-common "haproxy=3.4.*"
# apt bazı .deb'leri "partial/" alt klasörüne indirebilir, düzelt:
find "$OUT/debs" -name '*.deb' -path '*partial*' -exec mv {} "$OUT/debs/" \; 2>/dev/null || true
rmdir "$OUT/debs/partial" 2>/dev/null || true

echo "== keepalived ${KA_VERSION} kaynak tarball'ı indiriliyor =="
curl -fsSL -o "$OUT/keepalived-${KA_VERSION}.tar.gz" \
    "https://www.keepalived.org/software/keepalived-${KA_VERSION}.tar.gz"

echo
echo "Hazır: $OUT"
du -sh "$OUT"
ls "$OUT/debs" | wc -l
echo "paket (.deb) indirildi."
echo
echo "Bu klasörü air-gapped LB node'a taşı, sonra orada:"
echo "  ./scripts/install-lb-node.sh lb1 $OUT"
echo
echo "NOT: Bu bundle'ı, hedef host'taki Ubuntu sürümüyle AYNI ve mümkünse"
echo "aynı 'temizlikte' (ör. aynı golden image) bir makinede hazırlamazsan,"
echo "hedefte zaten kurulu olmayan bazı temel kütüphaneler (libc vb.)"
echo "bundle'da eksik kalabilir -- apt bu makinede 'zaten var' diye onları"
echo "indirmeyi atlar. Böyle bir durumda install-lb-node.sh 'dpkg: dependency"
echo "problems' hatası verir; eksik paketi bu makineden 'apt-get download"
echo "<paket>' ile ayrıca indirip $OUT/debs/ içine ekle, tekrar dene."
