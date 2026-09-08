# 从零部署：当前真实流程与支持范围

更新：2026-09-08。对象是精简项目 `sing-box-vps-bootstrap-simple`。
本说明依据当前两份脚本、已审核配置基线、本机后台部署及两端重启核验记录整理。
2026-09-08 已另外完成指定 VPS 的主机加固和受控重启；本次文档同步没有连接 VPS 或修改 Mac 服务、网络设置。

**当前已打通一台 VPS → 一台 Mac 的日用 TCP 代理链路。VPS 安装有通用脚本；Mac 完整 TUN 后台配置已在操作者机器落地，但尚无仓库内通用安装入口。**

## 1. 整体顺序

| 顺序 | 做什么 | 交付结果 | 当前执行方式 |
| --- | --- | --- | --- |
| 1 | 准备 VPS、SSH、时间同步和 TCP 443 放行 | 一台满足安装条件的 Ubuntu VPS | 操作者完成；脚本检查部分前提 |
| 2 | 单独配置 SSH 管理员、UFW、自动安全更新 | 密钥管理入口和主机安全基线 | 指定 VPS 已手工完成；独立 [harden-vps.sh](hardening.md) 已实现，测试状态另列；代理安装器不自动加固 |
| 3 | 安装依赖、服务账号、条件 swap、sing-box 和 systemd | VPS 后台提供 SS2022 TCP 443 | `scripts/prepare-vps.sh` 自动完成 |
| 4 | 私密取回服务端配置，记录公网 IPv4 | Mac 获得同一份 SS2022 密钥 | 已核验主机身份的 SSH＋sudo；脚本不登录 VPS |
| 5 | 用独立客户端确认协议和 HTTPS | 证明密钥、公网端口及代理请求可用 | 可用 `connect-vps.sh check`；本机证据来自另行准备的 1.14.0 客户端 |
| 6 | 准备完整客户端配置、规则和固定版本程序 | 可检查的 TUN 候选目录 | 根据已审核基线私密生成；尚非通用脚本 |
| 7 | 停止旧代理、测试完整 TUN | 普通应用路由、HTTPS、真实出口证据 | 操作者控制的临时试跑；避免同时运行两套 auto_route TUN |
| 8 | 安装固定目录及 launchd，处理旧自启与 PAC/WPAD | 不依赖终端的日用后台服务 | 本机已通过专用安装流程完成；需要管理员权限 |
| 9 | 验证、维护、保留备份 | 可检查、可重启、有恢复材料 | 两端各自使用 systemd / launchd；不是通用事务控制器 |

新机器按这个顺序部署；现网历史上先安装了代理再手工加固，新入口的完整组合验收仍待第二批。已经运行本项目后台代理的 Mac 不应盲目重跑独立客户端检查：17890 已被后台服务占用。

## 2. VPS：从空系统到运行中的服务

### 准备条件

- Ubuntu 24.04，`amd64` 或 `arm64`，systemd，非容器 VPS/VM。
- 有 root 权限；保留现有 SSH 入口及服务商控制台。确认 SSH host-key 后再传输文件。
- 系统已有时间服务且 `NTPSynchronized=yes`；脚本不会修复时间同步或设置时钟。
- APT 与官方制品 HTTPS 下载可用；`/var/lib` 至少有 3 GiB 可用空间。
- TCP 443 没有外部监听者；回环或 IPv6 上的冲突监听也会被检查。
- 操作者在主机和服务商防火墙中允许 IPv4 TCP 443。脚本不配置防火墙、SSH 端口或 DNS。

1 GiB 内存 / 20 GiB 磁盘是已经跑过的 VM 测试规格，不是要求磁盘恰好为 20 GiB。

### 获取与执行

获取并审查本仓库的脚本；可以在加固前用初始 root 入口上传材料。加固后改用管理员登录与 sudo，不能再依赖 root SSH。
下面大写的 SSH_PORT、VPS_IP 是待替换的非秘密占位符：

