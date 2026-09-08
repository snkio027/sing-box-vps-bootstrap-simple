#!/usr/bin/bash
# Ubuntu 24.04 单机加固：prepare 只准备管理员；新 SSH 会话再单独调用 apply。
# 不安装代理、不迁移 SSH 端口、不重启机器。普通备份用于人工恢复，不是通用事务引擎。
set +x
set +a
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C LANG=C
unset BASH_ENV ENV CDPATH NEEDRESTART_MODE NEEDRESTART_SUSPEND
umask 077

STATE=/var/lib/sing-box-hardening
SSH_POLICY=/etc/ssh/sshd_config.d/00-sing-box-hardening.conf
APT_POLICY=/etc/apt/apt.conf.d/99-sing-box-hardening
RESTART_POLICY=/etc/needrestart/conf.d/99-sing-box-hardening.conf
MARKER='# Managed by harden-vps.sh (simple-v1)'
WORK='' BACKUP='' GUARD_ID='' ADMIN='' SSH_PORT='' PUBLIC_KEY='' CONSOLE=0
STEP=arguments
say() { printf '%s\n' "$*"; }
die() { printf 'ERROR [%s]: %s\n' "$STEP" "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: sudo bash harden-vps.sh prepare --admin NAME --public-key /path/key.pub --ssh-port PORT
Then open a NEW key-authenticated SSH session as NAME, verify sudo, retain the old
session and a working provider console. From that new session run:
  sudo --preserve-env=SSH_CONNECTION bash harden-vps.sh apply --admin NAME --ssh-port PORT --confirm-console
prepare and apply are separate calls. Existing SSH port is verified, not changed.
apply grants full NOPASSWD administrator elevation, disables root/password/keyboard
SSH login, enables dual-stack UFW and daily security updates. Necessary service
restarts and brief interruptions are allowed; automatic machine reboot is forbidden.
This is not a proxy installer. No private key or password input is accepted.
EOF
}

valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 && 10#$1 != 443 )); }
valid_admin() { [[ $1 =~ ^[a-z][a-z0-9_-]{0,30}$ && $1 != root && $1 != sing-box ]]; }

