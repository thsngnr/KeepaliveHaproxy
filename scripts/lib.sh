# shellcheck shell=bash
# install-lb-node.sh ve install-hf-node.sh icin ortak fonksiyonlar.
# Kullanim (script icinden):  source "$HERE/scripts/lib.sh"; load_vars "$HERE"
#
# Sablonlardaki <BUYUK_HARF_ISIM> yer tutuculari, ayni isimdeki shell
# degiskeniyle doldurulur (elle tutulan sed listesi yok). Render sonrasi hala
# <ISIM> kalmissa (degisken tanimsiz / yazim hatasi) kurulum durur -- yarim
# doldurulmus bir config'in sessizce servise gitmesini engeller.
#
# HF'ye ozel bloklar: sablonda "#HF_BEGIN#" ve "#HF_END#" satirlari arasindaki
# blok HF_NODES'taki her HF icin bir kez tekrarlanir; blok icinde <HF_NAME> ve
# <HF_IP> o HF'nin degerleriyle doldurulur.

# variables.env'i yukler, varsayilanlari atar, HF_NODES'u dogrular.
load_vars() {
    local root="$1"
    # shellcheck source=/dev/null
    source "$root/variables.env"

    # Opsiyonel degiskenlerin varsayilanlari (variables.env'de yoksa).
    : "${VIP_PREFIX:=32}"
    : "${USE_VMAC:=no}"
    : "${HEC_SSL:=0}"
    : "${HEC_TLS_BALANCE:=source}"
    : "${DS_IP:=}"
    : "${DS_PORT:=8089}"
    : "${DS_LISTEN_PORT:=8089}"
    # HF'lerin deploymentclient.conf hedefi: VIP olamaz (VIP HF'lerin lo'sunda)
    # shellcheck disable=SC2034  # deploymentclient.conf render eder
    HF_DEPLOYMENT_SERVER="${DS_IP:-${INDEXER_IP:-}}"
    : "${SYSLOG_INDEX:=main}"
    : "${SYSLOG_RETENTION_HOURS:=5}"
    : "${SYSLOG_QUEUE_SIZE:=100000}"
    : "${SYSLOG_QUEUE_WORKERS:=2}"
    : "${SYSLOG_QUEUE_BATCH:=1024}"
    : "${SYSLOG_QUEUE_DISK:=no}"
    : "${SYSLOG_QUEUE_MAX_DISK:=2g}"
    : "${SYSLOG_UDP_RMEM_BYTES:=33554432}"
    : "${READYZ_DISK_FREE_PCT_MIN:=10}"
    : "${READYZ_DISK_FREE_MB_MIN:=0}"
    : "${READYZ_SYNTHETIC_CHECK:=0}"
    : "${READYZ_SYNTHETIC_INTERVAL:=30}"
    : "${STATUS_CHECK_INTERVAL_SEC:=60}"
    : "${STATUS_REPORT_INTERVAL_MIN:=60}"
    : "${STATUS_DISK_WARN_PCT:=20}"
    : "${STATUS_INDEX=lb_status}"     # := degil: bilerek bos birakilabilir
    : "${STATUS_RETENTION_DAYS:=7}"
    # shellcheck disable=SC2034  # indexes.conf.snippet render eder
    STATUS_RETENTION_SECS=$((STATUS_RETENTION_DAYS * 86400))
    : "${STATUS_HEC_TOKEN:=${HEC_TOKEN:-}}"
    : "${SLACK_ENABLED:=no}"
    : "${SPLUNK_SLACK_CHANNEL:=}"
    : "${ALERT_SITE_NAME:=}"
    : "${SLACK_WEBHOOK_URL:=}"
    : "${SLACK_PROXY:=}"

    # Geriye uyumluluk: HF_NODES yoksa eski HF1..HF3_NAME/IP'den olustur.
    if [ -z "${HF_NODES:-}" ]; then
        local i name ip
        HF_NODES=""
        for i in 1 2 3 4 5 6 7 8 9; do
            name="HF${i}_NAME"; ip="HF${i}_IP"
            [ -n "${!ip:-}" ] || continue
            HF_NODES="${HF_NODES} ${!name:-splunk-hf-${i}}:${!ip}"
        done
    fi
    validate_hf_nodes
}