```sh
git clone https://github.com/snkio027/sing-box-vps-bootstrap-simple.git
cd sing-box-vps-bootstrap-simple
scp -P SSH_PORT scripts/prepare-vps.sh root@VPS_IP:/root/prepare-vps.sh
```

在 VPS 上执行默认安装：

```sh
sudo bash /root/prepare-vps.sh
```

本次若也要升级已安装的 Ubuntu 软件，使用以下命令替代上面一条，不必先后执行两遍：

```sh
sudo bash /root/prepare-vps.sh --upgrade-system
```

### 安装过程中实际发生的事

| 子步骤 | 实际修改或检查 | 支持与边界 |
| --- | --- | --- |
| 预检与安装锁 | 检查平台、资源归属、端口、NTP 状态和空间；获取排他锁 | 拒绝并发安装、旧控制器状态、APT 管理的 sing-box、外来 unit 和不匹配的二进制 |
| 依赖 | 每次执行 APT update 并安装所需依赖 | 默认安装也会修改包状态；不是只读命令 |
| 服务账号 | 创建或验证锁定密码、nologin、无补充组的 `sing-box` 系统账号 | VPS 服务由非 root 账号运行，不创建 SSH 管理员 |
| 条件 swap | 内存不超过 2 GiB、无活动或 fstab 配置的 swap、ext4/xfs、至少 5 GiB 可用空间时，创建并启用 1 GiB swap | 已有 swap 保留；不支持的文件系统跳过；未知的未启用 swapfile 拒绝覆盖 |
| 可选系统升级 | 仅 `--upgrade-system` 执行 `apt-get upgrade`，保留现有配置文件 | 不自动重启机器；包更新后需要重启时提示操作者 |
| 固定程序 | 下载官方 1.14.0 `.deb`，检查包与内部程序的大小、SHA-256，只提取程序 | 不执行 `.deb` 安装脚本，不登记为 APT sing-box 包，不安装附带 Polkit/D-Bus 文件 |
| 配置 | 首次生成随机 16 字节 SS2022 密钥；重跑复用原密钥；以服务账号执行 `sing-box check` | 候选通过后备份并原子替换单个文件；密钥不打印 |
| 后台服务与日志 | 安装 systemd unit，启用开机启动、失败重启、低端口 capability 及沙箱；写入 journald 限制配置 | journald 的 128 MiB 磁盘 / 32 MiB 运行时限制是全机设置，不是独占的 sing-box 配额 |
| 本机验收 | 观察 5 秒，检查服务、PID、程序和 TCP 443 归属，无本进程 UDP 443 监听 | 这一步不证明公网可达或真实 SS2022 请求成功 |

VPS 最终提供：`2022-blake3-aes-128-gcm`、IPv4 TCP 443、单用户密钥、direct 出站；服务端允许 MUX。
443 上提供的是 SS2022 服务，不是网站 HTTPS 入口；不需要为这个 SS2022 入口配置域名或 TLS 证书。

### 路径与核验

| 用途 | VPS 路径 |
| --- | --- |
| 程序 | `/usr/local/bin/sing-box` |
| 配置 | `/etc/sing-box/config.json`，`root:sing-box 0640`，目录 0750 |
| 服务 | `/etc/systemd/system/sing-box.service` |
| 可选 swap | `/var/lib/sing-box/swapfile`，root 0600 |
| 被替换文件备份 | `/var/backups/sing-box/run.*`，root-only；有旧文件替换时才创建 |
| 日志配置 | `/etc/systemd/journald.conf.d/60-sing-box-limits.conf` |

```sh
systemctl --no-pager status sing-box
systemctl is-enabled sing-box
ss -ltnp 'sport = :443'
journalctl --no-pager -u sing-box -n 50
```

重复执行会刷新 APT，保留密钥；受管配置和 unit 内容未变且服务健康时保留原 PID，不重复创建 swap。
**它不是“保留任意自定义配置”的工具**：除密钥外，受管配置会重新渲染为脚本的固定模板，修改前备份。

