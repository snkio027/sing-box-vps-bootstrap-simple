# 服务器安全加固

2026-09-08：指定 VPS 的 SSH、UFW 和自动安全更新已经加固，在线验收通过。
**一次受控 VPS 整机重启及四项恢复验收 PASS；主机加固及重启恢复已完成。**
本轮沿用单台 VPS 与现有 SS2022；没有更换协议或更改 Mac 代理配置。

这是该目标的显式授权运维操作，尚未并入 [prepare-vps.sh](../scripts/prepare-vps.sh)。
从零重建时仍需单独完成此节的安全步骤，不能把安装器成功当作已自动加固。
最初发现与只读命令见 [安全核查](server-security-review.md)。

## 实施与验收

| 项目 | 已实施 | 在线证据 |
| --- | --- | --- |
| SSH 管理员 | 普通管理员、Ed25519 公钥、锁定本地密码、经 visudo 检查的免密码 sudo | 创建后、收紧认证后、UFW 后、更新后各建立全新公钥连接并提权，均 exit 0 |
| SSH 认证 | 早期加载的独立片段；禁 root、密码和键盘交互认证，仅允许公钥；保留端口 22 | sshd -t 与管理员/root 的 sshd -T -C 通过；禁止方式的新连接测试均 exit 255 |
| 防火墙 | UFW IPv4/IPv6；默认入站/转发 DROP、出站 ACCEPT；用户放行仅 22/tcp 与 443/tcp | 两个后端的实际默认政策、各两条用户规则、启用标记与启动项均已核对 |
| 控制流量 | 保留 UFW 默认 before/before6 规则 | 文件摘要前后相同，未删除连接跟踪、必要 ICMP/DHCP 等默认规则 |
| 自动安全更新 | 每日索引刷新与自动更新；仅 noble-security 来源；明确禁止自动整机重启 | 有效配置、dry-run 和实际运行均通过；两个 APT timer active/enabled |
| 代理链路 | 保持现有 sing-box 1.14.0 与 SS2022 | UFW 后和实际更新后，共 8 项 TUN/SOCKS HTTPS 请求通过，Cloudflare 出口符合目标 |

实际更新运行没有找到允许来源中的待安装更新，前后软件包版本变化为 **0**；不把模拟或无更新结果说成安装了补丁。
更新运行后未出现 reboot-required；随后按操作者的明确指令完成一次受控重启。
手工部署的 sing-box 仍需独立审查更新，不能依赖 unattended-upgrades。

免密码 sudo 采用 `ALL=(ALL:ALL) NOPASSWD: ALL`，是操作者明确选择的**完整管理员提权权限**，不是受限 sudo。

另做四次认证方法检查，服务器实际只公布 publickey，避免把客户端 BatchMode 不交互导致的失败误当作服务端禁用密码。四项均通过。

## UFW 和更新细节

启用 UFW 前，先取得并核对完整原生 nftables 规则，只存在已知空 filter 表。
nftables.service 保持 disabled，避免另一个规则加载器与 UFW 竞争。
主机内核转发为关闭状态，因此 UFW 的状态文本显示 routed=disabled；
配置的默认转发策略和实际 FORWARD 链均为 DROP，未为改变显示文本启用内核转发。

首次验证误把 routed 的显示文本和 IPv6 的 ufw6-user-input 链名当成其他形式，产生两次 exit 1。
已保留失败结果，并依据实际配置/内核规则修正检查后通过；没有为通过检查改动正确的防火墙行为。

首次安装工具时临时阻止包脚本启动服务，避免安装 nft 工具触发规则加载；临时保护文件已移除。
真实安全更新采用 needrestart 的系统默认行为，可能重启服务，实施窗口已由操作者确认。
自动整机重启明确关闭，不能推导为永远没有服务重启。
[Ubuntu 自动更新与服务重启](https://ubuntu.com/server/docs/how-to/software/automatic-updates/#service-restarts)

## 恢复与剩余范围

控制台恢复入口已由操作者确认。原 root SSH 会话保留到新管理员、UFW 和代理通过验证后才正常关闭。
私钥始终留在 Mac，本机旧认证输入文件已收紧到 0600；原始证据和备份保持私密，没有公开提交真实凭据。

服务商防火墙仍为 **NOT RUN**，需要独立核查；主机验收不代表服务商控制面的配置已经核对。

## 受控重启验收

2026-09-08 11:18–11:20 UTC（北京时间 19:18–19:20），Ubuntu 24.04 amd64 与 macOS 26.6.2 arm64、
sing-box 1.14.0。重启前确认 en4 可用、全新管理员密钥登录/sudo 成功，包管理锁空闲。
控制台恢复入口沿用操作者已确认可用的结果。仅发送一次 `sudo -n /usr/bin/systemctl reboot`，SSH exit 0；
重启后再次读取 boot ID，与紧邻重启前的现场记录不同，确认实际发生了重启。

| 验收项 | 现场结果 |
| --- | --- |
| 管理员和认证策略 | 新连接公钥登录及 sudo exit 0；root/密码/键盘交互的四个负向路径按预期 SSH exit 255，只公布 publickey；语法和实际上下文的有效策略同时通过 |
| UFW 持久化 | active/exited、enabled；IPv4/IPv6 默认入站与转发 DROP、出站 ACCEPT，用户规则每族仅 TCP 22/443；默认控制规则摘要一致 |
| sing-box 与实际链路 | 自动启动、非 root、NRestarts=0，主进程拥有 TCP 443；配置/程序摘要不变；TUN/SOCKS × 两个 HTTPS 目标四项通过，两个 Cloudflare 请求的出口均为指定 VPS |
| APT 持久化 | 两个 timer active/enabled；每日刷新/安全更新设置和仅 security 来源保留，Automatic-Reboot=false；没有 reboot-required |

运行内核从 6.8.0-117-generic 切换为已安装的 6.8.0-139-generic；本轮未执行包更新，不宣称此次安装了补丁。
HTTPS 均为 HTTP 200、TLS verify 0、无重定向且固定标记匹配。所有验证驱动 exit 0，
负向 SSH 的 255 属于预期结果；未因测试修改 Mac TUN、DNS、路由、代理配置或后台服务。

实际核验包含以下命令；有效 SSH 策略另外使用本次真实连接上下文执行 `sshd -T -C`，
完整断言、参数、每步结果与原始输出只在忽略的私密现场目录归档，未上传真实地址或凭据：

```sh
cat /proc/sys/kernel/random/boot_id
sudo -n id -u
sudo -n /usr/sbin/sshd -t
sudo -n visudo -c
sudo -n systemctl show sing-box.service ssh.service ufw.service nftables.service \
  -p Id -p MainPID -p NRestarts -p ActiveState -p SubState -p UnitFileState -p ExecMainStatus
sudo -n ss -ltnp 'sport = :443'
sudo -n ufw status verbose
sudo -n iptables-save
sudo -n ip6tables-save
sudo -n systemctl show apt-daily.timer apt-daily-upgrade.timer \
  -p Id -p ActiveState -p UnitFileState -p NextElapseUSecRealtime
```

HTTPS 使用现有 TUN 的无显式代理请求和现有 SOCKS 入口各一次访问 Apple success.html 与 Cloudflare trace，
设置 GET、15 秒超时、4096 字节上限、正常 TLS 校验、禁止重定向，并比较预期响应标记与 VPS 出口。
这是本机到该 VPS 的恢复验收，不扩展为长期稳定性、服务商防火墙或新协议验收。
