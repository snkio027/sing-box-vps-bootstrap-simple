#!/usr/bin/bash
# 只在一次性 Ubuntu VM 中运行：真实旧版升级、故障恢复及本地 REALITY HTTPS。
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
umask 077
[[ $EUID == 0 && $(cat /root/SIMPLE_INSTALLER_DISPOSABLE_VM) == simple-installer-fixture ]]
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
MAINTAIN="$ROOT/scripts/maintain-vps.sh"
WORK=$(mktemp -d)
CLIENT='' ORIGIN='' HANDSHAKE='' CONFLICT=''
cleanup() {
    local pid
    for pid in "$CLIENT" "$ORIGIN" "$HANDSHAKE" "$CONFLICT"; do
        [[ -z $pid ]] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
    done
    rm -rf "$WORK"
}
trap cleanup EXIT
pass() { printf 'PASS %s\n' "$1"; }
reject() { if "$@" > "$WORK/rejection.log" 2>&1; then echo 'Expected failure'; exit 1; fi; }
wait_port() { for _ in {1..50}; do [[ -n $(ss -H -ltn "sport = :$1") ]] && return; sleep 0.1; done; return 1; }
stop_client() { kill "$CLIENT"; wait "$CLIENT" 2>/dev/null || true; CLIENT=''; }
# 精确官方 1.14.0 二进制，使用刚完成安装的同一配置/unit，形成真实旧版运行起点。
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 180 \
  -o "$WORK/old.deb" https://github.com/SagerNet/sing-box/releases/download/v1.14.0/sing-box_1.14.0_linux_amd64.deb
[[ $(stat -c %s "$WORK/old.deb") == 32258946 ]]
printf '%s  %s\n' 84035ea7eb85570830af77801e8e949d3769dd23bbcacce08df3bfde1945f299 "$WORK/old.deb" | sha256sum -c - >/dev/null
dpkg-deb --fsys-tarfile "$WORK/old.deb" | tar -xOf - ./usr/bin/sing-box > "$WORK/old"
printf '%s  %s\n' ce3ed8667dd99ff40c85a8b236075e856ea9cb80731b304cedd2a47187828120 "$WORK/old" | sha256sum -c - >/dev/null
install -m 0755 "$WORK/old" /usr/local/bin/sing-box.new
mv /usr/local/bin/sing-box.new /usr/local/bin/sing-box
systemctl restart sing-box
CONFIG_BEFORE=$(sha256sum /etc/sing-box/config.json)
# 测试副本在已发布候选后发送 TERM；生产入口无故障注入参数。
python3 - "$MAINTAIN" "$WORK/interrupted.sh" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
s=s.replace('commit_change() {\n', 'commit_change() {\n    kill -TERM "$$"\n', 1)
Path(sys.argv[2]).write_text(s)
PY
reject bash "$WORK/interrupted.sh" upgrade
grep -Fq 'Previous files restored; local service verification passed' "$WORK/rejection.log"
[[ $(sha256sum /usr/local/bin/sing-box | cut -d ' ' -f 1) == ce3ed8667dd99ff40c85a8b236075e856ea9cb80731b304cedd2a47187828120 ]]
[[ $(sha256sum /etc/sing-box/config.json) == "$CONFIG_BEFORE" ]]
[[ ! -e /var/lib/sing-box-maintenance/pending ]]
systemctl is-active --quiet sing-box
pass 'TERM after binary publication restores reviewed 1.14.0 and original config'
bash "$MAINTAIN" upgrade > "$WORK/upgrade.log" 2>&1 || { cat "$WORK/upgrade.log"; exit 1; }
[[ $(/usr/local/bin/sing-box version | head -n 1) == 'sing-box version 1.14.2' ]]
[[ $(sha256sum /etc/sing-box/config.json) == "$CONFIG_BEFORE" ]]
pass 'real 1.14.0 to 1.14.2 upgrade preserves configuration and credential bytes'
PID=$(systemctl show sing-box -p MainPID --value)
bash "$MAINTAIN" upgrade > "$WORK/upgrade-repeat.log" 2>&1
[[ $(systemctl show sing-box -p MainPID --value) == "$PID" ]]
pass 'repeated upgrade preserves healthy PID'
# kill -9/断电无法触发 trap：pending 存在时所有维护都必须先停下。
printf '%s\n' "$WORK/simulated-interrupted-backup" > /var/lib/sing-box-maintenance/pending
reject bash "$MAINTAIN" upgrade
[[ $(systemctl show sing-box -p MainPID --value) == "$PID" ]]
rm /var/lib/sing-box-maintenance/pending
pass 'interrupted pending record blocks blind retry'
python3 -m http.server 8443 --bind 127.0.0.1 > "$WORK/conflict.log" 2>&1 &
CONFLICT=$!; wait_port 8443
reject bash "$MAINTAIN" reality --handshake-server 127.0.0.1 --server-name localhost --handshake-port 19443
[[ $(sha256sum /etc/sing-box/config.json) == "$CONFIG_BEFORE" ]]
kill "$CONFLICT"; wait "$CONFLICT" 2>/dev/null || true; CONFLICT=''
pass 'REALITY refuses real loopback port conflict without config changes'
# 独立 TLS1.3 握手目标和 HTTPS origin，所有地址只在此 guest 回环可达。
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -addext subjectAltName=DNS:localhost -keyout "$WORK/tls.key" -out "$WORK/tls.crt" > "$WORK/cert.log" 2>&1
openssl s_server -accept 127.0.0.1:19443 -cert "$WORK/tls.crt" -key "$WORK/tls.key" \
  -tls1_3 -groups X25519 -alpn h2 -www > "$WORK/handshake.log" 2>&1 &
