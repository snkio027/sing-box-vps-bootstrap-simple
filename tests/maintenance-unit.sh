#!/usr/bin/bash
# 合成配置测试，不连接真实 VPS、不改本机服务；原生和 systemd 运行另见 VM。
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR source=../scripts/maintain-vps.sh
source "$ROOT/scripts/maintain-vps.sh"
TEMP=$(mktemp -d)
trap 'rm -rf -- "$TEMP"' EXIT
COUNT=0
pass() { COUNT=$((COUNT+1)); printf 'PASS %s\n' "$1"; }
reject() { if ("$@") > "$TEMP/rejection" 2>&1; then say 'Expected rejection'; exit 1; fi; }
for host in www.example.com localhost 127.0.0.1; do valid_host "$host"; done
for host in '' '-bad' 'bad-' 'a..b' 'https://example.com' 'a b' 'x;true' '../foo'; do reject valid_host "$host"; done
valid_port 443; valid_port 65535
for port in '' 0 0443 65536 '443;true'; do reject valid_port "$port"; done
pass 'strict non-secret CLI fields'
validate_config "$ROOT/examples/1.14.0/server.example.json"
validate_config "$ROOT/examples/1.14.2/server.example.json"
pass 'known SS2022 and dual protocol profiles'
for filter in '.inbounds[0].listen_port=8443' '.inbounds[1].users[0].flow=""' \
  '.inbounds[1].tls.reality.private_key="invalid"' '.inbounds[1].tls.reality.short_id=["bad"]' \
  '.route.rules=[]' '.outbounds += [{"type":"direct","tag":"unknown"}]' '.inbounds[1].multiplex={"enabled":true}'; do
    jq "$filter" "$ROOT/examples/1.14.2/server.example.json" > "$TEMP/bad.json"
    reject validate_config "$TEMP/bad.json"
done
pass 'unknown/custom policy and malformed credentials refused'
WORK="$TEMP/render"; mkdir "$WORK"
CONFIG="$ROOT/examples/1.14.0/server.example.json"
HANDSHAKE=www.example.com SERVER_NAME=www.example.com
jq -r '.inbounds[1].users[0].uuid' "$ROOT/examples/1.14.2/server.example.json" > "$WORK/uuid"
jq -r '.inbounds[1].tls.reality.private_key' "$ROOT/examples/1.14.2/server.example.json" > "$WORK/private-key"
jq -r '.inbounds[1].tls.reality.short_id[0]' "$ROOT/examples/1.14.2/server.example.json" > "$WORK/short-id"
render_reality
validate_config "$WORK/candidate.json"
jq -S . "$WORK/candidate.json" > "$TEMP/rendered"
jq -S . "$ROOT/examples/1.14.2/server.example.json" > "$TEMP/expected"
cmp "$TEMP/rendered" "$TEMP/expected"
pass 'render preserves SS credential and expected TCP-only REALITY contract'
bash "$ROOT/scripts/maintain-vps.sh" --help >/dev/null
reject bash "$ROOT/scripts/maintain-vps.sh" upgrade extra
reject bash "$ROOT/scripts/maintain-vps.sh" reality --handshake-server example.com
reject bash "$ROOT/scripts/maintain-vps.sh" reality --handshake-server example.com --server-name example.com --handshake-port 0443
reject bash "$ROOT/scripts/maintain-vps.sh" reality --handshake-server example.com --handshake-server another.com --server-name example.com
pass 'invalid CLI exits before host preflight'
printf 'Maintenance unit checks passed: %s\n' "$COUNT"
