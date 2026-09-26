# 1.14.2 升级与 VLESS + REALITY + Vision

2026-09-26，用户选定本方案。开发分支交付；当前真实 VPS/Mac 仍以此前 1.14.0 验收记录为准。
本批代码、公开测试配置和真实设备的运行状态分开记录，见 [验证记录](reality-validation.md)。

## 分步执行

1. 现有 VPS 运行 `maintain-vps.sh upgrade`：仅接受精确校验过的 1.14.0 或 1.14.2 二进制。
   原配置逐字节保留；先以新程序和服务账号检查配置，再备份、原子替换二进制、重启并验证。
   重复执行 1.14.2 保留健康 PID。未知安装、APT 管理版本、unit drop-in、非健康进程和未知配置停止。
2. 通过 SS2022 的实际 HTTPS 验证后，单独运行 `maintain-vps.sh reality`：添加 IPv4 TCP 8443 的
   VLESS / `xtls-rprx-vision` / REALITY，原 SS2022 TCP 443 和密钥不变。首次独立生成 UUID、X25519
   密钥和 8 字节 short ID；重跑保持全部凭据，拒绝暗中改变握手目标。VLESS 入站通过路由规则拒绝 UDP。
3. 已由本项目加固的主机，单独运行 `harden-vps.sh allow-reality`：核验当前管理员新 SSH/sudo 会话、
   实际 SSH 端口、文件和实时防火墙记录；仅增加双栈 TCP 8443 放行，保留 SSH/443、默认策略和更新策略。
   新增规则记录后，后续 `apply` 会保留它。SSH 占用 8443 或未知/外改规则时拒绝。未由本项目管理的防火墙需另审。
4. 私密交接客户端参数，用 1.14.2 检查候选；Mac 先独立 SOCKS 试跑，经 en4 核验两项 HTTPS 和真实出口，
   再安排既有 launchd 后台的程序升级及配置切换。手机通过各自应用导入，分别实测切网/锁屏/退出恢复。

示例命令在已授权的目标 VPS 上执行；握手目标必须另行核验，不照抄示例域名：

```sh
sudo bash /path/maintain-vps.sh upgrade
# 完成 SS2022 HTTPS 验证后另一次调用：
sudo bash /path/maintain-vps.sh reality \
  --handshake-server HANDSHAKE_HOST --server-name TLS_NAME --handshake-port 443
# 从新的管理员 SSH 会话执行，仅适用于本项目已完成加固的主机：
sudo --preserve-env=SSH_CONNECTION bash /path/harden-vps.sh allow-reality \
  --admin ADMIN --ssh-port SSH_PORT --confirm-console
```

1.14.2 新主机仍先执行 `prepare-vps.sh` 安装 SS2022，再执行上述协议步骤。旧版主机必须用独立升级入口，
不能将重跑安装器当成升级。添加 REALITY 后，单协议安装器会在 APT 等持久修改之前拒绝覆盖配置。
`connect-vps.sh` 仍是 SS2022 简易客户端；新协议使用本批完整模板，不伪称旧 setup 已支持 VLESS。

## 握手目标与能力边界

REALITY 握手目标不是代理最终网站，也不是随便填写的 SNI。部署前从 VPS 核对目标的可达性、TLS 1.3、
X25519 协商、证书覆盖所填 server name 以及所需 ALPN；检查未认证连接的行为和目标变化风险。
脚本校验字段与配置，**不自动选择站点，也不宣称通过公网握手目标兼容性检查**。
公开模板中的 `www.example.com` 仅为占位，不是已审核的生产目标；VM 使用独立本地合成 TLS 目标。

本批保持 TCP 策略，Vision 不叠加 sing-box MUX。所有协议使用独立凭据；REALITY 私钥只留服务器，
客户端仅需 UUID、公钥、short ID、server name 和 VPS 地址/端口。凭据不放 argv、环境变量或日志。
首次生成的公私钥配对仅保存在本次 root-only 备份 `reality-keypair.private`，不要将它整份交给客户端。

