#!/usr/bin/bash
# Ubuntu 24.04 / sing-box 1.14.0. Upload this file; run it as root.
# 服务端入口：只上传本文件，以 root 执行，无需 Python、模板或构建产物。
# 主流程见文件末尾 main：预检 → APT 依赖 → 账号/swap → 可选升级 → 二进制 → 配置 → 验证。
# 本脚本会修改系统；它没有 --check/--plan，也不提供跨步骤事务或自动回滚。
# SSH、防火墙规则和机器重启由操作者管理；公网 TCP 443 放行是外部前提。
# 排错时根据 ERROR 中的阶段检查已完成步骤与私有备份，不要把含密钥的配置贴到日志。

# 关闭命令展开跟踪，避免敏感内容进入终端；严格模式使未处理失败和未定义变量中止执行。
# pipefail 同时检查管道上游，例如 dpkg-deb 失败不能被 tar 的结果掩盖。
set +x
set -Eeuo pipefail
# 固定工具搜索路径与输出语言，减少 root 环境中的同名命令和本地化输出干扰。
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C LANG=C
unset BASH_ENV ENV CDPATH
# 新文件默认只允许 root 访问；确需服务账号读取的文件随后显式放宽权限。
umask 077

# 固定版本与部署路径。MARKER 只标识本脚本维护的文件，不是密码或完整状态数据库。
VERSION=1.14.0
BIN=/usr/local/bin/sing-box
CONFIG=/etc/sing-box/config.json
UNIT=/etc/systemd/system/sing-box.service
SWAP=/var/lib/sing-box/swapfile
MARKER='# Managed by prepare-vps.sh (simple-v1)'
WORK='' BACKUP='' STEP=preflight
# publish_file 写入不同内容时置 1；用于决定是否重启已运行的 sing-box。
# 该标志是本次执行的内存状态，不会跨执行保存。
SERVICE_CHANGED=0

# 普通输出不含密钥。die 报告当前阶段后退出；不尝试撤销前面的系统修改。
say() { printf '%s\n' "$*"; }
die() { printf 'ERROR [%s]: %s\n' "$STEP" "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: sudo bash prepare-vps.sh [--upgrade-system]
Install sing-box 1.14.0 (IPv4 TCP 443, SS2022), optional 1 GiB swap,
private configuration and an enabled systemd service on Ubuntu 24.04.
APT indexes/dependencies are refreshed on every run. --upgrade-system also
runs apt-get upgrade, preserving existing config files. No automatic reboot.
SSH and firewall rules are preserved. No keys are printed.
EOF
}

# 按 dpkg 架构选择已核验的官方包与内层可执行文件的大小、摘要。
# 两层都校验：下载物正确，且真正发布到 /usr/local/bin 的内容也正确。
# 升级版本必须同时审查并更新这些常量；不得把它改成调用者提供的任意摘要。
artifact_for_arch() {
    case "$1" in
        amd64)
            ARCHIVE_SIZE=32258946
            ARCHIVE_SHA=84035ea7eb85570830af77801e8e949d3769dd23bbcacce08df3bfde1945f299
            BINARY_SIZE=91842368
            BINARY_SHA=ce3ed8667dd99ff40c85a8b236075e856ea9cb80731b304cedd2a47187828120 ;;
        arm64)
            ARCHIVE_SIZE=29525840
            ARCHIVE_SHA=80378caee6f5fdc0557f9aad0c3ade9341a4a4a66e3755c9f0d228c3d697f6e7
            BINARY_SIZE=85908600
            BINARY_SHA=5f4d9ef9436b36a6cb9db8831833264c11fe4cab1622cec465c0acfd3abfffac ;;
        *) die 'Supported architectures: amd64, arm64.' ;;
    esac
    ARCHIVE_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box_${VERSION}_linux_${1}.deb"
}