失败时根据 `ERROR [阶段]` 排查。此前完成的包、账号、swap 或文件修改可能保留，脚本不会整体自动回滚。
没有 `--check`、`--plan`、`--verify`、事务恢复、卸载或密钥轮换入口；旧复杂项目的这些能力不属于本脚本。

## 3. 私密交接与最小链路验证

通过已经核验主机身份的 SSH＋sudo，把 VPS 的 `/etc/sing-box/config.json` 私密下载到 Mac。
加固后的普通管理员 SFTP 不能直接读取 root:sing-box 0640 的配置；通过 `sudo -n` 读取，
输出只进入 Mac 的私密临时文件，传输和格式检查成功后再发布。失败时保留原客户端配置。
不为传输放宽服务端文件权限。当前脚本不负责这条远程取回路径，拟议入口见 [下一阶段计划](next-steps.md)。
Mac 文件应归当前用户所有、权限 0600；公网数字 IPv4 由操作者明确提供，不从本地 DNS 或出口检测猜测。

文件包含实际密钥，不进入 Git、聊天、命令参数或环境变量。客户端导入原密钥，不能另造一把不同的密钥。

[最小 Mac 客户端](mac-client.md) 可以完成独立的 SOCKS5 检查。它要求 Apple Silicon、Homebrew 当前稳定依赖及 Homebrew Bash 5.3+。
准备依赖会安装/升级指定软件，应在新机器或明确准备依赖时执行：

```sh
brew update
brew install --formula bash curl jq openssl sing-box
brew upgrade --formula --no-ask bash curl jq openssl sing-box
chmod 600 "$HOME/Downloads/vps-config.json"
/opt/homebrew/bin/bash scripts/connect-vps.sh setup VPS_IP "$HOME/Downloads/vps-config.json" en4
/opt/homebrew/bin/bash scripts/connect-vps.sh check
```

`setup` 保存 `~/Library/Application Support/sing-box-vps/client.json`，检查新配置后替换，并保留一份 previous 配置。
`check` 临时启动 127.0.0.1:17890，绑定选定网卡、MUX 关闭，通过 SOCKS5 请求 Cloudflare HTTPS，然后停止子进程。
`run` 则在检查成功后继续运行，直到 Ctrl+C。两者都需要该端口空闲，不安装 launchd，也不接管 TUN 或系统代理。

脚本检查 HTTP 200、TLS、目标标记和 `ip=` 字段，**没有把响应 IP 与给定 VPS IPv4 做相等比较**。
本机后续独立验证增加了这个比较，并用 nettop 核对了实际 en4 出口；不要把两种检查强度写成一样。

Homebrew 路径供这个最小客户端使用。当前日用后台另外固定在 `/opt/sing-box/1.14.0`，不会因为 `brew upgrade sing-box` 自动更换版本。

## 4. Mac：准备完整 TUN 配置

这一阶段需要人工准备候选材料。仓库的 [macos.example.json](../examples/1.14.0/macos.example.json) 是已审核的结构基线，
其中地址、SS2022 密钥和管理 API secret 是测试值，不能直接部署。`connect-vps.sh setup` 不会生成这份完整配置。

| 材料 | 实际需要完成的事 |
| --- | --- |
| 程序 | 获取并校验精确 1.14.0 Darwin arm64 程序，确认它能在目标 macOS 上运行 |
| VPS 信息 | 在私密候选中填入真实 IPv4、服务端原密钥，同时替换 VPS 直连规则中的示例 `/32` |
| 本机 API | 生成独立随机 secret，仅写私密配置；监听回环 19090 |
| 物理出口 | 核对 en4 活跃、能到 VPS，系统 DNS 上游经 en4 可达；更换网卡必须同步所有相关绑定 |
| 规则 | 准备 `rules/geosite-cn.srs`、`rules/geoip-cn.srs`、`rules/geosite-ads.srs`；来源见配置中的 URL |
| 运行差异 | 在基线之外增加固定日志输出，以及仅回环的 IPv4/IPv6 7890 mixed 兼容入口；保留 17890 |
| 缓存 | 新机器由程序创建；从已有测试实例迁移时先干净停止，再复制有效 `cache.db`，避免重置 FakeIP 映射 |

