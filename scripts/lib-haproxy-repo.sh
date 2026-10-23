#!/bin/bash
# source edilir (install-lb-node.sh, prepare-offline-bundle.sh). Bu makinenin
# Ubuntu surumu icin kurulabilir EN GUNCEL HAProxy serisini bulur, apt kaynagini
# ekler ve HAPROXY_PKG degiskenini ("haproxy=3.4.*" veya "haproxy") ayarlar.
#
# Sirayla her seri icin (HAPROXY_SERIES verilmisse sadece o seri) su kaynaklar
# denenir; kaynagin bu Ubuntu kod adi (noble vb.) icin Release dosyasi
# yayinlamis olmasi curl ile once YOKLANIR (404 olan kaynak apt'a hic eklenmez):
#   1) vbernat PPA   https://ppa.launchpadcontent.net/vbernat/haproxy-<seri>/ubuntu
#   2) haproxy.debian.net  <kodad>-backports-<seri>
# Hicbiri yoksa Ubuntu'nun kendi paketine (ör. noble'da 2.8) dusulur.
# Kullanim: HAPROXY_SERIES=3.2 ./scripts/install-lb-node.sh lb1   (seriyi sabitler)

HAPROXY_CANDIDATES="${HAPROXY_SERIES:-3.4 3.3 3.2 3.0}"
HAPROXY_PKG="haproxy"

haproxy_probe() { curl -fsSI -m 15 "$1" >/dev/null 2>&1; }

setup_haproxy_repo() {
    local codename series
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    for series in $HAPROXY_CANDIDATES; do
        if haproxy_probe "https://ppa.launchpadcontent.net/vbernat/haproxy-${series}/ubuntu/dists/${codename}/Release"; then
            echo "HAProxy ${series}: vbernat PPA (${codename}) bulundu"
            apt-get install --no-install-recommends -y software-properties-common
            add-apt-repository -y "ppa:vbernat/haproxy-${series}"
            apt-get update -qq
            HAPROXY_PKG="haproxy=${series}.*"; return 0
        fi
        if haproxy_probe "https://haproxy.debian.net/dists/${codename}-backports-${series}/Release"; then
            echo "HAProxy ${series}: haproxy.debian.net (${codename}-backports-${series}) bulundu"
            apt-get install --no-install-recommends -y gnupg ca-certificates
            curl -fsSL https://haproxy.debian.net/bernat.debian.org.gpg \
                | gpg --dearmor -o /usr/share/keyrings/haproxy.debian.net.gpg
            echo "deb [signed-by=/usr/share/keyrings/haproxy.debian.net.gpg] https://haproxy.debian.net ${codename}-backports-${series} main" \
                > /etc/apt/sources.list.d/haproxy-debian-net.list
            apt-get update -qq
            HAPROXY_PKG="haproxy=${series}.*"; return 0
        fi
    done
    echo "UYARI: ${codename} icin harici HAProxy kaynagi bulunamadi (${HAPROXY_CANDIDATES})." >&2
    echo "       Ubuntu'nun kendi haproxy paketi kullanilacak: $(apt-cache policy haproxy | awk '/Candidate/{print $2}')" >&2
    HAPROXY_PKG="haproxy"
}
