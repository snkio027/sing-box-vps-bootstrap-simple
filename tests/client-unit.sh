#!/usr/bin/env bash
# 客户端逻辑测试：合成地址/密钥/HTTPS 响应，不读取用户配置，不连接真实 VPS。
# macOS 额外调用现有 Homebrew 依赖检查和 sing-box check；测试本身不安装或升级软件。
# 如果原生依赖缺失，整条命令失败，前面已通过的用例不能当成完整套件通过。
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR source=../scripts/connect-vps.sh
source "$ROOT/scripts/connect-vps.sh"
# Test runners also use their installed jq/OpenSSL; Mac CI installs current Homebrew versions.
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
TEMP=$(mktemp -d)
trap 'rm -rf -- "$TEMP"' EXIT
WORK="$TEMP/work"
mkdir "$WORK"
COUNT=0
pass() { COUNT=$((COUNT + 1)); printf 'PASS %s\n' "$1"; }
# 在隔离子 shell 捕获 die/exit，避免一个预期失败终止整个测试进程。
reject() { if ("$@") > "$TEMP/rejected" 2>&1; then say 'Expected rejection.'; exit 1; fi; }

# Linux only adapts BSD stat; production jq parsing is exercised on both platforms.
if [[ $(uname -s) != Darwin ]]; then
    file_info() { stat -c '%u %a %h' "$1"; }
    file_size() { stat -c '%s' "$1"; }
fi

# 文档地址只用于输入验证；这里不会尝试拨号或测量可达性。
valid_ipv4 203.0.113.7
valid_ipv4 198.51.100.24
for invalid in 256.1.2.3 01.2.3.4 127.0.0.1 10.0.0.1 172.16.0.1 192.168.1.1 198.18.0.43 224.0.0.1 example.com '1.2.3.4"'; do
    reject valid_ipv4 "$invalid"
done
pass 'numeric IPv4 validation and fake-IP/local destination rejection'
valid_interface en4
valid_interface en0
for invalid in utun5 lo0 'en4"' 'en4;id' ''; do reject valid_interface "$invalid"; done
pass 'physical interface input validation'

# 权限、软/硬链接和受保护文件名均应拒绝；源文件和导出文件必须保持私有。
# 此处使用外部 OpenSSL；后面的同名函数仅用于环境变量泄露回归测试。
command openssl rand -base64 16 > "$TEMP/key-input"
jq -n --rawfile key "$TEMP/key-input" '{inbounds:[{type:"shadowsocks",method:"2022-blake3-aes-128-gcm",listen_port:443,password:($key|rtrimstr("\n"))}]}' > "$TEMP/source.json"
private_file "$TEMP/source.json"
chmod 0644 "$TEMP/source.json"
reject private_file "$TEMP/source.json"
chmod 0600 "$TEMP/source.json"
ln -s "$TEMP/source.json" "$TEMP/link.json"
reject private_file "$TEMP/link.json"
ln "$TEMP/source.json" "$TEMP/hard.json"
reject private_file "$TEMP/hard.json"
rm "$TEMP/hard.json"
reject private_file "$TEMP/secret"
reject private_file "$TEMP/vps-conn.sh"
pass 'credential-file permissions, links and protected filename rejection'

# 使用生产 render_client 验证真实 JSON 字段、密钥复用以及源文件不变。
BEFORE=$(shasum -a 256 "$TEMP/source.json")
render_client "$TEMP/source.json" inbounds.0.password 203.0.113.7 en4 "$TEMP/client.json"
jq -e '.inbounds==[{type:"socks",listen:"127.0.0.1",listen_port:17890}] and (.outbounds|length)==1 and
 .outbounds[0].type=="shadowsocks" and .outbounds[0].server=="203.0.113.7" and .outbounds[0].server_port==443 and
 .outbounds[0].bind_interface=="en4" and .outbounds[0].network=="tcp" and .outbounds[0].multiplex.enabled==false and
 .route.final=="proxy"' "$TEMP/client.json" >/dev/null
[[ $(file_info "$TEMP/client.json" | cut -d ' ' -f 2) == 600 ]]
pass 'private loopback-only profile, TCP SS2022, explicit interface and no direct fallback'
jq -r '.outbounds[0].password' "$TEMP/client.json" > "$TEMP/key-output"
cmp "$TEMP/key-input" "$TEMP/key-output"
[[ $(shasum -a 256 "$TEMP/source.json") == "$BEFORE" ]]
pass 'exact key import without modifying the source'

