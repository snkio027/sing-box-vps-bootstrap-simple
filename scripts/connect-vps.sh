#!/opt/homebrew/bin/bash
# macOS Apple Silicon; one terminal-owned SOCKS5 client, no system networking changes.
# Mac 入口：setup 私密导入配置，run 保持前台客户端，check 只验证一次并退出。
# 只启动自己的 127.0.0.1:17890 SOCKS5，不设置系统代理/TUN/DNS/路由/launchd。
# 默认 en4 可在 setup 时显式选择；VPS 地址必须是数字 IPv4，避免本地代理的假 IP DNS。
# 客户端配置含真实密钥，只留在本机私有目录，不要提交或粘贴到公开日志。

# 禁止命令跟踪和自动导出变量；严格模式让未处理失败尽快退出到统一清理流程。
set +x
set +a
set -Eeuo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C LANG=C
unset BASH_ENV ENV CDPATH
# 临时配置、日志、备份默认只允许当前用户访问。
umask 077

# 仅记录本次临时目录、直接子进程和锁是否由本次取得；不会按进程名清理其他代理。
WORK='' CHILD='' LOCKED=0

# 错误仅说明失败原因和私有日志位置，不打印配置正文或密钥。
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

# 使用 macOS/BSD stat：文件大小，以及 uid、八进制权限、硬链接数。
# Linux 单元测试只替换这两个平台适配函数，不改变 JSON/密钥处理逻辑。
file_size() { stat -f '%z' "$1"; }
file_info() { stat -f '%u %Lp %l' "$1"; }
# 点分路径同时支持对象键和数组下标，例如 inbounds.0.password。
# 路径作为 jq 数据参数传入，不拼接为 jq 程序；仅允许返回字符串或数字。
# 调用方必须重定向/捕获密钥字段，不能直接把这个函数的输出写到终端。
json_get() {
    local file=$1
    [[ $file == /* ]] || file="$PWD/$file"
    jq -er --arg path "$2" 'getpath($path|split(".")|map(tonumber? // .)) |
      select(type=="string" or type=="number")' "$file"
}

# 只接收当前用户的私有普通文件，拒绝链接及任何组/其他用户权限。
# 显式拒绝受保护的连接文件名；本函数只检查元数据，不解析文件正文。
private_file() {
    local owner mode links
    case "${1##*/}" in secret|vps-conn.sh) die 'Protected connection files must not be used.' ;; esac
    [[ -f $1 && ! -L $1 ]] || die 'Expected a private regular file, not a symlink.'
    read -r owner mode links < <(file_info "$1")
    if [[ $owner != "$EUID" || $links != 1 ]] || (( (8#$mode & 0077) != 0 )); then
        die 'File must belong to you with mode 600 (or stricter) and no hardlinks.'
    fi
}

# 先校验四段十进制与范围，再排除常见本地、组播、CGNAT 和 fake-IP 网段。
# 拒绝前导零消除不同工具的八进制解释；这里只做输入过滤，不证明公网可达性。
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

# 限定 enN 名称，排除 lo0/utunN；实际存在且连接活跃由 check_interface 再检查。
# 名称格式与配置中的 bind_interface 不能代替真实链路的出接口观测。
valid_interface() { [[ $1 =~ ^en[0-9]+$ ]]; }

# 参数：私有源配置、密钥字段路径、VPS IPv4、网卡名、候选输出文件。
# setup 从服务端 inbound 取密钥，run/check 从保存的 outbound 取同一密钥。
# 总是重建固定配置，不继承源文件里的 TUN、路由或额外 direct 出站。
render_client() {
    local source=$1 key_path=$2 server=$3 interface=$4 output=$5 key canonical prefix
    # 同名变量可能从调用环境带有 export 属性；取消它，避免密钥进入子进程环境。
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
    # 16 字节 SS2022 密钥的标准 base64 是 24 个字符；还要验证解码长度和重编码。
    # 密钥通过管道标准输入传给 OpenSSL，临时二进制文件受私有目录和 umask 保护。
    [[ $key =~ ^[A-Za-z0-9+/]{22}==$ ]] || die 'Invalid SS2022 key format.'
    printf '%s' "$key" | openssl base64 -d -A > "$WORK/key.raw"
    [[ $(file_size "$WORK/key.raw") == 16 ]] || die 'SS2022 key must decode to 16 bytes.'
    canonical=$(openssl base64 -A -in "$WORK/key.raw")
    [[ $key == "$canonical" ]] || die 'SS2022 key must be canonical base64.'
    # 一个 SOCKS5 入站、一个 SS2022 出站；MUX 关闭，无直连回退，出站明确绑定网卡。
    # 回环 SOCKS5 不额外认证，同一 Mac 上可访问此端口的进程可以使用它。
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

# 运行脚本只核验依赖，不调用 brew install/upgrade；准备命令由操作者显式执行。
# 要求 Apple Silicon、非 root、实际运行的 Homebrew Bash 5.3+，以及 stable 工具。
# PATH 改动只影响本次脚本及子进程，不修改终端配置或系统 PATH。
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
    # “未过期”依据本机 Homebrew 元数据；应先执行帮助中的 brew update 刷新它。
    # 此处故意禁用隐式更新，不声称启动时实时查询了上游的最新版本。
    [[ -z $outdated ]] || die 'Dependencies are outdated; run the update commands shown by --help.'
    BIN=/opt/homebrew/opt/sing-box/bin/sing-box
    versions=$(HOMEBREW_NO_AUTO_UPDATE=1 "$brew" list --versions bash curl jq openssl sing-box)
    [[ $versions != *HEAD* ]] || die 'Install stable Homebrew formulas; HEAD builds are unsupported.'
    say "$versions"
}

# EXIT 时先停止并回收本次直接子进程，再删除临时文件，最后释放自己的锁目录。
# 不使用 pkill/killall，不接触已经运行的系统代理或其他 sing-box。
# SIGKILL 无法触发 shell trap；异常强杀后可能遗留状态，应按文档人工检查。
cleanup() {
    if [[ -n $CHILD ]]; then
        kill "$CHILD" 2>/dev/null || true
        wait "$CHILD" 2>/dev/null || true
    fi
    [[ -z $WORK ]] || rm -rf -- "$WORK"
    if (( LOCKED )); then rmdir "$STATE/running.lock" 2>/dev/null || true; fi
}

# 持久目录只容纳本项目客户端配置、前一份配置和日志；临时文件在其私有子目录中。
# 用 mkdir 的原子成功/失败取得实例锁，setup 与 run/check 也不能交错写同一份配置。
# 只在成功取得锁后设置 LOCKED，失败路径不会删除其他运行实例的锁。
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

# 查询既有接口的活跃状态，不启用网卡、不改地址或路由；不可用时停止。
check_interface() {
    ifconfig "$1" 2>/dev/null | grep -q 'status: active' || die 'Selected interface is missing or inactive.'
}

# 使用实际选定客户端校验候选配置；诊断可能引用配置内容，故只写私有日志。
# 这一步不启动 SOCKS5，不替代随后的 listener 和 HTTPS 验证。
check_config() {
    "$BIN" check -c "$WORK/client.json" > "$LOG" 2>&1 || die "Configuration rejected; inspect privately: $LOG"
}

# 同时限定本次 PID、IPv4 回环地址、端口和 LISTEN 状态，避免把其他代理当作本次客户端。
owns_listener() {
    [[ $(lsof -nP -a -p "$CHILD" -iTCP@127.0.0.1:17890 -sTCP:LISTEN -t 2>/dev/null) == "$CHILD" ]]
}

# curl 的 -q 必须在首位以忽略 .curlrc；显式指定 SOCKS5 并清空 no_proxy 绕过列表。
# socks5h 将目标域名交给 SOCKS5 端解析；连接 VPS 自身使用已验证的数字地址。
# 保留正常 TLS 验证，不跟随重定向，并限制连接时间、总时间和响应体大小。
# 结果同时要求 HTTP 200、固定标记和 ip 字段；只输出通过结论，不打印公网地址。
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

# 参数在任何依赖查询或状态目录修改之前校验；帮助可独立查看。
# 流程：校验参数 → 依赖 → 私有目录/锁 → setup 或临时客户端 → HTTPS → 清理。
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
    # Ctrl+C、终止和终端挂断都经 EXIT 清理；返回常见的 128+signal 退出码。
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    require_dependencies
    prepare_state
    if [[ $command == setup ]]; then
        # 私密配置应已通过核验主机身份的 SSH/SFTP 下载；本脚本本身不负责 SSH 登录。
        server=$2 interface=${4:-en4}
        render_client "$3" inbounds.0.password "$server" "$interface" "$WORK/client.json"
        [[ $(json_get "$3" inbounds.0.listen_port 2>/dev/null) == 443 ]] || die 'Source VPS configuration must use port 443.'
        check_interface "$interface"
        check_config
        # 只有新配置检查成功才保留旧配置并替换；临时目录与目标目录在同一文件系统。
        # 仅保留上一份客户端配置，不构建历史事务或自动恢复引擎。
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
    # 不抢占、不终止端口占用者；已有任何 TCP 17890 listener 时直接停止。
    if lsof -nP -iTCP:17890 -sTCP:LISTEN -t >/dev/null 2>&1; then die 'Local TCP port 17890 is occupied.'; fi
    check_config
    "$BIN" run -c "$WORK/client.json" > "$LOG" 2>&1 &
    CHILD=$!
    # 最多约 5 秒等待本次子进程真正建立 listener；进程退出或超时都进入清理。
    for _ in {1..50}; do
        kill -0 "$CHILD" 2>/dev/null || die "Client exited; inspect privately: $LOG"
        if owns_listener; then break; fi
        sleep 0.1
    done
    owns_listener || die "Client did not open its SOCKS5 listener; inspect privately: $LOG"
    probe_https
    # check 成功即返回，EXIT 停止临时代理；run 则继续等待，由当前终端持有生命周期。
    if [[ $command == check ]]; then return; fi
    say 'SOCKS5 ready: 127.0.0.1:17890. Keep this terminal open; Ctrl+C stops this client.'
    say 'Use in another terminal: /opt/homebrew/opt/curl/bin/curl --noproxy "" --proxy socks5h://127.0.0.1:17890 https://example.com'
    if wait "$CHILD"; then code=0; else code=$?; fi
    CHILD=''
    die "Client exited (status $code); inspect privately: $LOG"
}

# 测试 source 本文件时只加载函数，不读取真实配置，也不启动客户端。
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