# 检查绝对路径的每一级已有组件：拒绝符号链接、非 root 所有者及不安全写权限。
# root 所有的 sticky 目录允许作为临时目录祖先；最终文件还必须为单硬链接普通文件。
# 尚不存在的组件留给后续创建步骤；这是一组前置检查，不是通用文件事务机制。
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

# 仅在确实需要替换已有文件时，懒创建本次运行的 root-only 备份目录。
# 固定文件集合的绝对路径转成扁平文件名；备份统一 0600，包含配置时仍保护原密钥。
# 备份供人工恢复，不表示 APT、账号、swap 等此前修改也能自动恢复。
backup_file() {
    [[ -e $1 ]] || return 0
    if [[ -z $BACKUP ]]; then
        safe_path /var/backups/sing-box
        install -d -m 0700 /var/backups/sing-box
        BACKUP=$(mktemp -d /var/backups/sing-box/run.XXXXXXXX)
    fi
    # Flat names are unique for the small, fixed set of managed files.
    cp --preserve=mode,ownership,timestamps -- "$1" "$BACKUP/${1//\//_}"
    chmod 0600 "$BACKUP/${1//\//_}"
}

# 参数：已准备好的源文件、绝对目标路径、目标权限、目标组。
# 内容相同只收敛 owner/mode，不置 SERVICE_CHANGED，避免健康服务无故重启。
# 内容不同时先备份，再在目标目录创建候选；同目录 rename 原子切换单个文件。
# sync -f 先同步候选内容、再同步目标目录；多个文件之间仍不是一个原子事务。
publish_file() {
    local source=$1 destination=$2 mode=$3 group=$4 candidate
    safe_path "$destination"
    if [[ -f $destination ]] && cmp -s -- "$source" "$destination"; then
        chown "root:$group" "$destination"
        chmod "$mode" "$destination"
        return 0
    fi
    backup_file "$destination"
    candidate=$(mktemp "${destination}.new.XXXXXXXX")
    install -m "$mode" -o root -g "$group" -- "$source" "$candidate"
    sync -f "$candidate"
    mv -fT -- "$candidate" "$destination"
    sync -f "${destination%/*}"
    SERVICE_CHANGED=1
}

# 用 jq 从私有文件读取密钥，不把密钥正文放到 jq 参数或环境变量中。
# 渲染固定服务端配置：IPv4 TCP 443、SS2022 AES-128、direct 出站、服务端接受 MUX。
# 重跑会保留密钥，但其他自定义配置会收敛为这个模板；替换前由 publish_file 备份。
render_config() {
    jq -n --rawfile key "$1" '{
      log: {level:"info"},
      inbounds: [{type:"shadowsocks",tag:"ss-in",listen:"0.0.0.0",listen_port:443,
        network:"tcp",method:"2022-blake3-aes-128-gcm",password:($key|rtrimstr("\n")),
        multiplex:{enabled:true}}],
      outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}
    }' > "$2"
}

# 首次执行才生成随机 16 字节密钥。已有配置先验证算法、单一 inbound 和密钥格式。
# 解码后核对字节数，再重新编码比较，拒绝非规范 base64；绝不把非法旧密钥静默换新。
# key/key.raw/key.canonical 都在本次私有工作目录中，不向终端输出。
prepare_key() {
    if [[ -f $CONFIG ]]; then
        jq -er '.inbounds | select(length==1) | .[0] |
          select(.type=="shadowsocks" and .method=="2022-blake3-aes-128-gcm") |
          .password | select(type=="string" and test("^[A-Za-z0-9+/]{22}==$"))' \
          "$CONFIG" > "$WORK/key" 2>/dev/null || die 'Existing key/config is invalid; inspect it privately.'
        base64 -d "$WORK/key" > "$WORK/key.raw" 2>/dev/null || die 'Existing key is invalid.'
        [[ $(stat -c %s "$WORK/key.raw") == 16 ]] || die 'Existing key must be 16 bytes.'
        base64 "$WORK/key.raw" > "$WORK/key.canonical"
        cmp -s "$WORK/key" "$WORK/key.canonical" || die 'Existing key is not canonical base64.'
    else
        openssl rand -base64 16 > "$WORK/key"
    fi
}

