# Mac 客户端

本文只说明仓库中的 `scripts/connect-vps.sh`，它不是当前日用 TUN 后台服务的安装器。
VPS 到 Mac 完整部署顺序、固定 1.14.0 后台布局及实测边界见 [当前真实部署流程](deployment-flow.md)。

一个 Bash 脚本连接已部署的 VPS。适用于 **Apple Silicon Mac + Homebrew**。
项目依赖全部使用 Homebrew 当前稳定版：Bash、curl、jq、OpenSSL、sing-box。
运行时明确选择 Homebrew 工具路径；不使用系统 Bash 3.2，也不固定下载某个旧版客户端包。

## 1. 安装或更新依赖

在 Mac 普通用户终端执行；以后升级依赖也使用同一组命令：

```bash
brew update
brew install --formula bash curl jq openssl sing-box
brew upgrade --formula --no-ask bash curl jq openssl sing-box
```

需要先安装 [Homebrew](https://brew.sh/)。准备命令会更新已有同名软件以及 Homebrew 需要更新的关联依赖。
sing-box 由 Homebrew 选择适合当前 macOS 的包，并负责下载校验，不再使用先前仅支持 macOS 26 的固定压缩包。

“最新”指执行上述准备命令时 Homebrew 提供的稳定版本。脚本日常启动不隐式升级软件，
会根据 Homebrew 已刷新的元数据拒绝过期依赖；如依赖被 pin，需先检查并解除相应 pin。
不用 HEAD/beta。macOS 的接口和进程查询继续使用操作系统提供的命令。

2026-09-06 查询到的版本仅作记录，**不是版本锁**：

| 项目依赖 | 当时稳定版 |
|---|---|
| [Bash](https://formulae.brew.sh/formula/bash) | 5.3.15 |
| [curl](https://formulae.brew.sh/formula/curl) | 8.22.0 |
| [jq](https://formulae.brew.sh/formula/jq) | 1.8.2 |
| [OpenSSL](https://formulae.brew.sh/formula/openssl@3) | 3.6.4 |
| [sing-box](https://formulae.brew.sh/formula/sing-box) | 1.14.0 |

## 2. 导入 VPS 配置

下载 `connect-vps.sh`。使用你已经验证主机身份、能够直连 VPS 的 SSH/SFTP 连接，
把 VPS 的 `/etc/sing-box/config.json` 私密下载为 Mac 的 `~/Downloads/vps-config.json`。
这个文件含密钥，不要发到聊天、Git 或公开日志。

把下面的 `VPS_IP` 换成 VPS 的公网数字 IPv4 地址：

```bash
chmod 600 "$HOME/Downloads/vps-config.json"
/opt/homebrew/bin/bash connect-vps.sh setup VPS_IP "$HOME/Downloads/vps-config.json"
```

默认绑定之前已确认的物理网卡 `en4`。换网卡时，在 setup 最后明确指定，例如：

```bash
/opt/homebrew/bin/bash connect-vps.sh setup VPS_IP "$HOME/Downloads/vps-config.json" en0
```

setup 导入原密钥并用当前 sing-box 检查配置。连接设置保存在
`~/Library/Application Support/sing-box-vps/client.json`，权限为 600。
重复 setup 检查成功后替换，保留一份 `client.previous.json`；不会重新生成服务端密钥。

## 3. 启动或检查

```bash
/opt/homebrew/bin/bash connect-vps.sh
```

启动 `127.0.0.1:17890` 的 SOCKS5，完成一次 HTTPS 检查后保持运行。
保持这个终端打开，**Ctrl+C 停止本次客户端**。只检查一次并退出：

```bash
/opt/homebrew/bin/bash connect-vps.sh check
```

在另一个终端中使用运行中的客户端：

```bash
/opt/homebrew/opt/curl/bin/curl --noproxy "" --proxy socks5h://127.0.0.1:17890 https://example.com
```

支持 SOCKS5 的应用填写 `127.0.0.1`、端口 `17890`，并启用通过代理解析域名。
只代理明确选择该端口的应用；脚本不接管系统代理、TUN、DNS、路由或已有的后台服务。
回环端口不设额外认证，同一 Mac 上能访问它的本地进程可以使用这条代理。
本脚本没有 launchd、后台安装或通用进程控制器；本机另行完成的完整后台部署不由它启动。

## 检查与排障

客户端仅有一个 SS2022 TCP 443 出站，绑定所选物理网卡、关闭 MUX，没有 direct 回退。
运行前重建固定配置并检查，不会把保存文件中额外的 TUN 或 direct 字段带入运行配置。

HTTPS 检查使用 `socks5h` 请求 `https://www.cloudflare.com/cdn-cgi/trace`，保留正常 TLS 证书和
主机名验证，要求 HTTP 200、`h=www.cloudflare.com` 和 `ip=` 字段；不打印公网地址。
它验证一次连通性，不测延迟、吞吐或长期稳定性；目标站故障也可能使检查失败。

- 端口 17890 已占用：先关闭占用它的客户端。check 模式也需要独占该端口。
- 网卡缺失或未连接：检查 en4，或通过 setup 改成正确的 enN。
- 依赖缺失/过期：重跑第一步；始终用 `/opt/homebrew/bin/bash` 启动。
- 启动或 HTTPS 失败：私下查看 `~/Library/Application Support/sing-box-vps/client.log`。
  新版 sing-box 如不再接受该配置，会在启动前拒绝；不自动回退旧版。
- 强制杀死可能遗留空锁目录。确认本次客户端及其子进程均已退出后，才移除它：

```bash
rmdir "$HOME/Library/Application Support/sing-box-vps/running.lock"
```

正常退出会停止本次子进程、删除临时目录和锁。日志每次启动覆盖。
字段依据：[SOCKS](https://sing-box.sagernet.org/configuration/inbound/socks/)、
[Shadowsocks](https://sing-box.sagernet.org/configuration/outbound/shadowsocks/)、
[接口绑定](https://sing-box.sagernet.org/configuration/shared/dial/#bind_interface)。

## 验证状态

2026-09-06 核对已审核配置基线 `4258dda` 的 [CI](https://github.com/snkio027/sing-box-vps-bootstrap-simple/actions/runs/34030386419)：
static、mac-client、vm 三个 job 均 success。Mac job 在 macOS 26 更新 Homebrew 依赖后，
执行脚本语法、客户端单元测试及两份公开配置的 `check`；不会启动 TUN 或连接真实 VPS。

本脚本从 setup 到 run/check 的真实公网完整流程仍为 **NOT RUN**。已有的独立临时客户端、
以及当前固定 1.14.0 TUN 后台均完成了实际 HTTPS 验证，但不能替代这个脚本自身的端到端验收。
本脚本的检查仅确认响应具有 `ip=` 字段，不比较它是否等于用户提供的 VPS IPv4；
现场完整 TUN 验证另有出口相等检查及 en4 socket 观测。

早期依赖不全或尚未触发 CI 的记录保留在 [历史验证记录](validation.md) 和
[注释与独立建仓记录](commentary-validation.md)。公开仓库不包含真实配置或连接文件。
