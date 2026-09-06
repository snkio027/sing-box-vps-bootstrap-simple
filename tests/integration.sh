#!/usr/bin/bash
# Run only on the disposable Ubuntu VM provisioned by tests/run_vm.py.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
[[ $EUID == 0 && -f /root/SIMPLE_INSTALLER_DISPOSABLE_VM ]]
[[ $(cat /root/SIMPLE_INSTALLER_DISPOSABLE_VM) == 'simple-installer-fixture' ]]
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="$ROOT/scripts/prepare-vps.sh"
WORK=$(mktemp -d)
CLIENT='' ORIGIN='' CONFLICT=''
cleanup() {
    local pid
    for pid in "$CLIENT" "$ORIGIN" "$CONFLICT"; do
        [[ -z $pid ]] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
    done
    rm -rf -- "$WORK"
}
trap cleanup EXIT
pass() { printf 'PASS %s\n' "$1"; }
SSH_BEFORE=$(sha256sum /etc/ssh/sshd_config)

# Wait for cloud-init's existing time provider, without changing it.
for _ in {1..60}; do
    [[ $(timedatectl show -p NTPSynchronized --value) == yes ]] && break
    sleep 1
done

# A real conflicting TCP listener must block before APT or installation changes.
python3 -m http.server 443 --bind 127.0.0.1 >"$WORK/conflict.log" 2>&1 &
CONFLICT=$!
for _ in {1..30}; do
    [[ -n $(ss -H -ltn 'sport = :443') ]] && break
    sleep 0.1
done
if bash "$INSTALLER" >"$WORK/conflict-output" 2>&1; then exit 1; fi
grep -Fq 'TCP 443 is occupied' "$WORK/conflict-output"
[[ ! -e /usr/local/bin/sing-box && ! -e /etc/sing-box/config.json ]]
kill "$CONFLICT"; wait "$CONFLICT" 2>/dev/null || true; CONFLICT=
pass 'foreign loopback listener rejected before installation'

bash "$INSTALLER" --upgrade-system >"$WORK/install.log" 2>&1 || { cat "$WORK/install.log"; exit 1; }
systemctl is-enabled --quiet sing-box
systemctl is-active --quiet sing-box
[[ $(systemctl show sing-box -p User --value) == sing-box ]]
[[ $(stat -c '%U:%G:%a' /etc/sing-box/config.json) == root:sing-box:640 ]]
[[ $(sha256sum /etc/ssh/sshd_config) == "$SSH_BEFORE" ]]
[[ $(wc -l < /proc/swaps) == 2 ]]
[[ $(stat -c %s /var/lib/sing-box/swapfile) == 1073741824 ]]
[[ $(grep -Fxc '/var/lib/sing-box/swapfile none swap sw 0 0' /etc/fstab) == 1 ]]
pass 'real installation, private config, service account, swap and unchanged SSH'

# Reproduce the released candidate's missing NETLINK_ROUTE access, then repair by rerunning.
UNIT=/etc/systemd/system/sing-box.service
cp "$UNIT" "$WORK/good.service"
KEY_CONFIG_BEFORE=$(sha256sum /etc/sing-box/config.json)
sed -e 's/ AF_NETLINK//g' -e 's/^Restart=on-failure$/Restart=no/' "$UNIT" > "$WORK/restricted.service"
install -o root -g root -m 0644 "$WORK/restricted.service" "$UNIT"
systemctl daemon-reload
systemctl restart sing-box.service || true
for _ in {1..50}; do
    [[ $(systemctl show sing-box -p ActiveState --value) == failed ]] && break
    sleep 0.1
done
[[ $(systemctl show sing-box -p ActiveState --value) == failed ]]
[[ $(systemctl show sing-box -p ExecMainStatus --value) == 1 ]]
journalctl --no-pager -u sing-box -b -n 30 -o cat > "$WORK/restricted.log"
grep -Fq 'subscribe route updates: address family not supported by protocol' "$WORK/restricted.log"
bash "$INSTALLER" >"$WORK/recovery.log" 2>&1 || { cat "$WORK/recovery.log"; exit 1; }
cmp "$UNIT" "$WORK/good.service"
[[ $(sha256sum /etc/sing-box/config.json) == "$KEY_CONFIG_BEFORE" ]]
systemctl is-active --quiet sing-box
pass 'missing AF_NETLINK reproduces the failure; rerun repairs service without changing the key'