# 在 APT 或配置修改之前验证平台与已有资源，发现冲突尽早停止。
# 此阶段仍会创建/打开 /run 中的安装锁，因此不能将它宣传为完整的只读预检接口。
preflight() {
    [[ $EUID == 0 ]] || die 'Run as root.'
    [[ $(sed -n 's/^ID=//p' /etc/os-release | tr -d '"') == ubuntu &&
       $(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"') == 24.04 ]] || die 'Ubuntu 24.04 is required.'
    [[ $(cat /proc/1/comm) == systemd ]] || die 'A systemd VPS/VM is required.'
    if systemd-detect-virt --container --quiet; then die 'Containers are unsupported.'; fi
    artifact_for_arch "$(dpkg --print-architecture)"
    # FD 9 在本次脚本运行期间持有排他锁；-n 不等待，避免并发安装交错写入。
    safe_path /run/lock/sing-box-install.lock
    exec 9>/run/lock/sing-box-install.lock
    flock -n 9 || die 'Another installer is running.'
    for path in "$BIN" "$CONFIG" "$UNIT" /var/lib/sing-box /etc/fstab \
        /etc/systemd/journald.conf.d/60-sing-box-limits.conf; do safe_path "$path"; done
    local journal=/etc/systemd/journald.conf.d/60-sing-box-limits.conf
    if [[ -e $journal ]]; then
        grep -Fxq -- "$MARKER" "$journal" || die 'Foreign journald policy at the managed path.'
    fi
    # 不自动接管旧控制器、APT 管理的 sing-box 或没有本脚本标记的 systemd unit。
    # 已有二进制即使版本字符串相同，也必须匹配固定的大小和摘要。
    [[ ! -e /var/lib/prepare-vps ]] || die 'Old controller state exists; this is not an in-place migration.'
    [[ $(dpkg-query -W -f='${db:Status-Status}' sing-box 2>/dev/null || true) != installed ]] ||
        die 'An APT sing-box installation already exists; inspect it before migrating.'
    if [[ -e $UNIT ]]; then
        grep -Fxq -- "$MARKER" "$UNIT" || die 'Existing service is not managed by this script.'
    else
        [[ ! -e $CONFIG ]] || die 'Existing sing-box configuration is not managed by this script.'
        [[ $(systemctl show sing-box.service -p LoadState --value) == not-found ]] || die 'Another sing-box unit exists.'
    fi
    if [[ -e $BIN ]]; then matches_artifact "$BIN" "$BINARY_SIZE" "$BINARY_SHA" || die 'Existing binary differs from the pinned version.'; fi
    local listeners pid
    # 保留全部 TCP 443 监听，包括 127.0.0.1 和 IPv6；它们也可能阻止通配地址绑定。
    # 只有已标记 unit 的 MainPID、可执行路径和每条监听归属都吻合时，才允许重跑。
    listeners=$(ss -H -ltnp 'sport = :443')
    if [[ -n $listeners ]]; then
        [[ -e $UNIT ]] || die 'TCP 443 is occupied.'
        pid=$(systemctl show sing-box.service -p MainPID --value)
        [[ $pid =~ ^[1-9][0-9]*$ && $(readlink -f "/proc/$pid/exe") == "$BIN" ]] || die 'TCP 443 owner is unverified.'
        while IFS= read -r line; do
            [[ $line == *"pid=$pid,"* ]] || die 'A foreign process is listening on TCP 443.'
        done <<< "$listeners"
    fi
    # 只询问现有时间服务是否同步，不安装/重启时间服务，也不主动设置系统时钟。
    # 该布尔检查不代表精密时间采样或 SS2022 的公网验证。
    [[ $(timedatectl show -p NTPSynchronized --value) == yes ]] || die 'System time is not synchronized; fix the existing time service first.'
    local available
    available=$(df -B1 --output=avail /var/lib | tail -n 1)
    (( available >= 3 * 1024 * 1024 * 1024 )) || die 'At least 3 GiB free disk space is required.'
}

# sing-box 用专用系统账号运行：锁定密码、nologin、无补充组、固定 home。
# 复用账号必须满足这些属性；目录由 root 管理，服务账号只获得读取配置所需权限。
ensure_account() {
    if ! getent passwd sing-box >/dev/null; then
        getent group sing-box >/dev/null && die 'An unrelated sing-box group exists.'
        useradd --system --user-group --home-dir /var/lib/sing-box --no-create-home --shell /usr/sbin/nologin sing-box
    fi
    local _ uid gid account_home shell
    IFS=: read -r _ _ uid gid _ account_home shell < <(getent passwd sing-box)
    [[ $uid -gt 0 && $uid -lt 1000 && $account_home == /var/lib/sing-box && $shell == /usr/sbin/nologin &&
       $(id -gn sing-box) == sing-box && $(id -G sing-box) == "$gid" ]] || die 'Existing service account has unexpected privileges.'
    [[ $(passwd -S sing-box | awk '{print $2}') == L ]] || die 'Service account password must be locked.'
    install -d -o root -g sing-box -m 0750 /etc/sing-box
    install -d -o root -g root -m 0755 /var/lib/sing-box
}

# 已有活动 swap 或 fstab 中已有 swap 条目时直接保留，不修改大小、优先级或路径。
# 仅在内存不超过 2 GiB 且文件系统/空间满足条件时创建本项目的 1 GiB swapfile。
# 中断后留下的未启用 swapfile 会被拒绝，需人工检查，避免覆盖不明文件。
ensure_swap() {
    if [[ $(wc -l < /proc/swaps) -gt 1 ]] || awk '!/^[[:space:]]*#/ && $3=="swap" {found=1} END {exit !found}' /etc/fstab; then
        say 'Existing active/configured swap preserved.'; return
    fi
    local memory filesystem available
    memory=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    (( memory <= 2 * 1024 * 1024 )) || return 0
    filesystem=$(findmnt -n -o FSTYPE --target /var/lib/sing-box)
    case "$filesystem" in ext4|xfs) ;; *) say "Swap skipped: unsupported filesystem $filesystem."; return ;; esac
    safe_path "$SWAP"
    [[ ! -e $SWAP ]] || die 'An inactive swapfile exists; inspect it before retrying.'
    available=$(df -B1 --output=avail /var/lib/sing-box | tail -n 1)
    (( available >= 5 * 1024 * 1024 * 1024 )) || die 'Creating swap requires 5 GiB free space.'
    # noclobber prevents replacement; real writes avoid sparse/CoW fallocate surprises.
    (set -o noclobber; : > "$SWAP")
    chmod 0600 "$SWAP"
    timeout 180 dd if=/dev/zero of="$SWAP" bs=1M count=1024 conv=fsync status=none
    mkswap --quiet "$SWAP"
    # 先实际启用，再备份并发布 fstab 条目。若后一步失败，活动 swap 可能已经保留；
    # 重试会优先识别活动 swap，操作者仍应检查持久化条目是否完整。
    swapon "$SWAP"
    cp /etc/fstab "$WORK/fstab"
    printf '\n%s none swap sw 0 0\n' "$SWAP" >> "$WORK/fstab"
    publish_file "$WORK/fstab" /etc/fstab 0644 root
    systemctl daemon-reload
    say 'Created and activated 1 GiB swap.'
}

# 已有二进制在 preflight 中核验过，重跑无需再次下载。
# .deb 仅作为可信的归档使用：不执行 dpkg -i，不触发包脚本，也不安装附带权限文件。
install_binary() {
    if [[ -f $BIN ]]; then return; fi
    curl --fail --silent --show-error --location --max-redirs 3 --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 180 --max-filesize "$ARCHIVE_SIZE" \
        --output "$WORK/sing-box.deb" "$ARCHIVE_URL"
    matches_artifact "$WORK/sing-box.deb" "$ARCHIVE_SIZE" "$ARCHIVE_SHA" || die 'Official package checksum/size mismatch.'
    # Only this member is read. No package scripts, accounts, Polkit or D-Bus files are installed.
    dpkg-deb --fsys-tarfile "$WORK/sing-box.deb" | tar -xOf - ./usr/bin/sing-box > "$WORK/sing-box"
    matches_artifact "$WORK/sing-box" "$BINARY_SIZE" "$BINARY_SHA" || die 'Executable checksum/size mismatch.'
    publish_file "$WORK/sing-box" "$BIN" 0755 root
}

# 先在 live 配置路径之外生成候选，以实际服务账号执行目标二进制的 check。
# 配置检查通过后才发布 unit/config；check 不等于 systemd 沙箱中的运行验证。
configure_service() {
    prepare_key
    render_config "$WORK/key" "$WORK/config.json"
    # 服务账号需要遍历工作目录并读取候选配置；原始 key 文件仍保持 root-only。
    chown root:sing-box "$WORK" "$WORK/config.json"
    chmod 0750 "$WORK"; chmod 0640 "$WORK/config.json"
    # Check diagnostics may contain config values; keep them in the private work directory.
    runuser -u sing-box -- "$BIN" check -c "$WORK/config.json" > "$WORK/config-check.log" 2>&1 ||
        die 'sing-box rejected the candidate configuration; the live configuration was not replaced.'
    # unit 使用最小低端口 capability、只读系统目录和私有临时目录。
    # AF_NETLINK 是 sing-box 订阅路由变化所需；遗漏它会出现 check 通过但启动失败。
    # 自动重启仅针对 sing-box 进程失败，不会重启 VPS。
    {
        say "$MARKER"
        cat <<'EOF'
[Unit]
Description=Sing-box SS2022 proxy
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=sing-box
Group=sing-box
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
# Linux route/interface monitoring uses NETLINK_ROUTE, including in proxy-only mode.
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
UMask=0077
LimitNOFILE=65536
LogRateLimitIntervalSec=30s
LogRateLimitBurst=1000

[Install]
WantedBy=multi-user.target
EOF
    } > "$WORK/sing-box.service"
    publish_file "$WORK/sing-box.service" "$UNIT" 0644 root
    publish_file "$WORK/config.json" "$CONFIG" 0640 sing-box
    # 这是全机 journald 配额，不是只限制 sing-box；仅内容变化时重启 journald。
    install -d -m 0755 /etc/systemd/journald.conf.d
    printf '%s\n[Journal]\nSystemMaxUse=128M\nRuntimeMaxUse=32M\n' "$MARKER" > "$WORK/journal.conf"
    local journal=/etc/systemd/journald.conf.d/60-sing-box-limits.conf
    if [[ ! -f $journal ]] || ! cmp -s "$WORK/journal.conf" "$journal"; then
        [[ ! -f $journal ]] || grep -Fxq -- "$MARKER" "$journal" || die 'Foreign journald policy at the managed path.'
        publish_file "$WORK/journal.conf" "$journal" 0644 root
        systemctl restart systemd-journald.service
    fi
    systemctl daemon-reload
    systemctl enable sing-box.service >/dev/null
    # 内容不变且服务健康时保留原 PID；未运行则清除启动限流失败状态后启动。
    if systemctl is-active --quiet sing-box.service; then
        if (( SERVICE_CHANGED )); then systemctl restart sing-box.service; fi
    else
        systemctl reset-failed sing-box.service
        systemctl start sing-box.service
    fi
}

# systemctl start 成功只说明启动请求被接受，因此继续观察 5 秒的状态和 MainPID。
# 随后确认实际二进制、TCP 443 归属和没有该进程的 UDP 443 监听。
# 此函数只验证 VPS 本机服务；公网放行、密钥认证和 HTTPS 需要独立客户端实测。
verify_service() {
    local pid listeners _
    pid=$(systemctl show sing-box.service -p MainPID --value)
    [[ $pid =~ ^[1-9][0-9]*$ ]] || die 'Service has no running main process.'
    for _ in 1 2 3 4 5; do
        sleep 1
        systemctl is-active --quiet sing-box.service || die 'Service stopped during verification.'
        [[ $(systemctl show sing-box.service -p MainPID --value) == "$pid" ]] || die 'Service restarted during verification.'
    done
    [[ $(readlink -f "/proc/$pid/exe") == "$BIN" ]] || die 'Unexpected service executable.'
    listeners=$(ss -H -ltnp 'sport = :443')
    [[ -n $listeners ]] || die 'TCP 443 is not listening.'
    while IFS= read -r line; do
        [[ $line == *'0.0.0.0:443'* && $line == *"pid=$pid,"* ]] || die 'Unexpected TCP 443 listener.'
    done <<< "$listeners"
    listeners=$(ss -H -lunp 'sport = :443')
    [[ $listeners != *"pid=$pid,"* ]] || die 'The service unexpectedly opened UDP 443.'
    say "Installed: sing-box $VERSION, SS2022, IPv4 TCP 443. Local service check passed."
    say "Private configuration: $CONFIG (key not printed)."
    say 'Status: systemctl --no-pager status sing-box; logs: journalctl --no-pager -u sing-box -n 50'
    say 'Confirm host/provider TCP 443 access and test from the Mac; this was not an end-to-end test.'
    [[ -z $BACKUP ]] || say "Previous files: $BACKUP"
    if [[ -e /run/reboot-required ]]; then say 'System requests a reboot. Schedule it manually; sing-box is enabled at boot.'; fi
}

# 唯一执行入口。只有 --upgrade-system 会额外升级现有系统软件；默认也会更新 APT
# 索引并安装所需依赖。--help 与非法参数在平台检查/安装之前返回。
main() {
    local upgrade=0
    case "${1:-}" in
        --help|-h) usage; return 0 ;;
        --upgrade-system) [[ $# == 1 ]] || die 'Unexpected arguments.'; upgrade=1 ;;
        '') [[ $# == 0 ]] || die 'Unexpected arguments.' ;;
        *) die 'Use --help for usage.' ;;
    esac
    # 不把失败命令全文打印出来，避免暴露敏感参数；退出只清理本次临时目录。
    # 已发布文件、包、账号和 swap 不在这个清理范围内，失败后应先检查再重试。
    trap 'printf "ERROR [%s]: command failed (exit %s). Earlier completed steps remain; inspect before retrying.\n" "$STEP" "$?" >&2' ERR
    trap '[[ -z $WORK ]] || rm -rf -- "$WORK"' EXIT
    preflight
    WORK=$(mktemp -d /var/tmp/sing-box-install.XXXXXXXX)
    STEP=apt
    # 使用非交互 APT；needrestart 仅列出需要重启的服务，脚本不替操作者重启机器。
    # 锁超时限制等待时间，不删除锁文件，也不终止正在运行的包管理器。
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
    apt-get -o DPkg::Lock::Timeout=120 update
    apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends ca-certificates curl jq openssl util-linux iproute2
    STEP=account; ensure_account
    STEP=swap; ensure_swap
    if (( upgrade )); then
        # 依赖和条件 swap 已先准备好；升级采用 dpkg 默认决定，必要时保留旧配置。
        STEP=apt-upgrade
        apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold -y upgrade
    fi
    STEP=binary; install_binary
    STEP=configuration; configure_service
    STEP=verification; verify_service
}

# 测试可以 source 本文件调用纯函数；只有直接执行文件才进入安装流程。
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
