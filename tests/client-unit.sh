#!/usr/bin/env bash
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
reject() { if ("$@") > "$TEMP/rejected" 2>&1; then say 'Expected rejection.'; exit 1; fi; }

# Linux only adapts BSD stat; production jq parsing is exercised on both platforms.
if [[ $(uname -s) != Darwin ]]; then
    file_info() { stat -c '%u %a %h' "$1"; }
    file_size() { stat -c '%s' "$1"; }
fi

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

openssl rand -base64 16 > "$TEMP/key-input"
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

jq '.inbounds[0].password="invalid"' "$TEMP/source.json" > "$TEMP/bad.json"
CLIENT_BEFORE=$(shasum -a 256 "$TEMP/client.json")
reject render_client "$TEMP/bad.json" inbounds.0.password 203.0.113.7 en4 "$TEMP/client.json"
[[ $(shasum -a 256 "$TEMP/client.json") == "$CLIENT_BEFORE" ]]
printf '{invalid json' > "$TEMP/bad.json"
reject render_client "$TEMP/bad.json" inbounds.0.password 203.0.113.7 en4 "$TEMP/client.json"
pass 'bad source fails without replacing the existing client profile'

jq '.inbounds += [{type:"tun"}] | .outbounds += [{type:"direct"}] | .route.final="direct"' "$TEMP/client.json" > "$TEMP/custom.json"
render_client "$TEMP/custom.json" outbounds.0.password 203.0.113.7 en4 "$TEMP/restored.json"
cmp "$TEMP/client.json" "$TEMP/restored.json"
pass 'saved custom fields cannot introduce TUN or bypass the VPS'

if [[ $(uname -s) == Darwin ]]; then
    require_dependencies
    "$BIN" check -c "$TEMP/client.json" > "$TEMP/native-check.log" 2>&1
    pass 'current Homebrew sing-box accepts the generated client configuration'
fi

# Synthetic curl contract, no network: assert proxy/DNS bypass settings and validate rejection paths.
LOG="$TEMP/client.log"
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

"$BASH" "$ROOT/scripts/connect-vps.sh" --help > "$TEMP/help"
reject "$BASH" "$ROOT/scripts/connect-vps.sh" setup
reject "$BASH" "$ROOT/scripts/connect-vps.sh" check extra
reject "$BASH" "$ROOT/scripts/connect-vps.sh" --unknown
pass 'help and invalid CLI return before installation'
printf 'Client checks passed: %s\n' "$COUNT"
