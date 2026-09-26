#!/usr/bin/bash
# 已有 simple-v1 安装的维护入口；升级与添加 REALITY 必须分开调用。
# 只维护本项目 binary/config，不运行 APT、不改 SSH/UFW、不重启整机。
# 失败自动恢复本次文件；SIGKILL/断电后保留 pending 与 root-only 备份供人工恢复。
set +x
set +a
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C LANG=C
unset BASH_ENV ENV CDPATH
umask 077
VERSION=1.14.2
BIN=/usr/local/bin/sing-box
CONFIG=/etc/sing-box/config.json
UNIT=/etc/systemd/system/sing-box.service
STATE=/var/lib/sing-box-maintenance
MARKER='# Managed by prepare-vps.sh (simple-v1)'
WORK='' BACKUP='' STEP=arguments CHANGED=0
HANDSHAKE='' SERVER_NAME='' HANDSHAKE_PORT=443
say() { printf '%s\n' "$*"; }
die() { printf 'ERROR [%s]: %s\n' "$STEP" "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: sudo bash maintain-vps.sh upgrade
       sudo bash maintain-vps.sh reality --handshake-server HOST --server-name NAME [--handshake-port PORT]
upgrade: reviewed 1.14.0 -> 1.14.2, preserving configuration and credentials.
reality: add VLESS + REALITY + Vision on IPv4 TCP 8443; preserve SS2022 TCP 443.
Requires a healthy simple-v1 service and existing dependencies. Unknown binaries,
configs and occupied ports are refused. Reruns retain credentials and healthy PID.
No APT, SSH/firewall changes or machine reboot. Client configuration remains private.
EOF
}
# 旧版本只作为明确允许的升级来源；不能按版本字符串信任任意二进制。
artifact_for_arch() {
    case "$1" in
        amd64)
            OLD_SIZE=91842368
            OLD_SHA=ce3ed8667dd99ff40c85a8b236075e856ea9cb80731b304cedd2a47187828120
            ARCHIVE_SIZE=32302424
            ARCHIVE_SHA=3a15ee1ee918cb5297ccf7fb4356b31ba85f8a7c01da122c5b3e3aeda0568001
            BINARY_SIZE=91951072
            BINARY_SHA=4b5cef575df2e5572eddf7c204b4adea03a27d9721c5e39a89df5fb6977643cb ;;
        arm64)
            OLD_SIZE=85908600
            OLD_SHA=5f4d9ef9436b36a6cb9db8831833264c11fe4cab1622cec465c0acfd3abfffac
            ARCHIVE_SIZE=29564014
            ARCHIVE_SHA=283b31355c1213afe0f6c93498884ef6ff34cd38679789fe1af900d84691e51c
            BINARY_SIZE=86012408
            BINARY_SHA=fb9189e2d14f2795aa86adc070f7a61d1c74c299f519e52a021b1bbc720b4769 ;;
        *) die 'Supported architectures: amd64, arm64.' ;;
    esac
    ARCHIVE_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box_${VERSION}_linux_${1}.deb"
}
safe_path() {
    local path=$1 part walk='' mode
    local -a parts
    [[ $path == /* && $path != *'/../'* && $path != *'/./'* ]] || die 'Unsafe path.'
    IFS=/ read -r -a parts <<< "$path"
    for part in "${parts[@]:1}"; do
        walk+="/$part"
        [[ ! -L $walk ]] || die "Symlink refused: $walk"
        if [[ -e $walk ]]; then
            [[ $(stat -c %u -- "$walk") == 0 ]] || die "Not root-owned: $walk"
            mode=$(stat -c %a -- "$walk")
            if (( (8#$mode & 0022) != 0 )); then
                if [[ ! -d $walk ]] || (( (8#$mode & 01000) == 0 )); then
                    die "Writable by group/others: $walk"
                fi
            fi
        fi
    done
    if [[ -e $path && ! -d $path ]]; then
        [[ -f $path && $(stat -c %h -- "$path") == 1 ]] || die "Not a single-link regular file: $path"
    fi
}

# 返回真假供调用方决定如何报错；先做类型/大小检查，再计算完整文件 SHA-256。
matches_artifact() {
    [[ -f $1 && ! -L $1 && $(stat -c %s -- "$1") == "$2" ]] &&
        [[ $(sha256sum -- "$1" | cut -d ' ' -f 1) == "$3" ]]
}


# 域名/数字 IPv4 是非秘密输入。只接受普通 DNS 标签或 IPv4；不接受 URL、空白和 shell 片段。
valid_host() {
    [[ ${#1} -le 253 && $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $1 != *..* ]] || return 1
    local part
    local -a labels
    IFS=. read -r -a labels <<< "$1"
    for part in "${labels[@]}"; do
        [[ ${#part} -le 63 && $part != -* && $part != *- ]] || return 1
    done
}
valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 )); }

# 精确识别本批管理的配置；不吞掉用户自定义字段，不把未知配置变成我们的模板。
validate_config() {
    jq -e '
      def ss: {type:"shadowsocks",tag:"ss-in",listen:"0.0.0.0",listen_port:443,
        network:"tcp",method:"2022-blake3-aes-128-gcm",password:.password,multiplex:{enabled:true}};
      def reality: {type:"vless",tag:"reality-in",listen:"0.0.0.0",listen_port:8443,
        users:[{name:"owner",uuid:.users[0].uuid,flow:"xtls-rprx-vision"}],
        tls:{enabled:true,server_name:.tls.server_name,reality:{enabled:true,
          handshake:{server:.tls.reality.handshake.server,server_port:.tls.reality.handshake.server_port},
          private_key:.tls.reality.private_key,short_id:.tls.reality.short_id,max_time_difference:"1m"}}};
      (.inbounds|length) as $n |
      ($n==1 or $n==2) and
      (.inbounds[0] == (.inbounds[0]|ss)) and
      (.inbounds[0].password|type=="string" and test("^[A-Za-z0-9+/]{22}==$")) and
      (if $n==2 then
        (.inbounds[1] == (.inbounds[1]|reality)) and
        (.inbounds[1].users[0].uuid|test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
        (.inbounds[1].tls.reality.private_key|test("^[A-Za-z0-9_-]{43}$")) and
        (.inbounds[1].tls.reality.short_id|length==1 and (.[0]|test("^[0-9a-f]{16}$")))
      else true end) and
      (. == {log:{level:"info"},inbounds:.inbounds,outbounds:[{type:"direct",tag:"direct"}],
        route:(if $n==2 then {rules:[{inbound:["reality-in"],network:"udp",action:"reject"}],final:"direct"}
               else {final:"direct"} end)})
    ' "$1" >/dev/null 2>&1 || die 'Unsupported configuration; inspect privately instead of overwriting it.'
}

# 原子发布单个文件。调用前已有可恢复备份，候选与目标处于同一文件系统。
replace_file() {
    local source=$1 target=$2 mode=$3 group=$4 temporary
    safe_path "$target"
    temporary=$(mktemp "${target}.new.XXXXXXXX")
    install -o root -g "$group" -m "$mode" "$source" "$temporary"
    sync -f "$temporary"
    mv -fT "$temporary" "$target"
    sync -f "${target%/*}"
}

# 同时核对进程、restart count、实际二进制和所有 listener；这不是公网链路验收。
healthy() {
    local pid restarts port listeners line _
    pid=$(systemctl show sing-box -p MainPID --value) || return 1
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
    restarts=$(systemctl show sing-box -p NRestarts --value) || return 1
    for _ in 1 2 3 4 5; do
        systemctl is-active --quiet sing-box || return 1
        [[ $(systemctl show sing-box -p MainPID --value) == "$pid" &&
           $(systemctl show sing-box -p NRestarts --value) == "$restarts" &&
           $(readlink -f "/proc/$pid/exe") == "$BIN" ]] || return 1
        cmp -s "/proc/$pid/exe" "$BIN" || return 1
        sleep 1
    done
    for port in $(jq -r '.inbounds[].listen_port' "$CONFIG"); do
        listeners=$(ss -H -ltnp "sport = :$port") || return 1
        [[ -n $listeners ]] || return 1
        while IFS= read -r line; do
            [[ $line == *"0.0.0.0:$port "* && $line == *"pid=$pid,"* ]] || return 1
        done <<< "$listeners"
        listeners=$(ss -H -lunp "sport = :$port") || return 1
        [[ $listeners != *"pid=$pid,"* ]] || return 1
    done
}

preflight() {
    [[ $EUID == 0 ]] || die 'Run as root.'
    [[ $(sed -n 's/^ID=//p' /etc/os-release | tr -d '"') == ubuntu &&
       $(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"') == 24.04 &&
       $(cat /proc/1/comm) == systemd ]] || die 'Ubuntu 24.04 systemd is required.'
    ! systemd-detect-virt --container --quiet || die 'Containers are unsupported.'
    local path command
    for command in jq curl openssl runuser timeout dpkg-deb ss; do command -v "$command" >/dev/null || die 'Install the existing installer dependencies first.'; done
    for path in "$BIN" "$CONFIG" "$UNIT" "$STATE" "$STATE/pending" /var/backups/sing-box /run/lock/sing-box-install.lock; do safe_path "$path"; done
    [[ -f $BIN && -f $CONFIG && -f $UNIT ]] || die 'Existing installation required.'
    exec 9>/run/lock/sing-box-install.lock
    flock -n 9 || die 'Another installer/maintenance process is running.'
    [[ ! -e $STATE/pending ]] || die 'Interrupted maintenance: restore files from the recorded private backup before retrying; see docs/reality-upgrade.md.'
    [[ $(dpkg-query -W -f='${db:Status-Status}' sing-box 2>/dev/null || true) != installed ]] || die 'APT-managed installation is unsupported.'
    grep -Fxq -- "$MARKER" "$UNIT" || die 'Foreign systemd unit.'
    [[ $(systemctl show sing-box -p FragmentPath --value) == "$UNIT" &&
       -z $(systemctl show sing-box -p DropInPaths --value) &&
       $(systemctl show sing-box -p User --value) == sing-box &&
       $(systemctl show sing-box -p Group --value) == sing-box ]] || die 'Unexpected effective service layout.'
    systemctl is-enabled --quiet sing-box || die 'Service must be enabled.'
    artifact_for_arch "$(dpkg --print-architecture)"
    matches_artifact "$BIN" "$OLD_SIZE" "$OLD_SHA" || matches_artifact "$BIN" "$BINARY_SIZE" "$BINARY_SHA" || die 'Unknown executable; version strings are insufficient.'
    [[ $(stat -c '%U:%G:%a' "$CONFIG") == root:sing-box:640 ]] || die 'Unexpected configuration permissions.'
    [[ $(timedatectl show -p NTPSynchronized --value) == yes ]] || die 'Existing time service is not synchronized.'
    validate_config "$CONFIG"
    healthy || die 'Start from a healthy service before maintenance.'
    WORK=$(mktemp -d /run/sing-box-maintain.XXXXXXXX)
    chown root:sing-box "$WORK"; chmod 0750 "$WORK"
}

backup() {
    install -d -m 0700 /var/backups/sing-box "$STATE"
    BACKUP=$(mktemp -d /var/backups/sing-box/maintain.XXXXXXXX)
    install -m 0600 "$CONFIG" "$BACKUP/config.json"
    install -m 0700 "$BIN" "$BACKUP/sing-box"
    install -m 0600 "$UNIT" "$BACKUP/sing-box.service"
    sha256sum "$BACKUP/config.json" "$BACKUP/sing-box" "$BACKUP/sing-box.service" > "$BACKUP/SHA256SUMS"
    sync -f "$BACKUP"
    printf '%s\n' "$BACKUP" > "$STATE/pending"
    sync -f "$STATE"
    # 先置标志再发布；任何之后的非零退出均进入有限的文件恢复。
    CHANGED=1
}
cleanup() {
    local code=$?
    trap - EXIT INT TERM HUP
    if (( code != 0 && CHANGED )); then
        # 独立子 shell 保持 errexit，避免失败恢复继续执行或被误报为成功。
        if /usr/bin/bash -Eeuo pipefail -c '
          source "$1"
          BIN=$2 CONFIG=$3 BACKUP=$4
          sha256sum -c "$BACKUP/SHA256SUMS" >/dev/null
          cmp -s "$BACKUP/sing-box.service" "$UNIT"
          replace_file "$BACKUP/sing-box" "$BIN" 0755 root
          replace_file "$BACKUP/config.json" "$CONFIG" 0640 sing-box
          timeout 30 systemctl restart sing-box
          healthy
        ' _ "${BASH_SOURCE[0]}" "$BIN" "$CONFIG" "$BACKUP" > "$BACKUP/restore.log" 2>&1; then
            rm "$STATE/pending"; sync -f "$STATE"
            printf 'Previous files restored; local service verification passed. Operation failed.\n' >&2
        else
            printf 'RESTORE FAILED; retained pending record and private backup. Use SSH/console recovery.\n' >&2
        fi
    fi
    [[ -z $WORK ]] || rm -rf -- "$WORK"
    [[ -z $BACKUP ]] || printf 'Private backup/logs: %s\n' "$BACKUP"
    exit "$code"
}
check_candidate() {
    chown root:sing-box "$WORK/candidate.json"; chmod 0640 "$WORK/candidate.json"
    runuser -u sing-box -- "$1" check -c "$WORK/candidate.json" > "$WORK/check.log" 2>&1 || die 'Candidate check failed; live files unchanged.'
}
commit_change() {
    timeout 30 systemctl restart sing-box > "$BACKUP/restart.log" 2>&1
    healthy || die 'Service validation failed; restoring previous files.'
    rm "$STATE/pending"; sync -f "$STATE"
    CHANGED=0
    say 'PASS local service checks; validate proxy HTTPS separately before accepting deployment.'
}
upgrade() {
    if matches_artifact "$BIN" "$BINARY_SIZE" "$BINARY_SHA"; then say 'Already 1.14.2; configuration and healthy PID unchanged.'; return; fi
    curl --fail --silent --show-error --location --max-redirs 3 --proto '=https' --proto-redir '=https' \
      --connect-timeout 15 --max-time 180 --max-filesize "$ARCHIVE_SIZE" --output "$WORK/package.deb" "$ARCHIVE_URL"
    matches_artifact "$WORK/package.deb" "$ARCHIVE_SIZE" "$ARCHIVE_SHA" || die 'Official package size/checksum mismatch.'
    dpkg-deb --fsys-tarfile "$WORK/package.deb" | tar -xOf - ./usr/bin/sing-box > "$WORK/candidate"
    matches_artifact "$WORK/candidate" "$BINARY_SIZE" "$BINARY_SHA" || die 'Executable size/checksum mismatch.'
    chmod 0755 "$WORK/candidate"
    cp "$CONFIG" "$WORK/candidate.json"
    check_candidate "$WORK/candidate"
    backup
    install -m 0600 "$WORK/check.log" "$BACKUP/check.log"
    replace_file "$WORK/candidate" "$BIN" 0755 root
    commit_change
}
render_reality() {
    jq --rawfile uuid "$WORK/uuid" --rawfile private "$WORK/private-key" --rawfile sid "$WORK/short-id" \
      --arg host "$HANDSHAKE" --arg name "$SERVER_NAME" --argjson port "$HANDSHAKE_PORT" '
      .inbounds += [{type:"vless",tag:"reality-in",listen:"0.0.0.0",listen_port:8443,
        users:[{name:"owner",uuid:($uuid|rtrimstr("\n")),flow:"xtls-rprx-vision"}],
        tls:{enabled:true,server_name:$name,reality:{enabled:true,
          handshake:{server:$host,server_port:$port},private_key:($private|rtrimstr("\n")),
          short_id:[($sid|rtrimstr("\n"))],max_time_difference:"1m"}}}] |
      .route.rules=[{inbound:["reality-in"],network:"udp",action:"reject"}]
    ' "$CONFIG" > "$WORK/candidate.json"
}
enable_reality() {
    matches_artifact "$BIN" "$BINARY_SIZE" "$BINARY_SHA" || die 'Upgrade to 1.14.2 in a separate call first.'
    if [[ $(jq '.inbounds|length' "$CONFIG") == 2 ]]; then
        jq -e --arg host "$HANDSHAKE" --arg name "$SERVER_NAME" --argjson port "$HANDSHAKE_PORT" '
          .inbounds[1].tls | .server_name==$name and .reality.handshake=={server:$host,server_port:$port}' \
          "$CONFIG" >/dev/null || die 'Existing REALITY target differs; no credential rotation or target migration in this entry.'
        say 'REALITY already configured; original credentials and healthy PID unchanged.'; return
    fi
    [[ -z $(ss -H -ltnp 'sport = :8443') ]] || die 'TCP 8443 occupied, including loopback/IPv6 listeners.'
    "$BIN" generate uuid > "$WORK/uuid"
    "$BIN" generate reality-keypair > "$WORK/keypair"
    sed -n 's/^PrivateKey: //p' "$WORK/keypair" > "$WORK/private-key"
    sed -n 's/^PublicKey: //p' "$WORK/keypair" > "$WORK/public-key"
    openssl rand -hex 8 > "$WORK/short-id"
    render_reality
    validate_config "$WORK/candidate.json"
    check_candidate "$BIN"
    backup
    install -m 0600 "$WORK/keypair" "$BACKUP/reality-keypair.private"
    install -m 0600 "$WORK/check.log" "$BACKUP/check.log"
    replace_file "$WORK/candidate.json" "$CONFIG" 0640 sing-box
    commit_change
    say 'REALITY TCP 8443 configured. Public key is in the private backup; no credentials printed.'
}
main() {
    local action=${1:-} option
    case "$action" in
        --help|-h) usage; return ;;
        upgrade) [[ $# == 1 ]] || die 'upgrade takes no options.' ;;
        reality)
            shift
            local port_seen=0
            while (( $# )); do
                option=$1; shift
                [[ $# -gt 0 ]] || die 'Missing option value.'
                case "$option" in
                    --handshake-server) [[ -z $HANDSHAKE ]] || die 'Duplicate handshake server.'; HANDSHAKE=$1 ;;
                    --server-name) [[ -z $SERVER_NAME ]] || die 'Duplicate server name.'; SERVER_NAME=$1 ;;
                    --handshake-port) (( port_seen==0 )) || die 'Duplicate handshake port.'; port_seen=1; HANDSHAKE_PORT=$1 ;;
                    *) die 'Unknown option.' ;;
                esac
                shift
            done
            if ! valid_host "$HANDSHAKE" || ! valid_host "$SERVER_NAME" || ! valid_port "$HANDSHAKE_PORT"; then die 'Valid handshake host, TLS server name and port required.'; fi ;;
        *) die 'Use --help.' ;;
    esac
    trap cleanup EXIT
    trap 'printf "ERROR [%s]: command failed (exit %s).\n" "$STEP" "$?" >&2' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    STEP=preflight; preflight
    STEP=$action
    if [[ $action == upgrade ]]; then upgrade; else enable_reality; fi
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
