#!/usr/bin/bash
# 纯参数/观测解析测试；source 后不调用主机修改流程。
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR source=../scripts/harden-vps.sh
source "$ROOT/scripts/harden-vps.sh"
if [[ $(uname -s) == Darwin ]]; then export PATH=/opt/homebrew/bin:$PATH; fi
COUNT=0
pass() { COUNT=$((COUNT+1)); printf 'PASS %s\n' "$1"; }
reject() { if ("$@") >/dev/null 2>&1; then printf 'Expected rejection\n' >&2; exit 1; fi; }
valid_admin fixtureadmin
for value in root sing-box '' '-bad' 'bad;command' '../admin' 'a b'; do reject valid_admin "$value"; done
valid_port 22; valid_port 2222; valid_port 65535
for value in 0 022 443 65536 '' '22;true'; do reject valid_port "$value"; done
pass 'administrator and port validation'
check_listener_text 22 no <<'EOF'
LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=120,fd=3))
LISTEN 0 128 [::]:22 [::]:* users:(("sshd",pid=120,fd=4))
LISTEN 0 128 127.0.0.53:53 0.0.0.0:* users:(("systemd-resolve",pid=80,fd=3))
EOF
pass 'service IPv4 and IPv6 listeners'
check_listener_text 22 yes <<'EOF'
LISTEN 0 4096 *:22 *:* users:(("systemd",pid=1,fd=77))
EOF
pass 'socket activation listener owned by systemd'
reject check_listener_text 22 no <<'EOF'
LISTEN 0 4096 *:22 *:* users:(("systemd",pid=1,fd=77))
EOF
reject check_listener_text 22 yes <<'EOF'
LISTEN 0 4096 *:22 *:* users:(("python3",pid=123,fd=3))
EOF
reject check_listener_text 22 no <<'EOF'
LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=120,fd=3))
EOF
reject check_listener_text 22 no <<'EOF'
LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=120,fd=3))
LISTEN 0 128 127.0.0.1:2222 0.0.0.0:* users:(("sshd",pid=120,fd=4))
EOF
reject check_listener_text 22 no </dev/null
reject check_listener_text 22 no <<'EOF'
LISTEN 0 128 *:22 *:* users:(("sshd",pid=120,fd=3),("foreign",pid=50,fd=4))
EOF
pass 'wrong, additional, absent and foreign listeners rejected'
render_ssh_policy | grep -Fxq 'PermitRootLogin no'
render_updates | grep -Fxq 'Unattended-Upgrade::Automatic-Reboot "false";'
# Perl 变量必须保留字面量。
# shellcheck disable=SC2016
render_restart_policy | grep -Fxq '$nrconf{restart} = '\''a'\'';'
pass 'rendered authentication and daily restart policy'
if command -v jq >/dev/null; then
    clean_nft <<'EOF'
{"nftables":[{"metainfo":{"version":"fixture"}},{"table":{"family":"ip","name":"filter"}},{"chain":{"family":"ip","table":"filter","name":"INPUT","type":"filter","hook":"input","prio":0,"policy":"accept"}}]}
EOF
    reject clean_nft <<'EOF'
{"nftables":[{"table":{"family":"inet","name":"unknown"}}]}
EOF
    reject clean_nft <<'EOF'
{"nftables":[{"rule":{"family":"ip","table":"filter","chain":"INPUT","expr":[{"accept":null}]}}]}
EOF
    pass 'unknown native firewall tables and rules rejected'
else
    printf 'NOT RUN nft JSON tests: jq missing\n'
    exit 1
fi
clean_legacy <<'EOF'
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
COMMIT
EOF
reject clean_legacy <<'EOF'
*filter
:UNKNOWN - [0:0]
COMMIT
EOF
pass 'unknown legacy chains rejected'
# CLI 负向必须在 preflight 前失败；主进程绝不能运行实际安装路径。
bash "$ROOT/scripts/harden-vps.sh" --help >/dev/null
reject bash "$ROOT/scripts/harden-vps.sh" prepare --admin demo --ssh-port 22
reject bash "$ROOT/scripts/harden-vps.sh" apply --admin demo --ssh-port 22
reject bash "$ROOT/scripts/harden-vps.sh" prepare --admin demo --admin again --ssh-port 22 --public-key /root/a.pub
reject bash "$ROOT/scripts/harden-vps.sh" prepare apply
pass 'separate CLI calls and required explicit inputs'
printf 'Hardening unit checks passed: %s\n' "$COUNT"