HANDSHAKE=$!; wait_port 19443
python3 "$ROOT/tests/https_fixture.py" "$WORK/tls.crt" "$WORK/tls.key" > "$WORK/origin.log" 2>&1 &
ORIGIN=$!; wait_port 18443
reject bash "$WORK/interrupted.sh" reality --handshake-server 127.0.0.1 --server-name localhost --handshake-port 19443
grep -Fq 'Previous files restored; local service verification passed' "$WORK/rejection.log"
[[ $(sha256sum /etc/sing-box/config.json) == "$CONFIG_BEFORE" ]]
[[ -z $(ss -H -ltn 'sport = :8443') ]]
pass 'TERM after REALITY config publication restores original SS2022 service'
bash "$MAINTAIN" reality --handshake-server 127.0.0.1 --server-name localhost --handshake-port 19443 > "$WORK/reality.log" 2>&1 || { cat "$WORK/reality.log"; exit 1; }
BACKUP=$(sed -n 's/^Private backup\/logs: //p' "$WORK/reality.log")
sed -n 's/^PublicKey: //p' "$BACKUP/reality-keypair.private" > "$WORK/public-key"
jq --rawfile public "$WORK/public-key" '{log:{level:"error"},
  inbounds:[{type:"socks",listen:"127.0.0.1",listen_port:18080}],
  outbounds:[{type:"vless",tag:"proxy",server:"127.0.0.1",server_port:8443,
    uuid:.inbounds[1].users[0].uuid,flow:"xtls-rprx-vision",network:"tcp",
    tls:{enabled:true,server_name:"localhost",utls:{enabled:true,fingerprint:"chrome"},
      reality:{enabled:true,public_key:($public|rtrimstr("\n")),short_id:.inbounds[1].tls.reality.short_id[0]}}}],
  route:{final:"proxy"}}' /etc/sing-box/config.json > "$WORK/client.json"
request() {
    curl -q --fail --silent --show-error --max-time 8 --noproxy '' --proxy socks5h://127.0.0.1:18080 \
      --cacert "$WORK/tls.crt" https://localhost:18443/probe > "$WORK/response" 2> "$WORK/curl.log"
}
/usr/local/bin/sing-box run -c "$WORK/client.json" > "$WORK/client.log" 2>&1 &
CLIENT=$!; wait_port 18080
request || { echo 'REALITY request failed'; cat "$WORK/curl.log"; exit 1; }
[[ $(cat "$WORK/response") == proxy-ok ]]; stop_client
pass 'real VLESS REALITY Vision HTTPS request with verified origin TLS'
for filter in '.outbounds[0].uuid="00000000-0000-4000-8000-000000000000"' \
  '.outbounds[0].tls.reality.short_id="ffffffffffffffff"'; do
    jq "$filter" "$WORK/client.json" > "$WORK/wrong.json"
    /usr/local/bin/sing-box run -c "$WORK/wrong.json" > "$WORK/wrong.log" 2>&1 &
    CLIENT=$!; wait_port 18080
    if request; then echo 'Wrong credential accepted'; exit 1; fi
    [[ ! -s $WORK/response ]]; stop_client
done
pass 'wrong UUID and short ID cannot obtain HTTPS response'
# 同一服务上的旧协议仍可用。
jq '{log:{level:"error"},inbounds:[{type:"socks",listen:"127.0.0.1",listen_port:18080}],
 outbounds:[{type:"shadowsocks",tag:"proxy",server:"127.0.0.1",server_port:443,
 method:"2022-blake3-aes-128-gcm",password:.inbounds[0].password,network:"tcp",multiplex:{enabled:false}}],
 route:{final:"proxy"}}' /etc/sing-box/config.json > "$WORK/ss.json"
/usr/local/bin/sing-box run -c "$WORK/ss.json" > "$WORK/ss.log" 2>&1 &
CLIENT=$!; wait_port 18080; request; [[ $(cat "$WORK/response") == proxy-ok ]]; stop_client
pass 'SS2022 HTTPS fallback remains functional alongside REALITY'
PID=$(systemctl show sing-box -p MainPID --value)
DUAL_BEFORE=$(sha256sum /etc/sing-box/config.json)
bash "$MAINTAIN" reality --handshake-server 127.0.0.1 --server-name localhost --handshake-port 19443 > "$WORK/reality-repeat.log" 2>&1
[[ $(systemctl show sing-box -p MainPID --value) == "$PID" && $(sha256sum /etc/sing-box/config.json) == "$DUAL_BEFORE" ]]
reject bash "$MAINTAIN" reality --handshake-server another.example --server-name localhost
reject bash "$ROOT/scripts/prepare-vps.sh"
[[ $(systemctl show sing-box -p MainPID --value) == "$PID" && $(sha256sum /etc/sing-box/config.json) == "$DUAL_BEFORE" ]]
pass 'repeat retains both credentials/PID; changed target and old install path refuse overwrite'
jq -r '.inbounds[0].password,.inbounds[1].users[0].uuid,.inbounds[1].tls.reality.private_key,.inbounds[1].tls.reality.short_id[0]' /etc/sing-box/config.json > "$WORK/secrets"
if grep -Fq -f "$WORK/secrets" "$WORK/upgrade.log" "$WORK/reality.log" "$WORK/reality-repeat.log"; then exit 1; fi
pass 'maintenance output contains no credentials'
