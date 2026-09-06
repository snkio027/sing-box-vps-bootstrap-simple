#!/opt/homebrew/bin/bash
# macOS Apple Silicon; one terminal-owned SOCKS5 client, no system networking changes.
set +x
set +a
set -Eeuo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C LANG=C
unset BASH_ENV ENV CDPATH
umask 077

WORK='' CHILD='' LOCKED=0

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Usage: /opt/homebrew/bin/bash connect-vps.sh setup VPS_IPV4 PRIVATE_SERVER_JSON [INTERFACE]
       /opt/homebrew/bin/bash connect-vps.sh [run|check]

setup: import the VPS config privately; default interface en4.
run:   check HTTPS, then keep SOCKS5 at 127.0.0.1:17890 running until Ctrl+C.
check: check HTTPS through a temporary client, then stop it.
Requires Apple Silicon macOS and the current Homebrew stable dependencies.
Prepare/update: brew update
                brew install --formula bash curl jq openssl sing-box
                brew upgrade --formula --no-ask bash curl jq openssl sing-box
Run as your normal user, without sudo. No keys are printed.
HELP
}

file_size() { stat -f '%z' "$1"; }
file_info() { stat -f '%u %Lp %l' "$1"; }
json_get() {
    local file=$1
    [[ $file == /* ]] || file="$PWD/$file"
    jq -er --arg path "$2" 'getpath($path|split(".")|map(tonumber? // .)) |
      select(type=="string" or type=="number")' "$file"
}

private_file() {
    local owner mode links
    case "${1##*/}" in secret|vps-conn.sh) die 'Protected connection files must not be used.' ;; esac
    [[ -f $1 && ! -L $1 ]] || die 'Expected a private regular file, not a symlink.'
    read -r owner mode links < <(file_info "$1")
    if [[ $owner != "$EUID" || $links != 1 ]] || (( (8#$mode & 0077) != 0 )); then
        die 'File must belong to you with mode 600 (or stricter) and no hardlinks.'
    fi
}

valid_ipv4() {
    local part
    local -a octets
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$1"
    for part in "${octets[@]}"; do
        [[ $part == 0 || $part != 0* ]] && (( 10#$part <= 255 )) || return 1
    done
    # A remote public VPS is required; refuse local, multicast and benchmarking/fake-IP ranges.
    (( octets[0] > 0 && octets[0] < 224 && octets[0] != 10 && octets[0] != 127 &&
       !(octets[0] == 169 && octets[1] == 254) &&
       !(octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) &&
       !(octets[0] == 192 && octets[1] == 168) &&
       !(octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127) &&
       !(octets[0] == 198 && (octets[1] == 18 || octets[1] == 19)) ))
}

valid_interface() { [[ $1 =~ ^en[0-9]+$ ]]; }

render_client() {
    local source=$1 key_path=$2 server=$3 interface=$4 output=$5 key canonical prefix
    export -n key canonical
    [[ $source == /* ]] || source="$PWD/$source"
    valid_ipv4 "$server" || die 'Use the public numeric IPv4 address of your VPS.'
    valid_interface "$interface" || die 'Use a physical macOS interface such as en4 or en0.'
    private_file "$source"
    prefix=${key_path%.password}
    [[ $(json_get "$source" "$prefix.type" 2>/dev/null) == shadowsocks &&
       $(json_get "$source" "$prefix.method" 2>/dev/null) == 2022-blake3-aes-128-gcm ]] ||
        die 'The source must contain an SS2022 AES-128 configuration.'
    key=$(json_get "$source" "$key_path" 2>/dev/null) || die 'Cannot read the source key.'
    [[ $key =~ ^[A-Za-z0-9+/]{22}==$ ]] || die 'Invalid SS2022 key format.'
    printf '%s' "$key" | openssl base64 -d -A > "$WORK/key.raw"
    [[ $(file_size "$WORK/key.raw") == 16 ]] || die 'SS2022 key must decode to 16 bytes.'
    canonical=$(openssl base64 -A -in "$WORK/key.raw")
    [[ $key == "$canonical" ]] || die 'SS2022 key must be canonical base64.'
    # Inputs are validated; the key enters a private file via stdin, never argv/environment.
    cat > "$output" <<JSON
{
  "log": {"level": "error", "timestamp": true},
  "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": 17890}],
  "outbounds": [{"type": "shadowsocks", "tag": "proxy", "server": "$server",
    "server_port": 443, "method": "2022-blake3-aes-128-gcm", "password": "$key",
    "network": "tcp", "multiplex": {"enabled": false},
    "bind_interface": "$interface", "connect_timeout": "10s"}],
  "route": {"final": "proxy"}
}
JSON
}

require_dependencies() {
    local brew=/opt/homebrew/bin/brew openssl_prefix brew_bash expected outdated executable versions
    [[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || die 'Use a native Apple Silicon Mac terminal.'
    (( EUID != 0 )) || die 'Run as your normal Mac user, without sudo.'
    [[ -x $brew ]] || die 'Install Homebrew from https://brew.sh first.'
    brew_bash=/opt/homebrew/opt/bash/bin/bash
    [[ -x $brew_bash ]] || die 'Install the current Homebrew Bash; see --help.'
    (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3) )) ||
        die 'Use /opt/homebrew/bin/bash, not the system Bash. See --help.'
    # Expand the version in the selected Homebrew interpreter.
    # shellcheck disable=SC2016
    expected=$("$brew_bash" --noprofile --norc -c 'printf "%s" "${BASH_VERSION%%(*}"')
    [[ $BASH -ef $brew_bash && ${BASH_VERSION%%(*} == "$expected" ]] ||
        die 'Run this script with the current /opt/homebrew/bin/bash.'
    openssl_prefix=$("$brew" --prefix openssl) || die 'Install the Homebrew dependencies; see --help.'
    for executable in /opt/homebrew/opt/curl/bin/curl /opt/homebrew/opt/jq/bin/jq \
        "$openssl_prefix/bin/openssl" /opt/homebrew/opt/sing-box/bin/sing-box; do
        [[ -x $executable ]] || die 'A Homebrew dependency is missing; see --help.'
    done
    # curl can be keg-only: explicit opt paths prevent falling back to older macOS tools.
    export PATH="/opt/homebrew/opt/curl/bin:$openssl_prefix/bin:/opt/homebrew/opt/jq/bin:/opt/homebrew/opt/sing-box/bin:/opt/homebrew/opt/bash/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    outdated=$(HOMEBREW_NO_AUTO_UPDATE=1 "$brew" outdated --formula bash curl jq openssl sing-box) ||
        die 'Cannot inspect dependency versions; refresh Homebrew and retry.'
    [[ -z $outdated ]] || die 'Dependencies are outdated; run the update commands shown by --help.'
    BIN=/opt/homebrew/opt/sing-box/bin/sing-box
    versions=$(HOMEBREW_NO_AUTO_UPDATE=1 "$brew" list --versions bash curl jq openssl sing-box)
    [[ $versions != *HEAD* ]] || die 'Install stable Homebrew formulas; HEAD builds are unsupported.'
    say "$versions"
}

cleanup() {
    if [[ -n $CHILD ]]; then
        kill "$CHILD" 2>/dev/null || true
        wait "$CHILD" 2>/dev/null || true
    fi
    [[ -z $WORK ]] || rm -rf -- "$WORK"
    if (( LOCKED )); then rmdir "$STATE/running.lock" 2>/dev/null || true; fi
}

prepare_state() {
    local owner mode links
    [[ $HOME == /* ]] || die 'HOME must be an absolute path.'
    STATE="$HOME/Library/Application Support/sing-box-vps"
    CONFIG="$STATE/client.json" LOG="$STATE/client.log"
    [[ ! -L $STATE ]] || die 'Application state directory must not be a symlink.'
    # Parent directories keep their existing permissions; only our own directory is private.
    mkdir -p "${STATE%/*}"
    if [[ ! -e $STATE ]]; then mkdir -m 0700 "$STATE"; fi
    read -r owner mode links < <(file_info "$STATE")
    [[ $owner == "$EUID" && $mode == 700 ]] || die 'Application state directory must belong to you with mode 700.'
    mkdir "$STATE/running.lock" 2>/dev/null || die "Already running, or interrupted lock remains: $STATE/running.lock"
    LOCKED=1
    WORK=$(mktemp -d "$STATE/tmp.XXXXXXXX")
    if [[ -e $CONFIG || -L $CONFIG ]]; then private_file "$CONFIG"; fi
    if [[ -e $LOG || -L $LOG ]]; then private_file "$LOG"; fi
}

check_interface() {
    ifconfig "$1" 2>/dev/null | grep -q 'status: active' || die 'Selected interface is missing or inactive.'
}

check_config() {
    "$BIN" check -c "$WORK/client.json" > "$LOG" 2>&1 || die "Configuration rejected; inspect privately: $LOG"
}

owns_listener() {
    [[ $(lsof -nP -a -p "$CHILD" -iTCP@127.0.0.1:17890 -sTCP:LISTEN -t 2>/dev/null) == "$CHILD" ]]
}

probe_https() {
    local code
    code=$(curl -q --silent --show-error --noproxy '' --proxy socks5h://127.0.0.1:17890 \
        --connect-timeout 8 --max-time 20 --max-filesize 65536 --output "$WORK/response" \
        --write-out '%{http_code}' https://www.cloudflare.com/cdn-cgi/trace 2>> "$LOG") ||
        die "HTTPS request failed; inspect privately: $LOG"
    if [[ $code != 200 ]] || ! grep -Fxq 'h=www.cloudflare.com' "$WORK/response" ||
        ! grep -Eq '^ip=.+$' "$WORK/response"; then die 'HTTPS target returned an unexpected status/body.'; fi
    if ! kill -0 "$CHILD" 2>/dev/null || ! owns_listener; then die 'Client stopped during HTTPS verification.'; fi
    say 'PASS: SS2022 HTTPS request, HTTP 200 and expected response; TLS verification enabled.'
}

main() {
    local command=${1:-run} server interface _ code
    case "$command" in
        -h|--help) usage; return ;;
        setup) [[ $# == 3 || $# == 4 ]] || die 'Use: setup VPS_IPV4 PRIVATE_SERVER_JSON [INTERFACE]' ;;
        run|check) [[ $# -le 1 ]] || die 'Unexpected arguments.' ;;
        *) die 'Use --help for usage.' ;;
    esac
    trap 'printf "ERROR: command failed (exit %s); inspect the private client.log if present.\n" "$?" >&2' ERR
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    require_dependencies
    prepare_state
    if [[ $command == setup ]]; then
        server=$2 interface=${4:-en4}
        render_client "$3" inbounds.0.password "$server" "$interface" "$WORK/client.json"
        [[ $(json_get "$3" inbounds.0.listen_port 2>/dev/null) == 443 ]] || die 'Source VPS configuration must use port 443.'
        check_interface "$interface"
        check_config
        if [[ -f $CONFIG ]]; then
            if [[ -e $STATE/client.previous.json || -L $STATE/client.previous.json ]]; then private_file "$STATE/client.previous.json"; fi
            cp "$CONFIG" "$WORK/previous.json"
            mv -f "$WORK/previous.json" "$STATE/client.previous.json"
        fi
        mv -f "$WORK/client.json" "$CONFIG"
        say 'Client configured. Run: /opt/homebrew/bin/bash connect-vps.sh'
        return
    fi
    [[ -f $CONFIG ]] || die 'Run setup first.'
    server=$(json_get "$CONFIG" outbounds.0.server 2>/dev/null) || die 'Cannot read saved server address.'
    interface=$(json_get "$CONFIG" outbounds.0.bind_interface 2>/dev/null) || die 'Cannot read saved interface.'
    # Rebuild the fixed profile so saved custom fields cannot introduce TUN or a direct fallback.
    render_client "$CONFIG" outbounds.0.password "$server" "$interface" "$WORK/client.json"
    check_interface "$interface"
    if lsof -nP -iTCP:17890 -sTCP:LISTEN -t >/dev/null 2>&1; then die 'Local TCP port 17890 is occupied.'; fi
    check_config
    "$BIN" run -c "$WORK/client.json" > "$LOG" 2>&1 &
    CHILD=$!
    for _ in {1..50}; do
        kill -0 "$CHILD" 2>/dev/null || die "Client exited; inspect privately: $LOG"
        if owns_listener; then break; fi
        sleep 0.1
    done
    owns_listener || die "Client did not open its SOCKS5 listener; inspect privately: $LOG"
    probe_https
    if [[ $command == check ]]; then return; fi
    say 'SOCKS5 ready: 127.0.0.1:17890. Keep this terminal open; Ctrl+C stops this client.'
    say 'Use in another terminal: /opt/homebrew/opt/curl/bin/curl --noproxy "" --proxy socks5h://127.0.0.1:17890 https://example.com'
    if wait "$CHILD"; then code=0; else code=$?; fi
    CHILD=''
    die "Client exited (status $code); inspect privately: $LOG"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