客户端增加手动 `selector`，默认仍为 `ss2022`；可明确选择 `reality`。DNS、规则下载和既有代理路由
继续指向 selector 的 `vps` 标签；不设置自动直连回退。Mac 保留 en4；手机保留平台 socket 保护，
不硬编码网卡。缓存 ID 保持旧值，避免因为补丁版本变动主动丢弃 FakeIP 映射。

REALITY 的 TLS 外观不是不可识别保证；sing-box 官方提醒 uTLS 的指纹局限。此批不承诺速度提升、
UDP 支持或同一 VPS IP 被封时仍可用。服务商端口策略仍需独立核查。

## 有限恢复

维护入口与安装器共用 `/run/lock/sing-box-install.lock`。修改前保存原程序、配置和 unit 到
`/var/backups/sing-box/maintain.*`，并写入 `/var/lib/sing-box-maintenance/pending`。
正常失败或 TERM/INT/HUP 尝试恢复原程序/配置并验证 5 秒；恢复失败保留 pending，操作仍返回非零。
SIGKILL、断电不能执行 trap；后续入口拒绝盲目重试。没有通用事务引擎、轮换或自动整机重启。

中断后在 root 控制台核查 pending 指向的备份，执行备份 `SHA256SUMS` 检查，确认 unit 未外改。
如需恢复，将备份 `sing-box` 和 `config.json` 分别复制到原目标目录的临时文件，设为 root:root 0755
及 root:sing-box 0640，再同目录 rename；重启 sing-box 并核验 PID/监听、稳定运行及 SS2022 HTTPS。
成功后才删除 pending。不能直接对正在运行的二进制执行覆盖写入，也不能跳过备份校验清除标记。

防火墙变更单独使用 `/var/lib/sing-box-hardening/firewall-updating`，内容是其备份目录。
中断后还原该目录 `ufw-before-apply/` 内四份 UFW 文件（包括 `/etc/default/ufw`），运行 `ufw reload`，
恢复备份中的 `ufw-files.sha256`、`nft.json` 到加固状态目录，移除本次新增的 `reality-enabled`，
再核验两条原允许规则、默认策略和新的 SSH 连接；全部通过后才清除 `firewall-updating`。
不要执行 `ufw reset`，不要只删标记强行重试。此恢复针对新增 8443 前的已管理启用状态。

## Mac 固定后台的升级准备

Mac 最新候选路径为 `/opt/sing-box/1.14.2/sing-box`，其余已验收配置、工作目录、日志和 launchd label 保持原布局。
本批不将 Homebrew 简易客户端升级误认为固定后台已升级。官方制品摘要见
[client-versions.json](../examples/1.14.2/client-versions.json)，其中含归档和内层可执行文件的大小/SHA-256。

现场操作需要先检查现有 root 路径、原程序/配置/启动项及运行身份，保留私密备份，以新程序检查当前配置。
先只更新 launchd 的 ProgramArguments[0] 与默认 CLI 软链接，核验原 SS2022 路径；之后再替换含 REALITY
的私密配置并测试。停止旧进程后才能启动新 TUN；保留有效缓存/规则及对应备份。
失败时恢复原启动项/配置、程序引用和所需缓存，重新验证原链路。后台短暂中断属于切换的一部分。
当前没有新的通用 Mac 安装器；已下载候选程序、公开模板检查不代表机器已升级。

## 官方来源

- [1.14.2 正式发布](https://github.com/SagerNet/sing-box/releases/tag/v1.14.2)
- [VLESS 入站](https://sing-box.sagernet.org/configuration/inbound/vless/)、[VLESS 出站](https://sing-box.sagernet.org/configuration/outbound/vless/)
- [REALITY 字段与 uTLS 限制](https://sing-box.sagernet.org/configuration/shared/tls/)
