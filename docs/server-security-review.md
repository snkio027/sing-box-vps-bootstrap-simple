# 服务器安全基线核查与单协议试验准备

2026-09-08。源码核查后，经操作者授权完成真实 VPS 只读核查，未修改生产配置。
初次核查发现的三项问题已经实施加固，并通过一次受控重启恢复验收，见 [当前加固结果](server-hardening.md)；下文保留原始发现。现有 SS2022 / Mac TUN 继续作为已验收基线。

源码范围：本地 HEAD `12963a7bb3dc243ec43ce4047ca72f06b0a9ff73` 的安装器；
`scripts/prepare-vps.sh` SHA-256 为
`0dff75e5a441e246f04dd9957b5a0720029dbfadf4ab3a3e8311017f2476bb3b`。
同时阅读 [执行约束](../AGENTS.md)、[README](../README.md)、
[安全说明](../SECURITY.md)、[部署流程](deployment-flow.md) 与相关测试。
本轮没有修改安装器，未重新运行 VM 安装测试。

## 源码已确认的措施

| 项目 | 安装器实现 | 现场仍需确认 |
| --- | --- | --- |
| 软件来源 | 固定官方 1.14.0 包与内层程序大小/SHA-256，只提取程序，不运行包脚本 | 当前程序版本、摘要与架构 |
| 服务身份 | 专用 sing-box 系统账号，密码锁定、nologin、无补充组 | 实际 UID、组、账号状态与当前进程 |
| 服务权限 | NoNewPrivileges；仅 CAP_NET_BIND_SERVICE；ProtectSystem=strict、ProtectHome、PrivateTmp、PrivateDevices；限制地址族 | systemd 的实际生效属性，包括 drop-in |
| 配置与备份 | /etc/sing-box 为 root:sing-box 0750，配置 0640；备份目录 0700、备份文件 0600 | 文件与父目录的实际 owner/mode，是否存在额外不安全副本 |
| 监听 | 单个 IPv4 TCP 443 SS2022 inbound，未配置公网 SOCKS/API | 全部 TCP/UDP 监听及所有者；IPv6 也要核对 |
| 日志 | 单元日志速率限制；全机 journal 磁盘 128 MiB、运行时 32 MiB 上限 | 生效的 journald 配置与实际占用；不是单服务独享配额 |

源码证据见 [安装器](../scripts/prepare-vps.sh)。实现这些措施不等于当前真实主机全部符合。

## 当前没有由安装器落实的三项

1. **SSH 管理身份和认证策略**：安装器不创建 SSH 管理员，也不关闭 root / 密码登录。以实际生效配置和新会话验证为准，不能根据注释或主配置文件单独判断。
2. **主机及服务商防火墙**：安装器保留原规则。UFW inactive 不代表没有 nftables/iptables 策略；主机规则也不能证明服务商控制面的状态。
3. **自动安全更新**：安装器刷新 APT，可选执行一次 upgrade，但没有配置或验证 unattended-upgrades、定时任务及最近一次结果。sing-box 为手工安装程序，不随 APT 升级。

