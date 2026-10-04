#!/bin/bash
# lb-status uctan uca testi: sahte HAProxy stats / HF readyz / HEC / Slack
# (fake.py) ve ip/ipvsadm/systemctl shim'leriyle. scripts/ci-check.sh bunu
# ubuntu:24.04 konteynerinde calistirir: repo /m (salt okunur), bu dizin /t.
set -uo pipefail
apt-get -qq update >/dev/null && apt-get -qq install -y python3 curl iproute2 procps >/dev/null 2>&1

FAILS=0
ok()   { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; FAILS=$((FAILS + 1)); }
has()  { grep -qF -- "$2" "$1" && ok "$3" || bad "$3 (beklenen: '$2' $1 icinde)"; }
hasnt(){ grep -qF -- "$2" "$1" && bad "$3 (beklenmeyen: '$2' $1 icinde)" || ok "$3"; }

mkdir -p /fx /out /shim /etc/keepalived/keys
cp -r /m /w
cat > /w/variables.env.local <<'EOF'
VIP_IP=192.0.2.50
LB1_IP=192.0.2.11
LB2_IP=127.0.0.1
HF_NODES="hf-1:127.0.0.2 hf-2:127.0.0.3 hf-3:127.0.0.4"
ALERT_SITE_NAME=test-dc
SLACK_ENABLED=yes
EOF
( source /w/scripts/lib.sh; load_vars /w 2>/dev/null; render /w/lb-nodes/common/status/lb-status.py /usr/local/sbin/lb-status ) || exit 1
chmod +x /usr/local/sbin/lb-status
echo "http://127.0.0.1:8099/hook" > /etc/keepalived/keys/slack-webhook
echo "TESTTOKEN" > /etc/keepalived/keys/status-hec-token

cat > /shim/ip <<'EOF'
#!/bin/bash
echo "2: eth0    inet 192.0.2.11/24 brd 192.0.2.255 scope global eth0"
echo "2: eth0    inet 192.0.2.50/32 scope global eth0"
EOF
cat > /shim/ipvsadm <<'EOF'
#!/bin/bash
echo "IP Virtual Server version 1.2.1 (size=4096)"
echo "Prot LocalAddress:Port                 CPS    InPPS   OutPPS    InBPS   OutBPS"
echo "  -> RemoteAddress:Port"
for p in TCP UDP; do
  echo "$p  192.0.2.50:514                       0     9000        0   900000        0"
  for h in 2 3 4; do
    pl=$(echo $p | tr A-Z a-z)
    [ "$(cat /fx/pool_${pl}_127.0.0.$h 2>/dev/null)" = "out" ] && continue
    echo "  -> 127.0.0.$h:514                         0     1500        0   150000        0"
  done
done
EOF
printf '#!/bin/bash\necho active\n' > /shim/systemctl
printf '#!/bin/bash\necho "[logger] $*" >> /out/logger\n' > /shim/logger
chmod +x /shim/*
export PATH=/shim:$PATH

start_fake() { pkill -f /t/fake.py 2>/dev/null; sleep 0.3; python3 /t/fake.py & sleep 1; }
step() { echo "## $1"; : > /out/slack; : > /out/hec; }

start_fake
step "1) saglikli: ilk check + report"
lb-status check; lb-status report; sleep 0.5
has   /out/slack "3/3 HF saglikli"          "rapor tek satir"
has   /out/hec   '"sourcetype": "lb:status:hec"' "durum HEC'e gitti"
has   /out/hec   '"type": "report"'          "rapor HEC'e lb:event:hec olarak gitti"
hasnt /out/hec   '"state": "new"'            "saglikliyken olay yok"

step "2) sorun cikti: hf-2 HEC DOWN, hf-3 disk %12, hf-2 udp havuz disi"
echo DOWN > /fx/hec_hf-2; echo 12 > /fx/disk_hf-3; echo out > /fx/pool_udp_127.0.0.3
lb-status check; sleep 0.5
has   /out/slack "HF hf-2 HEC DOWN"          "HEC dususu aninda Slack'e"
has   /out/slack "hf-3 DATA_DIR diskinde"    "disk uyarisi aninda Slack'e"
hasnt /out/slack "havuzunda degil"           "syslog havuzu tekrar uyarilmadi (notify.sh'in isi)"
has   /out/hec   '"key": "hec:hf-2"'         "olay HEC'e lb:event:hec"

step "3) sorun suruyor: check tekrar uyarmamali, report tablo"
lb-status check; sleep 0.5
hasnt /out/slack "HEC DOWN"                  "ayni sorun tekrar uyarilmadi"
lb-status report; sleep 0.5
has   /out/slack "Durum raporu"              "sorun varken rapor tablo"
has   /out/slack "hf-2  DOWN"                "tabloda hf-2 DOWN"

step "4) duzeldi"
rm -f /fx/hec_hf-2 /fx/disk_hf-3 /fx/pool_udp_127.0.0.3
lb-status check; sleep 0.5
has   /out/slack "DUZELDI: HF hf-2 HEC DOWN" "duzelme bildirildi"
has   /out/hec   '"state": "resolved"'       "duzelme HEC'e"

step "5) SLACK_ENABLED=no"
sed -i 's/^SLACK_ENABLED = .*/SLACK_ENABLED = False/' /usr/local/sbin/lb-status
echo DOWN > /fx/hec_hf-1
lb-status check; sleep 0.5
[ -s /out/slack ] && bad "Slack kapaliyken mesaj gitti" || ok "Slack kapaliyken mesaj yok"
has   /out/hec   '"key": "hec:hf-1"'         "Slack kapaliyken olay yine HEC'e"

step "6) yerel HAProxy/HEC cokmus -> HEC yedek hedef (HF)"
echo down > /fx/local_hec; start_fake
lb-status check; sleep 0.5
has   /out/hec   "127.0.0.2 "                "HEC dogrudan HF'ye (127.0.0.2) gitti"

pkill -f /t/fake.py 2>/dev/null
echo "lb-status testi: ${FAILS} hata"
exit $((FAILS > 0))