PID=$(systemctl show sing-box -p MainPID --value)
CONFIG_BEFORE=$(sha256sum /etc/sing-box/config.json)
FSTAB_BEFORE=$(sha256sum /etc/fstab)
SWAP_BEFORE=$(stat -c '%d:%i:%s' /var/lib/sing-box/swapfile)
bash "$INSTALLER" >"$WORK/repeat.log" 2>&1 || { cat "$WORK/repeat.log"; exit 1; }
[[ $(systemctl show sing-box -p MainPID --value) == "$PID" ]]
[[ $(sha256sum /etc/sing-box/config.json) == "$CONFIG_BEFORE" ]]
[[ $(sha256sum /etc/fstab) == "$FSTAB_BEFORE" ]]
[[ $(stat -c '%d:%i:%s' /var/lib/sing-box/swapfile) == "$SWAP_BEFORE" ]]
pass 'rerun preserves key/config, swap, fstab and service process'

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost -keyout "$WORK/tls.key" -out "$WORK/tls.crt" >"$WORK/cert.log" 2>&1
python3 "$ROOT/tests/https_fixture.py" "$WORK/tls.crt" "$WORK/tls.key" &
ORIGIN=$!
jq '{log:{level:"error"},inbounds:[{type:"socks",listen:"127.0.0.1",listen_port:18080}],
    outbounds:[{type:"shadowsocks",tag:"proxy",server:"127.0.0.1",server_port:443,
    method:"2022-blake3-aes-128-gcm",password:.inbounds[0].password,network:"tcp",multiplex:{enabled:false}}],
    route:{final:"proxy"}}' /etc/sing-box/config.json > "$WORK/client.json"
/usr/local/bin/sing-box run -c "$WORK/client.json" >"$WORK/client.log" 2>&1 &
CLIENT=$!
for _ in {1..30}; do
    [[ -n $(ss -H -ltn 'sport = :18080') && -n $(ss -H -ltn 'sport = :18443') ]] && break
    sleep 0.1
done
curl --fail --silent --show-error --max-time 15 --noproxy '' --proxy socks5h://127.0.0.1:18080 \
    --cacert "$WORK/tls.crt" https://localhost:18443/probe > "$WORK/response"
[[ $(cat "$WORK/response") == proxy-ok ]]
pass 'real SS2022 HTTPS request with normal certificate and hostname verification'
kill "$CLIENT"; wait "$CLIENT" 2>/dev/null || true; CLIENT=
openssl rand -base64 16 > "$WORK/wrong-key"
jq --rawfile key "$WORK/wrong-key" '.outbounds[0].password=($key|rtrimstr("\n"))' \
    "$WORK/client.json" > "$WORK/wrong.json"
/usr/local/bin/sing-box run -c "$WORK/wrong.json" >"$WORK/wrong.log" 2>&1 &
CLIENT=$!
for _ in {1..30}; do
    [[ -n $(ss -H -ltn 'sport = :18080') ]] && break
    sleep 0.1
done
if curl --fail --silent --max-time 5 --noproxy '' --proxy socks5h://127.0.0.1:18080 \
    --cacert "$WORK/tls.crt" https://localhost:18443/probe > "$WORK/wrong-response"; then exit 1; fi
[[ ! -s $WORK/wrong-response ]]
pass 'wrong SS2022 key cannot obtain the HTTPS response'

# Credentials must not appear in installer output. The key remains in a private pattern file.
jq -r '.inbounds[0].password' /etc/sing-box/config.json > "$WORK/key-pattern"
if grep -Fq -f "$WORK/key-pattern" "$WORK/install.log" "$WORK/recovery.log" "$WORK/repeat.log"; then exit 1; fi
[[ $(sha256sum /etc/ssh/sshd_config) == "$SSH_BEFORE" ]]
pass 'no key in installer output and original SSH configuration preserved'
printf 'ALL INTEGRATION CHECKS PASSED\n'