# Previously-exported names must not turn the imported key into a subprocess environment value.
export key=fixture canonical=fixture
openssl() {
    sh -c 'test "${key:-fixture}" = fixture && test "${canonical:-fixture}" = fixture' || return 1
    command openssl "$@"
}
render_client "$TEMP/source.json" inbounds.0.password 203.0.113.7 en4 "$TEMP/without-export.json"
unset -f openssl
unset key canonical
pass 'imported key is not exposed through inherited exported variable names'

# 失败发生在输出替换之前，已有客户端配置必须仍为原内容。
jq '.inbounds[0].password="invalid"' "$TEMP/source.json" > "$TEMP/bad.json"
CLIENT_BEFORE=$(shasum -a 256 "$TEMP/client.json")
reject render_client "$TEMP/bad.json" inbounds.0.password 203.0.113.7 en4 "$TEMP/client.json"
[[ $(shasum -a 256 "$TEMP/client.json") == "$CLIENT_BEFORE" ]]
printf '{invalid json' > "$TEMP/bad.json"
reject render_client "$TEMP/bad.json" inbounds.0.password 203.0.113.7 en4 "$TEMP/client.json"
pass 'bad source fails without replacing the existing client profile'

# 保存文件中的额外 TUN/direct 字段不能穿透固定配置重建逻辑。
jq '.inbounds += [{type:"tun"}] | .outbounds += [{type:"direct"}] | .route.final="direct"' "$TEMP/client.json" > "$TEMP/custom.json"
render_client "$TEMP/custom.json" outbounds.0.password 203.0.113.7 en4 "$TEMP/restored.json"
cmp "$TEMP/client.json" "$TEMP/restored.json"
pass 'saved custom fields cannot introduce TUN or bypass the VPS'

# 这是原生配置语法检查，不启动客户端，也不证明网卡绑定或公网 SS2022 已通过。
if [[ $(uname -s) == Darwin ]]; then
    require_dependencies
    "$BIN" check -c "$TEMP/client.json" > "$TEMP/native-check.log" 2>&1
    pass 'current Homebrew sing-box accepts the generated client configuration'
fi

# Synthetic curl contract, no network: assert proxy/DNS bypass settings and validate rejection paths.
LOG="$TEMP/client.log"
# 仅在本测试进程里替换 listener/curl；生产脚本并没有这些测试替身。
# CHILD 使用当前测试 PID 供 kill -0 检查，结束前清空，避免误用生产清理函数。
CHILD=$$
owns_listener() { return 0; }
PROBE_CASE=ok
curl() {
    local output='' proxy='' bypass=missing previous='' argument first=$1
    [[ $first == -q ]] || return 2
    for argument in "$@"; do
        case "$previous" in --output) output=$argument ;; --proxy) proxy=$argument ;; --noproxy) bypass=$argument ;; esac
        case "$argument" in -k|--insecure|-L|--location) return 2 ;; esac
        previous=$argument
    done
    [[ $proxy == socks5h://127.0.0.1:17890 && -z $bypass && $previous == https://www.cloudflare.com/cdn-cgi/trace ]] || return 2
    printf 'h=www.cloudflare.com\nip=203.0.113.7\n' > "$output"
    case "$PROBE_CASE" in
        ok) printf 200 ;;
        status) printf 503 ;;
        marker) printf 'unexpected\n' > "$output"; printf 200 ;;
        network) return 7 ;;
    esac
}
probe_https > "$TEMP/probe-output"
for PROBE_CASE in status marker network; do reject probe_https; done
CHILD=''
unset -f curl owns_listener
pass 'HTTPS check requires forced SOCKS5, TLS verification, HTTP 200 and expected body'

# CLI 失败路径应在依赖安装或真实客户端启动之前返回。
"$BASH" "$ROOT/scripts/connect-vps.sh" --help > "$TEMP/help"
reject "$BASH" "$ROOT/scripts/connect-vps.sh" setup
reject "$BASH" "$ROOT/scripts/connect-vps.sh" check extra
reject "$BASH" "$ROOT/scripts/connect-vps.sh" --unknown
pass 'help and invalid CLI return before installation'
printf 'Client checks passed: %s\n' "$COUNT"
