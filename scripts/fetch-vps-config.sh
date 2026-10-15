#!/opt/homebrew/bin/bash
# 单独取回最小 SS2022 投影；不启动代理、不改网络、不下载 REALITY 私钥。
# 私钥仅交给本机 OpenSSH；远端只有固定的只读命令和 sudo -n。
set +x
set +a
set -Eeuo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C LANG=C
unset BASH_ENV ENV CDPATH
umask 077
WORK='' CHILD=''
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Usage: /opt/homebrew/bin/bash fetch-vps-config.sh VPS_IPV4 SSH_PORT ADMIN IDENTITY KNOWN_HOSTS INTERFACE OUTPUT.json
Use a verified private known_hosts file and an existing 0700 output directory.
Output must not exist. Only SS2022 client fields are fetched; no keys are printed.
Apple Silicon Mac; current Homebrew Bash 5.3+, jq and OpenSSL. No automatic installs.
Encrypted SSH keys require a previously unlocked SSH agent. No password prompts.
Next: connect-vps.sh setup VPS_IPV4 OUTPUT.json INTERFACE
HELP
}
file_info() { stat -f '%u %Lp %l' "$1"; }
file_size() { stat -f '%z' "$1"; }
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

# 路径先转成实际目录，再检查所有祖先；系统 /tmp、/var 别名不会被误判。
# 只信任 root 或当前用户，拒绝可被其他用户替换的目录；root sticky 临时目录除外。
controlled_directory() {
    local path=$1 owner mode links
    while :; do
        [[ -d $path && ! -L $path ]] || die 'Unsafe directory.'
        read -r owner mode links < <(file_info "$path")
        [[ $owner == 0 || $owner == "$EUID" ]] || die 'Directory has an unrelated owner.'
        if (( (8#$mode & 0022) != 0 )); then
            if [[ $owner != 0 ]] || (( (8#$mode & 01000) == 0 )); then die 'Directory is writable by others.'; fi
        fi
        [[ $path != / ]] || break
        path=${path%/*}; path=${path:-/}
    done
}
private_input() {
    local path=$1 owner mode links parent
    case "${path##*/}" in secret|vps-conn.sh) die 'Protected connection file refused.' ;; esac
    [[ -f $path && ! -L $path ]] || die 'Input must be a regular file, not a link.'
    parent=$(cd -P -- "${path%/*}" && pwd -P)
    controlled_directory "$parent"
    path="$parent/${path##*/}"
    [[ -f $path && ! -L $path ]] || die 'Input resolved to a link or non-file.'
    read -r owner mode links < <(file_info "$path")
    if [[ $owner != "$EUID" || $links != 1 ]] || (( (8#$mode & 0077) != 0 )); then
        die 'Input must be your private single-link file (0600 or stricter).'
    fi
    printf '%s\n' "$path"
}
require_dependencies() {
    local brew=/opt/homebrew/bin/brew prefix expected outdated
    [[ $(uname -s) == Darwin && $(uname -m) == arm64 && $EUID != 0 ]] || die 'Use a normal Apple Silicon Mac user.'
    (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3) )) || die 'Use current Homebrew Bash 5.3+.'
    [[ -x $brew && -x /opt/homebrew/opt/bash/bin/bash ]] || die 'Prepare Homebrew Bash, jq and OpenSSL first.'
    # shellcheck disable=SC2016
    expected=$(/opt/homebrew/opt/bash/bin/bash -c 'printf "%s" "${BASH_VERSION%%(*}"')
    [[ $BASH -ef /opt/homebrew/opt/bash/bin/bash && ${BASH_VERSION%%(*} == "$expected" ]] || die 'Use the current Homebrew Bash.'
    prefix=$("$brew" --prefix openssl)
    [[ -x $prefix/bin/openssl && -x /opt/homebrew/opt/jq/bin/jq ]] || die 'Prepare Homebrew jq and OpenSSL first.'
    outdated=$(HOMEBREW_NO_AUTO_UPDATE=1 "$brew" outdated --formula bash jq openssl)
    [[ -z $outdated ]] || die 'Refresh/update Homebrew Bash, jq and OpenSSL first.'
    [[ $(HOMEBREW_NO_AUTO_UPDATE=1 "$brew" list --versions bash jq openssl) != *HEAD* ]] || die 'Stable formulas required.'
    export PATH="/opt/homebrew/opt/jq/bin:$prefix/bin:$PATH"
}
check_interface() {
    ifconfig "$1" 2>/dev/null | grep -q 'status: active' || die 'Selected physical interface is missing or inactive.'
}
# 只含校验过的 enN 与 OpenSSH token，不拼入地址、路径或秘密。
proxy_command() { printf '/usr/bin/nc -4 -b %s %%h %%p' "$INTERFACE"; }
cleanup() {
    if [[ -n $CHILD ]]; then kill "$CHILD" 2>/dev/null || true; wait "$CHILD" 2>/dev/null || true; fi
    [[ -z $WORK ]] || rm -rf -- "$WORK"
}
# 单个普通 link(2) 发布：已有文件、目录、软链接及竞争创建均失败，不用会覆盖的 mv。
publish_projection() {
    /bin/link "$WORK/projection.json" "$OUTPUT" 2>/dev/null || die 'Output appeared or cannot be published; nothing overwritten.'
    rm -- "$WORK/projection.json"
}
# 远端输出后再检查一次精确形状及规范 Base64；未知额外字段/多文档不放行。
validate_projection() {
    jq -e -s 'length==1 and (.[0] |
      . == {inbounds:[{type:"shadowsocks",method:"2022-blake3-aes-128-gcm",listen_port:443,
        network:"tcp",password:.inbounds[0].password}]} and
      (.inbounds[0].password|type=="string" and test("^[A-Za-z0-9+/]{22}==$")))' "$WORK/raw.json" >/dev/null 2>&1 ||
        die 'Remote projection is invalid; no output published.'
    jq -jr '.inbounds[0].password' "$WORK/raw.json" > "$WORK/key.encoded"
    openssl base64 -d -A -in "$WORK/key.encoded" -out "$WORK/key.raw" 2>/dev/null || die 'Invalid key encoding.'
    [[ $(file_size "$WORK/key.raw") == 16 ]] || die 'Invalid key length.'
    openssl base64 -A -in "$WORK/key.raw" | cmp -s - "$WORK/key.encoded" || die 'Noncanonical key encoding.'
    jq . "$WORK/raw.json" > "$WORK/projection.json"
    chmod 0600 "$WORK/projection.json"
}
# 无 TTY、无 SSH 配置继承、无连接复用、仅指定身份/已核验主机密钥；不修改 known_hosts。
# agent 可解锁指定的加密私钥，但 IdentitiesOnly 不会尝试其他身份，也不转发 agent。
build_ssh_command() {
    local proxy
    proxy=$(proxy_command)
    FETCH_SSH=(/usr/bin/ssh -F /dev/null -T -p "$PORT" -l "$ADMIN" -i "$IDENTITY" \
       -o BatchMode=yes -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
       -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o ForwardAgent=no \
       -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519 \
       -o "UserKnownHostsFile=\"$WORK/known_hosts\"" -o GlobalKnownHostsFile=/dev/null \
       -o UpdateHostKeys=no -o VerifyHostKeyDNS=no -o ControlMaster=no -o ControlPath=none \
       -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
       -o "ProxyCommand=$proxy" )
}
remote_script() {
    cat <<'REMOTE'
set +x
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
# 重启会清空 /run。只允许排他新建零字节运行时锁；不创建持久配置/导出文件。
lock=/run/lock/sing-box-install.lock
if [[ ! -e $lock && ! -L $lock ]]; then
    (umask 077; set -o noclobber; : > "$lock") 2>/dev/null || true
fi
[[ -f $lock && ! -L $lock && $(stat -c '%u:%a:%h:%s' "$lock") == 0:600:1:0 ]]
exec 9< "$lock"
flock -s -w 5 9
for marker in /var/lib/sing-box-maintenance/pending /var/lib/sing-box/install-restart-required; do
    [[ ! -e $marker && ! -L $marker ]]
done
[[ ! -L /etc/sing-box && -f /etc/sing-box/config.json && ! -L /etc/sing-box/config.json ]]
[[ $(stat -c '%U:%G:%a:%h' /etc/sing-box/config.json) == root:sing-box:640:1 ]]
jq -e -s '
  if length==1 then .[0] else error("Expected one JSON document") end |
  [.inbounds[] | select(.type=="shadowsocks")] |
  if length==1 then .[0] else error("Expected one SS2022 inbound") end |
  if .method=="2022-blake3-aes-128-gcm" and .listen_port==443 and .network=="tcp" and
     (.password|type=="string" and test("^[A-Za-z0-9+/]{22}==$")) then
    {inbounds:[{type,method,listen_port,network,password}]}
  else error("Unsupported SS2022 input") end
' /etc/sing-box/config.json
REMOTE
}
fetch_projection() {
    build_ssh_command
    remote_script > "$WORK/remote.sh"
    (ulimit -f 16
     exec "${FETCH_SSH[@]}" "$SERVER" 'exec /usr/bin/timeout 20 /usr/bin/sudo -n /usr/bin/bash -se' \
       < "$WORK/remote.sh" > "$WORK/raw.json" 2> "$WORK/ssh.log"
    ) &
    CHILD=$!
    local code=0
    wait "$CHILD" || code=$?
    CHILD=''
    [[ $code == 0 ]] || die 'SSH/sudo/export failed; no output published. Check identity, host key and server state privately.'
}
main() {
    [[ ${1:-} != --help && ${1:-} != -h ]] || { usage; return; }
    [[ $# == 7 ]] || die 'Use --help for seven required non-secret inputs.'
    SERVER=$1 PORT=$2 ADMIN=$3 IDENTITY=$4 KNOWN=$5 INTERFACE=$6 OUTPUT=$7
    valid_ipv4 "$SERVER" || die 'Use a public numeric IPv4.'
    if [[ ! $PORT =~ ^[1-9][0-9]{0,4}$ ]] || (( 10#$PORT > 65535 )); then die 'Invalid SSH port.'; fi
    [[ $ADMIN =~ ^[a-z_][a-z0-9_-]{0,30}$ && $ADMIN != root && $ADMIN != sing-box ]] || die 'Use the key administrator.'
    [[ $INTERFACE =~ ^en[0-9]+$ ]] || die 'Use a physical enN interface.'
    local path parent name owner mode links lookup
    # OpenSSH 对配置路径解释 token/变量；明确拒绝这些字符，允许普通带空格路径。
    for path in "$IDENTITY" "$KNOWN" "$OUTPUT"; do
        [[ $path == /* && $path != *[$'\n\r\"%$']* ]] || die 'Use absolute paths without SSH expansion characters.'
    done
    IDENTITY=$(private_input "$IDENTITY"); KNOWN=$(private_input "$KNOWN")
    [[ ! -e $OUTPUT && ! -L $OUTPUT ]] || die 'Output already exists; choose a new file.'
    parent=${OUTPUT%/*}; name=${OUTPUT##*/}
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.json$ && ! -L $parent ]] || die 'Use a plain .json filename in a real directory.'
    parent=$(cd -P -- "$parent" && pwd -P)
    controlled_directory "$parent"
    read -r owner mode links < <(file_info "$parent")
    [[ $owner == "$EUID" && $mode == 700 ]] || die 'Output directory must belong to you with mode 0700.'
    OUTPUT="$parent/$name"
    for path in "$IDENTITY" "$KNOWN" "$OUTPUT"; do
        [[ $path != *[$'\n\r\"%$']* ]] || die 'Resolved path contains SSH expansion characters.'
    done
    require_dependencies
    check_interface "$INTERFACE"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    WORK=$(mktemp -d "$parent/.fetch.XXXXXXXX")
    lookup=$SERVER; [[ $PORT == 22 ]] || lookup="[$SERVER]:$PORT"
    /usr/bin/ssh-keygen -F "$lookup" -f "$KNOWN" > "$WORK/found" 2>/dev/null || die 'No verified host key for this address/port.'
    awk '!/^#/ && NF {print}' "$WORK/found" > "$WORK/known_hosts"
    awk 'NF!=3 || $2!="ssh-ed25519" {bad=1} END {exit (bad || NR!=1)}' "$WORK/known_hosts" || die 'Require one matching Ed25519 host-key record.'
    fetch_projection
    validate_projection
    publish_projection
    printf 'PASS: private SS2022 projection saved; existing files unchanged.\n'
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
