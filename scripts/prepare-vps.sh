#!/usr/bin/bash
# Ubuntu 24.04 / sing-box 1.14.0. Upload this file; run it as root.
set +x
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C LANG=C
unset BASH_ENV ENV CDPATH
umask 077

VERSION=1.14.0
BIN=/usr/local/bin/sing-box
CONFIG=/etc/sing-box/config.json
UNIT=/etc/systemd/system/sing-box.service
SWAP=/var/lib/sing-box/swapfile
MARKER='# Managed by prepare-vps.sh (simple-v1)'
WORK='' BACKUP='' STEP=preflight
SERVICE_CHANGED=0

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

matches_artifact() {
    [[ -f $1 && ! -L $1 && $(stat -c %s -- "$1") == "$2" ]] &&
        [[ $(sha256sum -- "$1" | cut -d ' ' -f 1) == "$3" ]]
}

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

render_config() {
    jq -n --rawfile key "$1" '{
      log: {level:"info"},
      inbounds: [{type:"shadowsocks",tag:"ss-in",listen:"0.0.0.0",listen_port:443,
        network:"tcp",method:"2022-blake3-aes-128-gcm",password:($key|rtrimstr("\n")),
        multiplex:{enabled:true}}],
      outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}
    }' > "$2"
}

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

preflight() {
    [[ $EUID == 0 ]] || die 'Run as root.'
    [[ $(sed -n 's/^ID=//p' /etc/os-release | tr -d '"') == ubuntu &&
       $(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"') == 24.04 ]] || die 'Ubuntu 24.04 is required.'
    [[ $(cat /proc/1/comm) == systemd ]] || die 'A systemd VPS/VM is required.'
    if systemd-detect-virt --container --quiet; then die 'Containers are unsupported.'; fi
    artifact_for_arch "$(dpkg --print-architecture)"
    safe_path /run/lock/sing-box-install.lock
    exec 9>/run/lock/sing-box-install.lock
    flock -n 9 || die 'Another installer is running.'
    for path in "$BIN" "$CONFIG" "$UNIT" /var/lib/sing-box /etc/fstab \
        /etc/systemd/journald.conf.d/60-sing-box-limits.conf; do safe_path "$path"; done
    local journal=/etc/systemd/journald.conf.d/60-sing-box-limits.conf
    if [[ -e $journal ]]; then
        grep -Fxq -- "$MARKER" "$journal" || die 'Foreign journald policy at the managed path.'
    fi
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
    listeners=$(ss -H -ltnp 'sport = :443')
    if [[ -n $listeners ]]; then
        [[ -e $UNIT ]] || die 'TCP 443 is occupied.'
        pid=$(systemctl show sing-box.service -p MainPID --value)
        [[ $pid =~ ^[1-9][0-9]*$ && $(readlink -f "/proc/$pid/exe") == "$BIN" ]] || die 'TCP 443 owner is unverified.'
        while IFS= read -r line; do
            [[ $line == *"pid=$pid,"* ]] || die 'A foreign process is listening on TCP 443.'
        done <<< "$listeners"
    fi
    [[ $(timedatectl show -p NTPSynchronized --value) == yes ]] || die 'System time is not synchronized; fix the existing time service first.'
    local available
    available=$(df -B1 --output=avail /var/lib | tail -n 1)
    (( available >= 3 * 1024 * 1024 * 1024 )) || die 'At least 3 GiB free disk space is required.'
}

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
    swapon "$SWAP"
    cp /etc/fstab "$WORK/fstab"
    printf '\n%s none swap sw 0 0\n' "$SWAP" >> "$WORK/fstab"
    publish_file "$WORK/fstab" /etc/fstab 0644 root
    systemctl daemon-reload
    say 'Created and activated 1 GiB swap.'
}

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

configure_service() {
    prepare_key
    render_config "$WORK/key" "$WORK/config.json"
    chown root:sing-box "$WORK" "$WORK/config.json"
    chmod 0750 "$WORK"; chmod 0640 "$WORK/config.json"
    # Check diagnostics may contain config values; keep them in the private work directory.
    runuser -u sing-box -- "$BIN" check -c "$WORK/config.json" > "$WORK/config-check.log" 2>&1 ||
        die 'sing-box rejected the candidate configuration; the live configuration was not replaced.'
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
    if systemctl is-active --quiet sing-box.service; then
        if (( SERVICE_CHANGED )); then systemctl restart sing-box.service; fi
    else
        systemctl reset-failed sing-box.service
        systemctl start sing-box.service
    fi
}

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

main() {
    local upgrade=0
    case "${1:-}" in
        --help|-h) usage; return 0 ;;
        --upgrade-system) [[ $# == 1 ]] || die 'Unexpected arguments.'; upgrade=1 ;;
        '') [[ $# == 0 ]] || die 'Unexpected arguments.' ;;
        *) die 'Use --help for usage.' ;;
    esac
    trap 'printf "ERROR [%s]: command failed (exit %s). Earlier completed steps remain; inspect before retrying.\n" "$STEP" "$?" >&2' ERR
    trap '[[ -z $WORK ]] || rm -rf -- "$WORK"' EXIT
    preflight
    WORK=$(mktemp -d /var/tmp/sing-box-install.XXXXXXXX)
    STEP=apt
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
    apt-get -o DPkg::Lock::Timeout=120 update
    apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends ca-certificates curl jq openssl util-linux iproute2
    STEP=account; ensure_account
    STEP=swap; ensure_swap
    if (( upgrade )); then
        STEP=apt-upgrade
        apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold -y upgrade
    fi
    STEP=binary; install_binary
    STEP=configuration; configure_service
    STEP=verification; verify_service
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