# HF_NODES: bosluk/satir ile ayrilmis "ad:ip" listesi.
validate_hf_nodes() {
    local entry name ip count=0 seen_names=" " seen_ips=" "
    for entry in $HF_NODES; do
        name="${entry%%:*}"; ip="${entry#*:}"
        if [ "$name" = "$entry" ] || ! [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] \
            || ! [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            echo "HATA: HF_NODES gecersiz giris '${entry}' (beklenen: ad:ipv4)" >&2; exit 1
        fi
        case "$seen_names" in *" $name "*) echo "HATA: HF_NODES'ta tekrar eden ad: $name" >&2; exit 1 ;; esac
        case "$seen_ips" in *" $ip "*) echo "HATA: HF_NODES'ta tekrar eden IP: $ip" >&2; exit 1 ;; esac
        seen_names="${seen_names}${name} "; seen_ips="${seen_ips}${ip} "
        count=$((count + 1))
    done
    if [ "$count" -eq 0 ]; then
        echo "HATA: HF_NODES bos (variables.env)" >&2; exit 1
    fi
    [ "$count" -ge 2 ] || echo "UYARI: HF_NODES'ta tek HF var -- yuk dengeleme/yedeklilik yok" >&2
    # Tek satira indir: sablonlarda <HF_NODES> olarak da kullaniliyor
    # shellcheck disable=SC2086
    HF_NODES="$(echo $HF_NODES)"
    # shellcheck disable=SC2034  # install-lb-node.sh kullanir
    HF_COUNT="$count"
}

# #HF_BEGIN# ... #HF_END# bloklarini her HF icin tekrarlar (stdin -> stdout).
_expand_hf_blocks() {
    awk -v nodes="$HF_NODES" '
        BEGIN {
            c = 0; m = split(nodes, raw, /[[:space:]]+/)
            for (i = 1; i <= m; i++) if (raw[i] != "") {
                c++; p = index(raw[i], ":")
                name[c] = substr(raw[i], 1, p - 1); ip[c] = substr(raw[i], p + 1)
            }
        }
        /#HF_BEGIN#/ { inblk = 1; nb = 0; next }
        /#HF_END#/ {
            for (h = 1; h <= c; h++) for (j = 1; j <= nb; j++) {
                l = blk[j]; gsub(/<HF_NAME>/, name[h], l); gsub(/<HF_IP>/, ip[h], l); print l
            }
            inblk = 0; next
        }
        inblk { blk[++nb] = $0; next }
        { print }
    '
}

# render <sablon> <hedef>
render() {
    local src="$1" dst="$2" tmp ph var val esc
    tmp="$(mktemp)"
    _expand_hf_blocks < "$src" > "$tmp"
    for ph in $(grep -oE '<[A-Z][A-Z0-9_]*>' "$tmp" | sort -u); do
        var="${ph#<}"; var="${var%>}"
        [ -n "${!var+x}" ] || continue          # tanimsiz -> asagida yakalanir
        val="${!var}"
        esc="$(printf '%s' "$val" | sed -e 's/[\\|&]/\\&/g')"
        sed -i -e "s|${ph}|${esc}|g" "$tmp"
    done
    if grep -nE '<[A-Z][A-Z0-9_]*>' "$tmp" >&2; then
        echo "HATA: ${src} render edildikten sonra doldurulmamis yer tutucu kaldi (yukarida)." >&2
        echo "      variables.env'de ilgili degiskeni tanimla." >&2
        rm -f "$tmp"; exit 1
    fi
    cat "$tmp" > "$dst"
    rm -f "$tmp"
}