# root 目标路径逐级检查；账号目录另外按目标 UID 检查，不信任普通用户可写的输入路径。
safe_root_path() {
    local path=$1 walk='' part mode
    local -a parts
    [[ $path == /* && $path != *'/../'* && $path != *'/./'* ]] || die 'Unsafe absolute path.'
    IFS=/ read -r -a parts <<< "$path"
    for part in "${parts[@]:1}"; do
        walk+="/$part"
        [[ ! -L $walk ]] || die 'Symlink at a managed path.'
        if [[ -e $walk ]]; then
            [[ $(stat -c %u "$walk") == 0 ]] || die 'Managed ancestor must be root-owned.'
            mode=$(stat -c %a "$walk")
            (( (8#$mode & 0022) == 0 )) || die 'Managed ancestor is writable by other users.'
        fi
    done
    if [[ -e $path && ! -d $path ]]; then
        [[ -f $path && $(stat -c %h "$path") == 1 ]] || die 'Expected single-link regular file.'
    fi
}

cleanup() {
    local code=$?
    # 包安装失败/中断时，子进程可能尚未结束；保留保护文件供操作者核对包锁后清理。
    # 正常成功路径在 install_dependencies 内按身份和内容删除，已有文件从不接管。
    if [[ -n $GUARD_ID ]]; then
        printf 'Service-start guard retained; inspect the recorded identity and package locks before cleanup.\n' >&2
    fi
    [[ -z $WORK ]] || rm -rf -- "$WORK"
    if (( code != 0 )) && [[ -n $BACKUP ]]; then
        printf 'Incomplete; retained private backup: %s\nKeep SSH/console access; inspect recovery instructions.\n' "$BACKUP" >&2
    fi
}

# 输入快照只含一条 Ed25519 公钥，去除注释；禁止 authorized_keys 选项和多密钥输入。
read_public_key() {
    local kind data _
    case "${PUBLIC_KEY##*/}" in secret|vps-conn.sh) die 'Protected input refused.' ;; esac
    safe_root_path "$PUBLIC_KEY"
    [[ -f $PUBLIC_KEY && $(stat -c %s "$PUBLIC_KEY") -le 4096 ]] || die 'Invalid public key file.'
    [[ $(awk 'NF {n++} END {print n+0}' "$PUBLIC_KEY") == 1 ]] || die 'Exactly one public key is required.'
    read -r kind data _ < "$PUBLIC_KEY" || [[ -n ${kind:-} ]]
    [[ $kind == ssh-ed25519 && $data =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || die 'Expected plain Ed25519 public key.'
    printf '%s %s\n' "$kind" "$data" > "$WORK/key.pub"
    ssh-keygen -lf "$WORK/key.pub" -E sha256 > "$WORK/key-check" 2>&1 || die 'Invalid Ed25519 public key.'
    grep -Eq '^256 SHA256:[^ ]+ .*\(ED25519\)$' "$WORK/key-check" || die 'Unexpected public key type.'
}

# ss 的实际 TCP listener 与 sshd -T 必须一致。ssh.socket 活跃时还核对 systemd 的 Listen。
# 这些检查先于包安装和防火墙修改；支持 service/socket 两种现有监听方式，拒绝多端口。
check_listener_text() {
    local expected=$1 socket_active=$2 endpoint processes port found=0 owner _
    while read -r _ _ _ endpoint _ processes; do
        [[ -n $endpoint ]] || continue
        port=${endpoint##*:}
        if [[ $processes == *'"sshd"'* ]]; then
            [[ $port == "$expected" ]] || return 1
        fi
        if [[ $port == "$expected" ]]; then
            if [[ $processes != *'"sshd"'* ]]; then
                [[ $socket_active == yes && $processes == *'"systemd",pid=1,'* ]] || return 1
            fi
            while read -r owner; do
                [[ $owner == '"sshd",pid='* || ( $socket_active == yes && $owner == '"systemd",pid=1' ) ]] || return 1
            done < <(grep -oE '"[^"]+",pid=[0-9]+' <<< "$processes")
            found=1
        fi
    done
    (( found == 1 ))
}

check_ssh_port() {
    local ports socket_active=no listens endpoint rest found=0
    /usr/sbin/sshd -t > "$WORK/sshd-check.log" 2>&1 || die 'Existing sshd configuration is invalid.'
    /usr/sbin/sshd -T > "$WORK/sshd-effective"
    ports=$(awk '$1=="port" {print $2}' "$WORK/sshd-effective" | sort -u)
    [[ $ports == "$SSH_PORT" ]] || die 'Input SSH port differs from effective sshd configuration.'
    if systemctl is-active --quiet ssh.socket; then
        socket_active=yes
        listens=$(systemctl show ssh.socket -p Listen --value)
        while read -r endpoint rest; do
            [[ -n $endpoint && $rest == '(Stream)' && ${endpoint##*:} == "$SSH_PORT" ]] || die 'ssh.socket Listen differs from the input port.'
            found=1
        done <<< "$listens"
        (( found )) || die 'ssh.socket has no verified stream listener.'
    fi
    ss -H -ltnp > "$WORK/listeners"
    check_listener_text "$SSH_PORT" "$socket_active" < "$WORK/listeners" || die 'Actual SSH listener/owner differs from the input port.'
    say "PASS existing SSH port and actual listener ($socket_active socket activation)."
}

preflight() {
    [[ $EUID == 0 ]] || die 'Run with sudo/root.'
    [[ $(sed -n 's/^ID=//p' /etc/os-release | tr -d '"') == ubuntu &&
       $(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"') == 24.04 ]] || die 'Ubuntu 24.04 required.'
    case $(dpkg --print-architecture) in amd64|arm64) ;; *) die 'Unsupported architecture.' ;; esac
    [[ $(cat /proc/1/comm) == systemd ]] || die 'systemd required.'
    if systemd-detect-virt --container --quiet; then die 'Containers are unsupported.'; fi
    for command in ssh-keygen ss sudo visudo; do command -v "$command" >/dev/null || die "Required command missing: $command"; done
    safe_root_path /run/sing-box-hardening.lock
    exec 9>/run/sing-box-hardening.lock
    flock -n 9 || die 'Another hardening process is running.'
    # /run is root-controlled; avoid allowing sticky/shared parents for root candidates.
    WORK=$(mktemp -d /run/sing-box-hardening.XXXXXXXX)
    check_ssh_port
    safe_root_path "$STATE"
    if [[ -e $STATE ]]; then
        [[ $(stat -c %a "$STATE") == 700 ]] || die 'Unexpected state permissions.'
        for name in admin ssh-port key.pub; do safe_root_path "$STATE/$name"; done
        [[ $(cat "$STATE/admin") == "$ADMIN" && $(cat "$STATE/ssh-port") == "$SSH_PORT" ]] || die 'Existing preparation belongs to another administrator/port.'
    fi
}

# 兼容性只针对目标账号，不拒绝系统上无关的预置普通账号。
check_account() {
    local name uid home shell groups _ mode
    IFS=: read -r name _ uid _ _ home shell < <(getent passwd "$ADMIN")
    [[ $uid -ge 1000 && $home == /home/"$ADMIN" && $shell == /bin/bash && $(id -gn "$ADMIN") == "$ADMIN" ]] || die 'Target administrator is incompatible.'
    [[ $(passwd -S "$ADMIN" | awk '{print $2}') == L ]] || die 'Target administrator password must be locked.'
    groups=$(id -nG "$ADMIN" | tr ' ' '\n' | grep -Fvx -e "$ADMIN" -e sudo || true)
    [[ -z $groups ]] || die 'Target administrator has unexpected supplementary groups.'
    [[ -d $home && ! -L $home && $(stat -c %u "$home") == "$uid" ]] || die 'Unsafe administrator home.'
    mode=$(stat -c %a "$home"); (( (8#$mode & 0022) == 0 )) || die 'Administrator home is writable by others.'
    for name in "$home/.ssh" "$home/.ssh/authorized_keys"; do
        [[ ! -L $name ]] || die 'Symlink in administrator SSH paths.'
        if [[ -e $name ]]; then
            [[ $(stat -c %u "$name") == "$uid" ]] || die 'Wrong SSH path owner.'
            mode=$(stat -c %a "$name"); (( (8#$mode & 0077) == 0 )) || die 'SSH paths must be private.'
        fi
    done
    if [[ -e $home/.ssh/authorized_keys ]]; then
        [[ -f $home/.ssh/authorized_keys && $(stat -c %h "$home/.ssh/authorized_keys") == 1 ]] || die 'Invalid authorized_keys type.'
        cmp -s "$WORK/key.pub" "$home/.ssh/authorized_keys" || die 'Target administrator has a different authorized key.'
    fi
}

prepare_admin() {
    read_public_key
    if [[ -d $STATE ]]; then cmp -s "$WORK/key.pub" "$STATE/key.pub" || die 'Prepared public key differs.'; fi
    safe_root_path /home
    safe_root_path "/etc/sudoers.d/90-sing-box-$ADMIN"
    printf '%s\n%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$MARKER" "$ADMIN" > "$WORK/sudoers"
    visudo -cf "$WORK/sudoers" > "$WORK/visudo.log" 2>&1 || die 'Invalid sudoers candidate.'
    if [[ -e /etc/sudoers.d/90-sing-box-$ADMIN ]]; then
        cmp -s "$WORK/sudoers" "/etc/sudoers.d/90-sing-box-$ADMIN" || die 'Conflicting target sudoers file.'
    fi
    if getent passwd "$ADMIN" >/dev/null; then
        check_account
        # 没有准备记录时，已有账号必须已经持有完全相同的公钥，才认为兼容。
        [[ -d $STATE || -f /home/$ADMIN/.ssh/authorized_keys ]] || die 'Existing target account has no compatible key.'
    else
        [[ ! -e /home/$ADMIN && ! -L /home/$ADMIN ]] || die 'An unknown target home exists.'
        ! getent group "$ADMIN" >/dev/null || die 'An unrelated target group exists.'
    fi
    # 简单归属记录先于账号创建，便于明确识别中断后哪些资源属于本次准备。
    if [[ ! -d $STATE ]]; then
        install -d -m 0700 "$STATE"
        printf '%s\n' "$ADMIN" > "$STATE/admin"
        printf '%s\n' "$SSH_PORT" > "$STATE/ssh-port"
        install -m 0600 "$WORK/key.pub" "$STATE/key.pub"
        sync -f "$STATE"
    fi
    if ! getent passwd "$ADMIN" >/dev/null; then useradd --create-home --user-group --shell /bin/bash "$ADMIN"; fi
    check_account
    usermod -aG sudo "$ADMIN"
    # 用户可写的 home 内以该用户身份新建文件；不让 root 跟随用户可竞态替换的目录项。
    if [[ ! -f /home/$ADMIN/.ssh/authorized_keys ]]; then
        # HOME 在 runuser 的目标用户 shell 中展开。
        # shellcheck disable=SC2016
        runuser -u "$ADMIN" -- /bin/sh -c 'umask 077; mkdir -p "$HOME/.ssh"; set -C; cat > "$HOME/.ssh/authorized_keys"' < "$WORK/key.pub"
    fi
    check_account
    install -o root -g root -m 0440 "$WORK/sudoers" "/etc/sudoers.d/90-sing-box-$ADMIN"
    visudo -c > "$WORK/visudo-all.log" 2>&1 || die 'Installed sudo configuration is invalid.'
    printf 'prepared\n' > "$STATE/prepared"
    sync -f "$STATE"
    say 'PREPARED: full NOPASSWD administrator; SSH policy/firewall unchanged.'
    say 'STOP here. Keep old session/console; open a NEW key SSH session, verify sudo, then call apply separately.'
}

require_admin_session() {
    [[ -f $STATE/prepared ]] || die 'Run prepare first, in a separate invocation.'
    [[ ${SUDO_USER:-} == "$ADMIN" && ${SUDO_UID:-} == "$(id -u "$ADMIN")" ]] || die 'apply must run through sudo as the prepared administrator.'
    local peer peerport localip localport extra
    read -r peer peerport localip localport extra <<< "${SSH_CONNECTION:-}"
    [[ -z $extra && $peer =~ ^[0-9a-fA-F:.]+$ && $localip =~ ^[0-9a-fA-F:.]+$ &&
       $peerport =~ ^[1-9][0-9]{0,4}$ && $localport == "$SSH_PORT" ]] || die 'Preserve SSH_CONNECTION from the new administrator SSH session.'
    (( peerport <= 65535 )) || die 'Invalid SSH peer port.'
    SSH_CONTEXT="host=$peer,addr=$peer,laddr=$localip,lport=$localport"
    # 完整管理员可伪造环境；本检查防误调用，不伪装成不可伪造的外部登录证明。
    cp "$STATE/key.pub" "$WORK/key.pub"
    check_account
    [[ -f /home/$ADMIN/.ssh/authorized_keys ]] || die 'Administrator key is missing.'
    sudo -u "$ADMIN" sudo -n true || die 'Administrator sudo verification failed.'
}

make_backup() {
    safe_root_path /var/backups/sing-box-hardening
    install -d -m 0700 /var/backups/sing-box-hardening
    BACKUP=$(mktemp -d /var/backups/sing-box-hardening/run.XXXXXXXX)
    printf '%s\n' "$BACKUP" > "$STATE/last-backup"
    # 固定允许列表，不归档 host 私钥、shadow 或代理配置。
    local path
    for path in "$SSH_POLICY" "$APT_POLICY" "$RESTART_POLICY" /etc/default/ufw \
        /etc/ufw/ufw.conf /etc/ufw/user.rules /etc/ufw/user6.rules; do
        safe_root_path "$path"
        if [[ -f $path ]]; then cp --preserve=mode,ownership "$path" "$BACKUP/${path//\//_}"; else printf '%s\n' "$path" >> "$BACKUP/absent-before"; fi
    done
    printf 'Keep old SSH session and console. See docs/hardening.md for exact-file recovery.\n' > "$BACKUP/README"
    sync -f "$BACKUP"
}

install_dependencies() {
    if ! dpkg-query -W -f='${db:Status-Status}\n' jq nftables ufw unattended-upgrades needrestart 2>/dev/null | grep -qv '^installed$'; then
        if command -v jq >/dev/null && command -v nft >/dev/null && command -v ufw >/dev/null && command -v unattended-upgrade >/dev/null && command -v needrestart >/dev/null; then return; fi
    fi
    safe_root_path /usr/sbin/policy-rc.d
    [[ ! -e /usr/sbin/policy-rc.d ]] || die 'Existing policy-rc.d requires operator inspection.'
    printf '#!/bin/sh\n%s\nexit 101\n' "$MARKER" > "$BACKUP/policy-rc.d.created"
    (set -o noclobber; cat "$BACKUP/policy-rc.d.created" > /usr/sbin/policy-rc.d)
    GUARD_ID=$(stat -c '%d:%i' /usr/sbin/policy-rc.d)
    printf '%s\n' "$GUARD_ID" > "$BACKUP/policy-rc.d.identity"
    chmod 0755 /usr/sbin/policy-rc.d
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l timeout 300 apt-get -o DPkg::Lock::Timeout=120 update > "$BACKUP/dependency-update.log" 2>&1
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l timeout 600 apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends jq nftables ufw unattended-upgrades needrestart > "$BACKUP/dependency-install.log" 2>&1
    if [[ $(stat -c '%d:%i' /usr/sbin/policy-rc.d) != "$GUARD_ID" ]] || ! cmp -s /usr/sbin/policy-rc.d "$BACKUP/policy-rc.d.created"; then die 'Service guard changed externally.'; fi
    rm /usr/sbin/policy-rc.d; GUARD_ID=''
}

# 全量 nft JSON；去掉 handle、计数器等易变观测，保留全部规则/集合/链与顺序。
nft_snapshot() {
    nft -j list ruleset | jq -S 'del(.nftables[] | select(has("metainfo"))) |
      walk(if type=="object" then del(.handle) |
        if has("counter") and (.counter|type)=="object" then .counter |= del(.packets,.bytes) else . end
      else . end)'
}
clean_nft() {
    jq -e 'all(.nftables[];
      if has("metainfo") then true
      elif has("table") then (.table | (.family=="ip" or .family=="ip6") and .name=="filter")
      elif has("chain") then (.chain | (.family=="ip" or .family=="ip6") and .table=="filter" and
        .type=="filter" and .prio==0 and .policy=="accept" and
        ((.name=="INPUT" and .hook=="input") or (.name=="OUTPUT" and .hook=="output") or (.name=="FORWARD" and .hook=="forward")))
      else false end)' > /dev/null
}
clean_legacy() {
    awk '/^#/ || NF==0 || /^COMMIT$/ || /^\*filter$/ || /^:(INPUT|OUTPUT|FORWARD) ACCEPT \[[0-9]+:[0-9]+\]$/ {next} {bad=1} END {exit bad}'
}
ufw_files() {
    printf '%s\n' /etc/default/ufw /etc/ufw/ufw.conf /etc/ufw/before.rules /etc/ufw/before6.rules \
        /etc/ufw/after.rules /etc/ufw/after6.rules /etc/ufw/user.rules /etc/ufw/user6.rules /etc/ufw/sysctl.conf \
        /etc/ufw/before.init /etc/ufw/after.init
}
check_stock_ufw_controls() {
    local name template expected
    safe_root_path /var/lib/dpkg/info/ufw.md5sums
    for name in before.rules before6.rules after.rules after6.rules user.rules user6.rules before.init after.init; do
        if [[ $name == *.rules ]]; then template=/usr/share/ufw/iptables/$name; else template=/usr/share/ufw/$name; fi
        safe_root_path "$template"
        expected=$(awk -v path="${template#/}" '$2==path {print $1}' /var/lib/dpkg/info/ufw.md5sums)
        [[ $expected =~ ^[0-9a-f]{32}$ && $(md5sum "$template" | cut -d ' ' -f 1) == "$expected" ]] || die 'UFW package template was modified.'
        cmp -s "$template" "/etc/ufw/$name" || die 'Unmanaged UFW control rules or init hook differs from its package template.'
    done
    [[ ! -x /etc/ufw/before.init && ! -x /etc/ufw/after.init ]] || die 'Unmanaged executable UFW hook exists.'
}
check_firewall() {
    ! systemctl is-active --quiet nftables.service || die 'Another nftables service is active.'
    ! systemctl is-enabled --quiet nftables.service || die 'Another nftables boot policy is enabled.'
    local path command
    while read -r path; do safe_root_path "$path"; done < <(ufw_files)
    for command in iptables-legacy-save ip6tables-legacy-save; do
        if command -v "$command" >/dev/null; then
            "$command" > "$WORK/legacy"
            clean_legacy < "$WORK/legacy" || die 'Unknown legacy firewall exists.'
        fi
    done
    if [[ -f $STATE/applied ]]; then
        sha256sum -c "$STATE/ufw-files.sha256" > "$WORK/ufw-check.log" 2>&1 || die 'Managed firewall files changed externally.'
        nft_snapshot > "$WORK/nft-current.json"
        cmp -s "$STATE/nft.json" "$WORK/nft-current.json" || die 'Managed kernel firewall changed externally.'
    else
        check_stock_ufw_controls
        nft -j list ruleset > "$BACKUP/nft-before.json"
        clean_nft < "$BACKUP/nft-before.json" || die 'Unknown native firewall; no rules changed.'
        ufw status | grep -Fxq 'Status: inactive' || die 'Unmanaged UFW is active.'
    fi
}

render_ssh_policy() {
    printf '%s\nPermitRootLogin no\nPubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nAuthenticationMethods publickey\n' "$MARKER"
}
check_effective_ssh() {
    local file=$1 user settings setting
    /usr/sbin/sshd -t -f "$file" > "$WORK/ssh-candidate-check.log" 2>&1 || die 'SSH candidate failed syntax check.'
    for user in "$ADMIN" root; do
        settings=$(/usr/sbin/sshd -T -f "$file" -C "user=$user,$SSH_CONTEXT")
        for setting in 'permitrootlogin no' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'pubkeyauthentication yes' 'authenticationmethods publickey'; do
            grep -Fxq "$setting" <<< "$settings" || die 'SSH policy cannot take effect in the current Include/Match context.'
        done
        if [[ $user == "$ADMIN" ]]; then
            ! grep -Eq '^(allowusers|denyusers|allowgroups|denygroups) ' <<< "$settings" || die 'Existing SSH user/group filters require manual review.'
            grep -Eq '^authorizedkeysfile .*\.ssh/authorized_keys( |$)' <<< "$settings" || die 'Unexpected authorized_keys lookup.'
            grep -Fxq 'forcecommand none' <<< "$settings" || die 'Existing ForceCommand is incompatible.'
        fi
    done
}
prepare_ssh_candidate() {
    safe_root_path /etc/ssh/sshd_config
    safe_root_path "$SSH_POLICY"
    render_ssh_policy > "$WORK/ssh-policy"
    if [[ -e $SSH_POLICY ]]; then cmp -s "$WORK/ssh-policy" "$SSH_POLICY" || die 'Conflicting hardening SSH file.'; fi
    # 保持真实主配置的顺序和 Match，只有标准 Include 目录换成候选快照目录。
    grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*\.conf[[:space:]]*$' /etc/ssh/sshd_config || die 'Expected standard Ubuntu SSH Include.'
    install -d -m 0700 "$WORK/sshd_config.d"
    local path
    for path in /etc/ssh/sshd_config.d/*.conf; do
        [[ -e $path || -L $path ]] || continue
        safe_root_path "$path"
        cp "$path" "$WORK/sshd_config.d/"
    done
    cp "$WORK/ssh-policy" "$WORK/sshd_config.d/${SSH_POLICY##*/}"
    sed "s|/etc/ssh/sshd_config.d/\\*.conf|$WORK/sshd_config.d/*.conf|g" /etc/ssh/sshd_config > "$WORK/sshd_config"
    check_effective_ssh "$WORK/sshd_config"
}

publish() {
    local source=$1 target=$2 mode=$3 candidate
    safe_root_path "$target"
    if [[ -f $target ]] && cmp -s "$source" "$target"; then return; fi
    candidate=$(mktemp "${target}.new.XXXXXXXX")
    install -m "$mode" -o root -g root "$source" "$candidate"
    sync -f "$candidate"; mv -fT "$candidate" "$target"; sync -f "${target%/*}"
}
configure_firewall() {
    if [[ -f $STATE/applied ]]; then return; fi
    # 先保留经过实际核对的 SSH 入口，再改变默认政策和启用 UFW。
    sed 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw > "$WORK/ufw-default"
    grep -Fxq 'IPV6=yes' "$WORK/ufw-default" || die 'Unexpected UFW IPv6 configuration.'
    publish "$WORK/ufw-default" /etc/default/ufw 0644
    {
        ufw allow "$SSH_PORT/tcp"
        ufw allow 443/tcp
        ufw default deny incoming
        ufw default deny routed
        ufw default allow outgoing
        ufw --force enable
    } > "$BACKUP/ufw-apply.log" 2>&1
    systemctl enable ufw.service > /dev/null
}
verify_firewall() {
    local command chain rules
    ufw status | grep -Fxq 'Status: active' || die 'UFW is not active.'
    grep -Fxq 'IPV6=yes' /etc/default/ufw || die 'UFW IPv6 disabled.'
    for command in iptables-save ip6tables-save; do
        if [[ $command == iptables-save ]]; then chain=ufw-user-input; else chain=ufw6-user-input; fi
        rules=$($command)
        if ! grep -Eq '^:INPUT DROP ' <<< "$rules" || ! grep -Eq '^:FORWARD DROP ' <<< "$rules" || ! grep -Eq '^:OUTPUT ACCEPT ' <<< "$rules"; then die 'Firewall default policies differ.'; fi
        [[ $(grep -c "^-A $chain " <<< "$rules") == 2 ]] || die 'Unexpected user firewall rules.'
        grep -Fxq -- "-A $chain -p tcp -m tcp --dport $SSH_PORT -j ACCEPT" <<< "$rules" || die 'SSH firewall rule missing.'
        grep -Fxq -- "-A $chain -p tcp -m tcp --dport 443 -j ACCEPT" <<< "$rules" || die 'Proxy firewall rule missing.'
    done
    systemctl is-enabled --quiet ufw.service || die 'UFW boot policy disabled.'
}

render_updates() {
    printf '%s\n' "$MARKER"
    cat <<'EOF'
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Allowed-Origins { "${distro_id}:${distro_codename}-security"; };
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF
}
verify_updates() {
    local key settings
    settings=$(apt-config dump)
    for key in 'APT::Periodic::Enable "1";' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Unattended-Upgrade "1";' \
        'Unattended-Upgrade::Automatic-Reboot "false";' 'Unattended-Upgrade::Automatic-Reboot-WithUsers "false";'; do
        grep -Fxq "$key" <<< "$settings" || die 'Effective APT policy differs.'
    done
    # APT 自己展开 distro 变量，这里比较它保存的字面量。
    # shellcheck disable=SC2016
    [[ $(grep '^Unattended-Upgrade::Allowed-Origins:: ' <<< "$settings") == 'Unattended-Upgrade::Allowed-Origins:: "${distro_id}:${distro_codename}-security";' ]] || die 'Unexpected unattended-upgrade origin.'
    ! grep -q '^Unattended-Upgrade::Origins-Pattern:: ' <<< "$settings" || die 'Unexpected unattended-upgrade origin pattern.'
    for key in apt-daily.timer apt-daily-upgrade.timer; do
        if ! systemctl is-enabled --quiet "$key" || ! systemctl is-active --quiet "$key"; then die 'Daily APT timer is not active/enabled.'; fi
    done
    cmp -s "$WORK/needrestart" "$RESTART_POLICY" || die 'Service restart policy changed.'
    # 按 needrestart 的 Perl 配置加载方式检查最终 restart 值，识别后续片段覆盖。
    # 仅解释现有 root 控制的配置，不运行进程扫描或服务重启。
    safe_root_path /etc/needrestart/needrestart.conf
    for key in /etc/needrestart/conf.d/*.conf; do [[ ! -e $key ]] || safe_root_path "$key"; done
    /usr/bin/perl > "$WORK/restart-effective.log" 2>&1 <<'PERL' || die 'Effective needrestart policy is not automatic.'
use strict;
my %nrconf = (verbosity => 0);
my $LOGPREF = '[hardening policy check]';
open my $fh, '<', '/etc/needrestart/needrestart.conf' or die $!;
my $config = do { local $/; <$fh> };
eval $config;
die $@ if $@;
die "restart must be a" unless ($nrconf{restart} // '') eq 'a';
print "restart=a\n";
PERL
}
configure_updates() {
    render_updates > "$WORK/apt-policy"
    render_restart_policy > "$WORK/needrestart"
    local path source
    for path in "$APT_POLICY" "$RESTART_POLICY"; do
        safe_root_path "$path"
        if [[ $path == "$APT_POLICY" ]]; then source="$WORK/apt-policy"; else source="$WORK/needrestart"; fi
        if [[ -e $path ]]; then cmp -s "$source" "$path" || die 'Conflicting update policy at managed path.'; fi
        publish "$source" "$path" 0644
    done
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer > /dev/null
    verify_updates
    # 后续每日更新也允许必要服务重启。此处不带 NEEDRESTART_MODE=l、不运行自动重启。
    timeout 300 apt-get -o DPkg::Lock::Timeout=120 update > "$BACKUP/security-refresh.log" 2>&1
    dpkg-query -W -f='${binary:Package} ${Version}\n' > "$BACKUP/packages-before"
    timeout 600 unattended-upgrade --dry-run --verbose > "$BACKUP/security-dry-run.log" 2>&1
    timeout 900 unattended-upgrade --verbose > "$BACKUP/security-run.log" 2>&1
    dpkg-query -W -f='${binary:Package} ${Version}\n' > "$BACKUP/packages-after"
    if cmp -s "$BACKUP/packages-before" "$BACKUP/packages-after"; then say 'Security updater executed successfully; no package version changed.';
    else say 'Security updater executed; package changes recorded privately.'; fi
    [[ ! -e /run/reboot-required ]] || say 'REBOOT_REQUIRED: arrange an explicit maintenance reboot; no reboot was requested.'
}

render_restart_policy() {
    printf '%s\n' "$MARKER"
    cat <<'EOF'
$nrconf{restart} = 'a';
EOF
}

apply_hardening() {
    require_admin_session
    [[ ! -e /usr/sbin/policy-rc.d && ! -L /usr/sbin/policy-rc.d ]] || die 'Existing service-start guard requires operator inspection before apply.'
    if [[ -f $STATE/applying && ! -f $STATE/applied ]]; then die 'Prior apply was interrupted; inspect last-backup and recover before retrying.'; fi
    if [[ -f $STATE/applied ]]; then sha256sum -c "$STATE/managed.sha256" > "$WORK/managed-check.log" 2>&1 || die 'Managed resources changed externally.'; fi
    prepare_ssh_candidate
    make_backup
    install_dependencies
    check_ssh_port
    check_firewall
    # 已有 APT/needrestart 同名片段必须兼容，不能在 SSH/UFW 之后才发现冲突。
    render_updates > "$WORK/apt-policy"
    render_restart_policy > "$WORK/needrestart"
    [[ ! -e $APT_POLICY ]] || cmp -s "$WORK/apt-policy" "$APT_POLICY" || die 'Conflicting APT policy.'
    [[ ! -e $RESTART_POLICY ]] || cmp -s "$WORK/needrestart" "$RESTART_POLICY" || die 'Conflicting restart policy.'
    printf 'applying\n' > "$STATE/applying"; sync -f "$STATE"
    STEP=firewall
    configure_firewall
    verify_firewall
    STEP=ssh
    local ssh_changed=0 path
    if [[ ! -f $SSH_POLICY ]] || ! cmp -s "$WORK/ssh-policy" "$SSH_POLICY"; then ssh_changed=1; fi
    publish "$WORK/ssh-policy" "$SSH_POLICY" 0644
    # 安装后再次验证实际 Include，而不是仅信任离线候选。
    check_effective_ssh /etc/ssh/sshd_config
    if (( ssh_changed )); then systemctl reload ssh.service; fi
    check_ssh_port
    STEP=security-updates
    configure_updates
    STEP=verification
    check_effective_ssh /etc/ssh/sshd_config
    check_ssh_port
    verify_firewall
    verify_updates
    [[ ! -e /usr/sbin/policy-rc.d ]] || die 'An unexpected service-start guard remains.'
    while read -r path; do sha256sum "$path"; done < <(ufw_files) > "$STATE/ufw-files.sha256"
    nft_snapshot > "$STATE/nft.json"
    sha256sum "$SSH_POLICY" "$APT_POLICY" "$RESTART_POLICY" "/etc/sudoers.d/90-sing-box-$ADMIN" "/home/$ADMIN/.ssh/authorized_keys" > "$STATE/managed.sha256"
    printf 'applied\n' > "$STATE/applied"; sync -f "$STATE"
    rm "$STATE/applying"
    say 'APPLIED: local SSH/UFW/update checks passed. Full administrator NOPASSWD sudo remains enabled.'
    say 'Keep old session until another NEW key SSH connection and proxy HTTPS have passed.'
}

main() {
    local action=${1:-} option
    if [[ $action == --help || $action == -h ]]; then usage; return; fi
    [[ $action == prepare || $action == apply ]] || die 'Use prepare or apply; see --help.'
    shift
    while (( $# )); do
        option=$1; shift
        case "$option" in
            --admin) [[ -z $ADMIN && $# -gt 0 ]] || die 'Duplicate/missing admin.'; ADMIN=$1; shift ;;
            --ssh-port) [[ -z $SSH_PORT && $# -gt 0 ]] || die 'Duplicate/missing port.'; SSH_PORT=$1; shift ;;
            --public-key) [[ -z $PUBLIC_KEY && $# -gt 0 && $action == prepare ]] || die 'Unexpected public key option.'; PUBLIC_KEY=$1; shift ;;
            --confirm-console) [[ $action == apply && $CONSOLE == 0 ]] || die 'Unexpected console confirmation.'; CONSOLE=1 ;;
            *) die 'Unexpected argument; see --help.' ;;
        esac
    done
    valid_admin "$ADMIN" || die 'Invalid administrator name.'
    valid_port "$SSH_PORT" || die 'Invalid SSH port (443 is reserved for the proxy).'
    if [[ $action == prepare ]]; then [[ -n $PUBLIC_KEY ]] || die 'Public key file required.';
    else (( CONSOLE == 1 )) || die 'Confirm the provider console is accessible before apply.'; fi
    trap cleanup EXIT
    trap 'printf "ERROR [%s]: command failed (exit %s); inspect private backup logs.\n" "$STEP" "$?" >&2' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
    STEP=preflight; preflight
    STEP=$action
    if [[ $action == prepare ]]; then prepare_admin; else apply_hardening; fi
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