Ubuntu 文档说明配置片段可能优先生效；SSH 修改前必须做语法检查并保留可用入口。
后续若需要加固，先建立密钥管理员、验证新登录和提权、确认控制台恢复方式，再安排关闭旧认证。
[OpenSSH 文档](https://ubuntu.com/server/docs/how-to/security/openssh-server/)

自动更新应同时检查安装包、有效配置、timer 和最近执行结果，并确认自动重启策略。
[Ubuntu 自动更新文档](https://ubuntu.com/server/docs/how-to/software/automatic-updates/)

## 现场只读命令清单

在已验证主机身份的 VPS SSH 会话中执行，root 或逐条 sudo。以下不安装软件、不刷新 APT、不重启服务、不改变 SSH 或防火墙；原始输出留在私密记录。
每条命令记录退出码；缺少命令、权限不足或服务未启用分别记录，不能统一当作 PASS。

身份、程序与服务：

```sh
date -u
cat /etc/os-release
uname -r
dpkg --print-architecture
/usr/local/bin/sing-box version
sha256sum /usr/local/bin/sing-box
getent passwd sing-box
id sing-box
passwd -S sing-box
systemctl show sing-box.service \
  -p ActiveState -p SubState -p MainPID -p NRestarts -p User -p Group \
  -p FragmentPath -p DropInPaths -p NoNewPrivileges \
  -p CapabilityBoundingSet -p AmbientCapabilities \
  -p ProtectSystem -p ProtectHome -p PrivateTmp -p PrivateDevices \
  -p RestrictAddressFamilies -p UMask -p LogRateLimitIntervalUSec -p LogRateLimitBurst
namei -l /usr/local/bin/sing-box /etc/sing-box/config.json /etc/systemd/system/sing-box.service /var/backups/sing-box
```

SSH、监听与防火墙：

```sh
/usr/sbin/sshd -t
/usr/sbin/sshd -T | awk '$1 ~ /^(port|listenaddress|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|authenticationmethods|usepam|allowusers|allowgroups|denyusers|denygroups)$/'
ss -lntup
ufw status verbose
nft list ruleset
iptables-save
ip6tables-save
```

上面的 sshd -T 只显示默认上下文。存在 Match 时，需按本次真实用户名、来源地址、目标地址和端口补充 sshd -T -C 检查；普通管理员未确定前，该路径保持 NOT RUN。服务商防火墙另由操作者在控制台核对。

更新与日志：

```sh
dpkg-query -W -f='${Package} ${Status} ${Version}\n' unattended-upgrades
apt-config shell UPDATE_LISTS APT::Periodic::Update-Package-Lists UNATTENDED APT::Periodic::Unattended-Upgrade AUTO_REBOOT Unattended-Upgrade::Automatic-Reboot
apt-config dump | awk '/^Unattended-Upgrade::(Allowed-Origins|Origins-Pattern|Package-Blacklist)/'
systemctl show apt-daily.timer apt-daily-upgrade.timer -p ActiveState -p UnitFileState -p LastTriggerUSec -p NextElapseUSecRealtime
systemctl show apt-daily.service apt-daily-upgrade.service -p ActiveState -p Result -p ExecMainStatus -p ExecMainExitTimestamp
journalctl --no-pager -u apt-daily-upgrade.service --since '7 days ago' -n 60
systemd-analyze cat-config systemd/journald.conf
journalctl --disk-usage
```

apt-config 未输出某个键时需核实默认值，不直接判断关闭。定时器正常也不能代替实际更新成功记录。
如果需要查看 unattended-upgrades 的具体成功/失败原因，只读取其最近有限日志；本批不运行 upgrade 或 unattended-upgrade 的 dry-run。
本清单没有读取 sing-box 密钥、SSH 私钥、shadow 正文或凭据文件的命令。

## 2026-09-08 现场只读核查结果

操作者授权后已完成目标 VPS 的只读核查。**sing-box 运行隔离符合既定基线，但服务器安全基线仍有三项待加固。**
原始地址、认证信息、日志和配置摘要只保存在忽略的私密目录，本文仅记录脱敏结论。

| 项目 | 现场结论 |
| --- | --- |
| 程序与运行身份 | 官方 1.14.0 amd64 程序摘要匹配；专用非 root 账号、nologin、锁定密码和无补充组符合要求 |
| 服务隔离与权限 | 最小 capability、NoNewPrivileges、文件系统隔离、配置目录/文件权限和 unit 属性符合基线 |
| 暴露面与日志 | 代理仅 IPv4 TCP 443；SSH IPv4/IPv6 TCP 22；未见公网 SOCKS/API；日志容量和速率限制生效 |
| SSH | 本次实际 root 密码认证成功，生效配置允许 root/密码登录；普通密钥管理员路径尚未建立并验证 |
| 主机防火墙 | UFW/nft 工具缺失；IPv4/IPv6 的 iptables-nft filter 链均默认 ACCEPT、无规则，legacy 无规则 |
| 自动安全更新 | unattended-upgrades 未安装；现场 APT 源码及配置确认刷新/升级周期均为 0，已启用 timer 不代表实际执行更新 |

完整原生 nftables 家族、服务商防火墙和系统补丁最新性仍未验收。
备份目录尚不存在符合首次替换才创建的实现，不作为权限缺陷。
当前 sing-box PID、重启计数、进程开始时间及所测配置摘要前后相同；本轮没有执行加固或切换协议。

命令记录：第一轮 SSH exit 0，27 组远程命令；采集器未识别结果名称中的数字，exit 1，只保存 26 组。
已保留首轮失败，随后修正采集并完成 11 组定向补查，包含 IPv6 及其他防火墙后端，SSH/采集器 exit 0。
命令缺失、包缺失和备份目录不存在的非零结果均按事实保留，不以“所有命令 PASS”表述安全结论。
两个采集脚本均通过 Bash/Python 语法检查；此项不代替 Ubuntu 上的实际命令结果。

下一步按普通密钥管理员的新会话验证、最小入站规则、自动安全更新的顺序准备加固。
实施时继续保留可用 SSH 与控制台恢复入口，并保持单台 VPS 和现有 SS2022 范围。

## 单协议试验的边界

- SS2022 保留作回退，复用现有 TUN、DNS、分流、防回环与 en4 出站约束。
- 当前 SS2022 已占用同一 IPv4 的 TCP 443。新协议先用一个经确认空闲、单独授权的端口做功能试验；如需改用 443，另安排端口交接和回退，不能让两个服务争用或临时叠加未审查的分流前端。
- 非 443 试验只证明功能，不等于 443 部署的流量外观，也不证明长期抗封锁能力。
- 协议尚未选定；不生成生产凭据、证书，不部署第二个服务。

本机已执行 `/opt/sing-box/1.14.0/sing-box version`，exit 0，版本 1.14.0，darwin/arm64，构建包含 with_naive_outbound 和 with_utls。
这只是构建能力确认，不代替协议配置检查或真实链路测试。

Naive 候选：使用 HTTP/2；先准备可控域名、有效证书和正常网站前端。1.14.0 官方文档支持 Apple 平台 Naive 出站；官方 NaiveProxy 部署示例使用带相应 forwardproxy 的 Caddy 与网站前端。
若采用独立客户端进程，必须另证其 en4 绑定，不能继承 SSH 的绑定结论。
[1.14.0 Naive 支持](https://github.com/SagerNet/sing-box/blob/v1.14.0/docs/configuration/outbound/naive.md)
[NaiveProxy 服务端设计](https://github.com/klzgrad/naiveproxy#server-setup)

REALITY 候选：可用现有 sing-box 的 VLESS / Vision 与 REALITY 能力，仍需审查目标站、客户端行为及未认证连接处理。减少域名证书维护是部署取舍，不作为抗识别效果保证。
[Vision 字段](https://sing-box.sagernet.org/configuration/outbound/vless/#flow)
[uTLS 局限](https://sing-box.sagernet.org/configuration/shared/tls/#utls)

截至本轮查看，官方发布页标记 1.14.0 为 Latest；这不证明没有漏洞或无需持续核查。任何新版本都要先核对变更及配置兼容，再做链路验证，不因本次讨论直接升级。
[官方发布页](https://github.com/SagerNet/sing-box/releases)