本轮官方 Mac 制品可从 [1.14.0 发布页](https://github.com/SagerNet/sing-box/releases/tag/v1.14.0) 获取：

| 项目 | 已核对值 |
| --- | --- |
| 文件 | `sing-box-1.14.0-darwin-arm64.tar.gz` |
| 包大小 | 29,123,654 字节 |
| 包 SHA-256 | `a150c94012ff768b7261939cd236b9c8554127f45137230295d23a5660225cc9` |
| 程序 SHA-256 | `973388c3f720e918fc64dff7fd75dde14b31cc1aa6fc15855e2f00c5291dd4f4` |

本机执行环境为 macOS 26.6.2 / arm64；这不是所有 macOS 版本的兼容性证明。先检查制品与版本，再用它检查候选。
三份规则及其本地快照也需要准备；公开仓库没有包含真实私密目录或 SRS 二进制。

完整配置的默认 rule 模式能力：

| 流量/功能 | 当前处理 |
| --- | --- |
| 普通应用 TCP | 通过 TUN/auto_route 接管，通常不需要逐个应用设置代理 |
| 本机、私有地址、本地域名 | `local-direct` 不硬编码网卡，`auto_detect_interface=true` 提供防回环保护；可达路径另行验证 |
| 国内域名列表命中 | en4 直连；国内 IP 集合只补充已有真实 IP，不为 FakeIP 域名做解析后兜底 |
| 其余普通公网 TCP | en4 → 单台 VPS → 目标网站 |
| DNS | 本地域走系统 DNS 上游；公共解析使用指定 DoH；TUN/主 mixed 的适用 A 查询使用 FakeIP |
| 广告规则 | 按广告规则集拒绝；不能保证拦截所有广告，应用自带加密 DNS 可能绕过相关规则 |
| UDP / ICMP | 前置本地/国内规则可以直连，其余拒绝；不提供经 VPS 的 UDP 代理 |
| 公网 IPv6 | 拒绝；前面的本地规则有例外；不全局禁用 macOS IPv6 |
| 显式代理 | 17890 和兼容 7890 mixed HTTP/SOCKS，仅回环；同机进程可使用 |
| 管理 | 带鉴权的回环 API，默认 rule；没有交付图形面板、节点订阅或自动故障切换 |

本地域解析取决于真实系统上游是否有相应记录。OrbStack、容器桥和其他 VPN 的兼容性不能仅由配置推断为通过。
自动接口保护也不会创建 Pod 路由：不可达目标应失败或超时，不能让出站反复回到自己的 TUN。
当前修复不依赖 Pod IP 拒绝列表；容器网段、网关及 `route_exclude_address` 的接入设计另行处理。

## 5. 临时 TUN 验证，再安装后台服务

本机实际走过的顺序如下；新机器上需要对其实际旧服务、接口和文件逐项处理：

1. 备份旧程序引用、配置、启动项和网络设置，核对旧进程身份。
2. 在独立工作目录准备完整私密配置、规则，用固定 1.14.0 执行 `check`。
3. 停止原代理，临时以前台 root 进程启动 TUN，验证路由和真实 HTTPS。
4. 准备固定目录与启动项；如果临时测试脚本退出时会恢复旧代理，要先等它清理完成，再接管启动项。
5. 停止临时进程后迁移有效缓存，部署固定程序/配置/规则，明确关闭所选网络服务遗留的 PAC/WPAD。
6. 由 launchd 直接启动 sing-box；验证服务归属、端口、API 模式、真实出口和重启后联网。
7. 备份后移除其他 sing-box 自启项，保留当前主服务及日志维护；清理后再核对联网。

**目前没有可以从新机器直接运行的 `install-mac.sh`。** 本轮一次性安装/测试文件绑定了现场旧进程、路径和备份，
不能复制它们到新机器或再次执行就当成通用安装器。可复用的是已审核配置基线、最终布局和核验步骤。

最终布局已在本机安装：

| 用途 | Mac 路径 | 权限 |
| --- | --- | --- |
| 程序 | `/opt/sing-box/1.14.0/sing-box` | root:wheel；程序及程序目录 0755 |
| 配置 | `/usr/local/etc/sing-box-vps/config.json` | root:wheel；目录 0700，文件 0600 |
| 缓存、规则、工作目录 | `/var/db/sing-box-vps` | root:wheel；目录 0700，文件 0600 |
| 日志 | `/var/log/sing-box-vps/service.log`、`startup.log` | root:wheel；目录 0700，文件 0600 |
| 主服务 | `/Library/LaunchDaemons/org.sing-box.plist` | root:wheel 0644 |
| 日志维护 | `/usr/local/libexec/sing-box-vps/rotate-logs.sh` | root:wheel；目录和脚本 0700 |
| 日志维护启动项 | `/Library/LaunchDaemons/org.sing-box-logrotate.plist` | root:wheel 0644 |
| 备份 | `/var/backups/sing-box-vps/` | root-only |

主启动项直接执行：

```sh
/opt/sing-box/1.14.0/sing-box run \
  -c /usr/local/etc/sing-box-vps/config.json \
  -D /var/db/sing-box-vps \
  --disable-color
```

使用 `RunAtLoad=true`、`KeepAlive=true`、`ThrottleInterval=15`、`ExitTimeOut=15`、`Umask=63`（八进制 077）。
父目录必须由 root 控制，普通用户不可写。只更换二进制路径或复制 JSON 不算完成这个阶段。

业务日志保持 info。日志维护每 300 秒检查一次，单文件达到 10 MiB 后复制并截断，保留五份历史日志，不重启 TUN。
这是有界保留策略，不是硬磁盘配额：检查间隔可超阈值，复制/截断之间可能少量漏记。

## 6. 如何判定部署成功

### 目前已取得的证据

| 范围 | 已验证的内容 | 不能扩展成什么结论 |
| --- | --- | --- |
| 已审核基线 CI | 静态、Mac 组件/配置检查、Ubuntu 24.04 x86_64 的 1 GiB / 20 GiB VM 安装测试通过 | Mac CI 没有启动真实 TUN，也没有连接真实 VPS |
| VM 协议与失败场景 | 真正 SS2022 HTTPS、错误密钥拒绝、端口冲突、原密钥/PID 保留、AF_NETLINK 故障复现与重跑修复 | 不代表任意阶段断电、APT 失败或一般性自动回滚 |
| 已有真实 VPS 检查 | 曾私密核对程序、服务、权限、TCP 443 和同步状态；后续真实 Mac 请求成功 | 本轮文档整理没有重新登录 VPS 审计全部状态 |
| 真实 VPS 加固及受控重启 | 新管理员密钥与完整免密码 sudo、禁用旧认证方式、UFW 双栈持久化、每日安全更新配置及 TUN/SOCKS HTTPS 通过 | 这是单独完成的现场运维；安装器不自动复现，服务商防火墙仍为 NOT RUN；见 [加固记录](server-hardening.md) |
| 当前 Mac 后台部署 | 21 项现场检查记录通过：固定程序/路径/权限、缓存迁移、TUN、API、端口、en4、HTTPS、受控重启与日志维护 | 不代表所有应用、容器网络、长期性能均已验收 |
| 旧自启清理 | 只保留主服务和日志维护；主 PID 未变，清理后再次经 VPS 请求 HTTPS 成功 | 旧配置/程序的保留不等于正在运行 |
| 一次真实 Mac 重启 | 10 项只读核验通过：主服务自动运行、本次开机仅启动一次、旧自启未恢复、日志任务成功、TUN/回环/API 正常，两项 HTTPS 及 VPS 出口/en4 通过 | 仅覆盖本次重启和当前有线网络，不代表断网启动、任意故障恢复或所有应用兼容 |
| OrbStack 基础兼容 | 现有本地 registry 的端口/IP/域名 HTTP、自动 HTTPS、经 mixed 解析本地域名；容器内部 DNS、到 Mac、公网 HTTPS/VPS 出口；现有 kind API 和四个 Ready 节点通过 | 不涵盖 Pod DNS/业务服务、OrbStack 内置 Kubernetes 或所有容器组合 |

CI 对应 `4258dda` 的 [已核对运行记录](https://github.com/snkio027/sing-box-vps-bootstrap-simple/actions/runs/34030386419)；
真实地址、密钥和原始现场证据保留在本机私密目录，不随本文公开。

本机完整链路检查对 Apple 和 Cloudflare 发出 GET，15 秒超时、4096 字节上限，正常验证 TLS，不跟随重定向。
要求 HTTP 200、各自固定标记；Cloudflare 出口必须等于配置的 VPS IPv4，同时通过 nettop 核对实际连接使用 en4。
重启后重复上述检查，7890 的 IPv4/IPv6 回环入口也实际转发了 HTTPS。

2026-09-06 已完成一次整机重启后的 Mac 自启与真实链路验收，并验证当前 OrbStack 2.2.3 的上述基础路径。
OrbStack 本地域 HTTPS 首次出现 5 秒 TLS 握手超时；未更改代理配置或关闭证书校验，后续 Mac/容器请求成功，
原 5 秒连接限时下两次复测也通过。首次失败保留，原因尚未确定，不将它写成从未失败或已完成配置修复。
另外通过两个新生成的 [容器通配子域](https://docs.orbstack.dev/docker/domains#wildcards)，分别验证系统及 mixed 入口的本地域名处理，
减少已有名称缓存对判断的影响。代理 PID、启动次数、DNS/代理设置、TUN 路由和现有五个容器的身份、状态、重启次数前后相同。
本轮没有创建、停止、重启容器，也没有修改 Kubernetes 资源或代理配置。

仍为 **NOT RUN**：Pod 层 DNS/业务服务与出口、OrbStack 内置 Kubernetes、其他容器组合、Wi-Fi 切换、当前手动回退脚本的端到端演练、
长期稳定性/吞吐、arm64 VPS 实际安装和 xfs swap 实测。UDP 代理、升级编排、密钥轮换等则是**未实现的能力**，不只是尚未测试。

## 7. 日常操作与失败处理

| 操作 | VPS | 当前 Mac 后台 |
| --- | --- | --- |
| 状态 | `systemctl --no-pager status sing-box` | `sudo launchctl print system/org.sing-box` |
| 日志 | `journalctl --no-pager -u sing-box -n 50` | `sudo tail -n 80 -F /var/log/sing-box-vps/service.log` |
| 重启 | `sudo systemctl restart sing-box` | `sudo launchctl kickstart -k system/org.sing-box` |
| 本次停止 | `sudo systemctl stop sing-box` | `sudo launchctl bootout system/org.sing-box` |
| 重新启动 | `sudo systemctl start sing-box` | `sudo launchctl bootstrap system /Library/LaunchDaemons/org.sing-box.plist` |

停止不等于取消下次开机启动；KeepAlive 下直接 kill Mac 主进程也不是停用办法。
配置修改先生成私密候选，用对应程序 `check`，通过后备份并原子替换，重启并检查实际联网。
Mac 配置检查命令如下；它与 VPS 安装脚本不存在的 `--check` 选项不是一回事：

```sh
sudo /opt/sing-box/1.14.0/sing-box check \
  -c /usr/local/etc/sing-box-vps/config.json \
  -D /var/db/sing-box-vps \
  --disable-color
```

VPS 失败使用阶段报错与文件备份人工处理；当前 Mac 另有现场绑定的旧代理恢复脚本，具体入口见本机私密运维说明。
后台安装验证失败时准备了恢复措施，但完整人工回退路径仍未实测；不要承诺任意失败都自动恢复。

没有交付多节点、自动直连回退、UDP 游戏/语音/QUIC 完整支持、公网 IPv6 代理、SSH 迁移、密钥轮换、自动版本升级或无痕卸载。
当前交付重点是：**能装一台 VPS、能验证真实 TCP/HTTPS、能在这一台 Mac 上由后台接管，并留下明确维护与恢复材料。**
