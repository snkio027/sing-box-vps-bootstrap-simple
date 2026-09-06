# sing-box 1.14.0 两端配置审查样例

本目录是操作者私密候选配置的结构脱敏副本，用于审查通过自有 VPS 替换现用 Mac 代理的方案。
**它不是可直接部署的配置，也不代表正式切换已经完成。**

| 文件 | 用途 |
|---|---|
| [server.example.json](server.example.json) | VPS：SS2022、IPv4 TCP 443、服务端允许 MUX、direct 出站 |
| [macos.example.json](macos.example.json) | Mac：TUN、回环 mixed、DNS、分流、广告阻断、带认证的 Clash API |

## 脱敏范围

- VPS 地址及其直连规则统一替换为文档示例地址 `198.51.100.10`。
- 两端 SS2022 密钥统一替换为字节 `00 01 … 0f` 的 Base64 编码。
  这是公开、可预测的测试值，仅用于配置语法检查，**不得用于部署**。
- 管理 API secret 替换为 `REPLACE_WITH_A_RANDOM_LOCAL_API_SECRET`。
- 未上传真实地址、实际密钥、账号、本机私有绝对路径、原始真实主机报告或私密配置文件。

除此之外，两份 JSON 与对应私密候选的配置结构和值相同。
没有把占位值藏在环境变量、命令参数或在线订阅地址中；实际部署时应通过私密文件提供真实值。

## 本轮修订

1. **本地出站不绑网卡。** `local-direct` 不设置 `bind_interface`，全局也不设置
   `default_interface` 或启用 `auto_detect_interface`。本机、私有地址和本地域名依赖系统已有
   lo0、桥接或 VPN 路由；VPS、普通公网 direct 和国内 DoH 继续绑定 `en4`。
2. **本地域名复用系统解析。** 单一 `dns-local` 使用 `type=local`、`prefer_go=false`，
   不绑接口。删除公网地址充当局域网 DNS 的设置，以及仅在 en4 查询 `.local` 的 mDNS 设置。
   `.local`（包含 OrbStack 的 `*.orb.local`）、`.lan`、`.home.arpa` 和单标签名称优先使用本地解析。
   这依赖系统本身已有正确记录，不会自动创建内网域名或启动容器环境。
3. **GeoIP 仅补充已有真实 IP。** `geosite-cn` 和 `geoip-cn` 分开列出。默认 rule 模式下，
   国内域名列表直连，其余域名走 VPS；没有为 FakeIP 域名增加 `resolve`，不能把 GeoIP
   描述为这些域名的“解析后国内 IP 兜底”。
4. 私密候选的管理 API secret 已重新生成；公开副本始终使用上述占位符。
   既有服务端配置及实际 SS2022 密钥没有因此改变。

依据：[1.14.0 接口绑定实现](https://github.com/SagerNet/sing-box/blob/v1.14.0/common/dialer/default.go)、
[Local DNS](https://github.com/SagerNet/sing-box/blob/v1.14.0/docs/configuration/dns/server/local.md)、
[本地解析实现](https://github.com/SagerNet/sing-box/blob/v1.14.0/dns/transport/local/local.go)、
[FakeIP 与路由](https://github.com/SagerNet/sing-box/blob/v1.14.0/route/route.go)、
[OrbStack 域名](https://docs.orbstack.dev/docker/domains)、
[home.arpa](https://www.rfc-editor.org/rfc/rfc8375.html#section-3)。

## 协议策略

服务端 MUX 开启表示允许复用，客户端 MUX 关闭可以正常配合。两端的代理链路只支持 TCP。

| 流量 | 默认 rule 模式 |
|---|---|
| 本机、私有地址、本地域名 | local-direct，按系统已有路由转发 |
| VPS 地址 | en4 直连，避免到 VPS 的 SSH 等连接绕回代理 |
| 国内域名列表中的普通 TCP | en4 直连 |
| 其他普通域名 TCP | 经 VPS |
| 已有真实目标 IPv4 | 国内 IP 集合命中时直连，否则继续匹配 |
| UDP、ICMP | 前面的本地/国内规则可以直连，其余拒绝 |
| 公网 IPv6 | 拒绝；前面的本地规则存在例外，不在系统上全局关闭 IPv6 |
| 广告域名 | direct、rule、global 模式都可能阻断 |

这是以 TCP 为主的整机接管候选，不能宣称完整支持 UDP 游戏、语音、QUIC/HTTP3。
API 切换 global/direct 时仍保留前置的本地、公网 IPv6 和广告策略；规则集下载固定经过 VPS。
没有 VPS 故障后自动直连回退。应用自带的加密 DNS 可能绕过此配置的 DNS 分流或广告规则。

## 工作目录和替换现用代理

样例 mixed 监听 `127.0.0.1:17890`，管理 API 监听 `127.0.0.1:19090`。
两者仅供本机访问；mixed 不另设认证，同机进程可以使用它。

三份远程 SRS 配置保留 `initial_path`，路径相对于运行时明确指定的 `-D` 工作目录。
本目录没有打包规则二进制；操作者应在私密工作目录准备对应的 `rules/*.srs`，并确认可读。
`cache.db` 独立保存远程规则缓存和 FakeIP 映射。没有缓存且初始文件不可用时，首次启动依赖下载成功。
规则文件来源与更新 URL 已明确列在 JSON；默认每天更新一次，经 VPS 的显式 HTTP client 下载。

依据：[1.14.0 initial_path / HTTP client](https://github.com/SagerNet/sing-box/blob/v1.14.0/docs/configuration/rule-set/index.md)。

真正替换现用代理时，还需完成原配置/启动项备份，核对现有应用端口、系统代理和 PAC/WPAD，
处理入口兼容性，验证完整 TUN 接管与退出恢复，最后验证新启动项持久运行。
不能只替换 JSON 就声称日常流量已经切换。不要同时运行两套 auto_route TUN。
本轮没有修改安装器或 `connect-vps.sh`；后者仍只生成它自己的最小 SOCKS 配置，不加载此完整 TUN 样例。

## 公开样例验证

在仓库根目录，用已安装的 **1.14.0** 二进制执行。变量只保存程序路径，不含凭据：

```sh
SING_BOX_114_BIN=/path/to/sing-box-1.14.0
"$SING_BOX_114_BIN" version
"$SING_BOX_114_BIN" check -D "$PWD/examples/1.14.0" -c "$PWD/examples/1.14.0/server.example.json"
"$SING_BOX_114_BIN" check -D "$PWD/examples/1.14.0" -c "$PWD/examples/1.14.0/macos.example.json"
git diff --check
```

2026-09-06 本机复核：Apple Silicon macOS 26.6.2、官方 sing-box 1.14.0，两份公开样例
`check` 均 exit 0、无诊断输出。仅有敏感字段被替换的结构比较通过；提交文件的敏感值扫描通过。
这些检查不需要本地 SRS 文件，不执行 `run`，不创建 TUN、不连接示例地址，也不证明启动可用。

现有 macOS CI 增加这两份样例的 `check`，使用该 job 安装的 Homebrew 当前稳定版并记录实际版本；
它与上述精确 1.14.0 本机复核分别记账。CI 是否通过，以 PR 的实际检查状态为准。

## 尚未验收的部分

| 检查 | 本次公开样例状态 |
|---|---|
| JSON 解析、精确 1.14.0 配置检查、脱敏结构比较 | PASS，exit 0 |
| 样例地址/公开测试密钥的真实代理请求 | NOT RUN；这些值不得用于部署 |
| 完整 TUN 启停、日常代理正式替换、开机启动 | NOT RUN |
| OrbStack、容器与 Kubernetes 实际服务 | NOT RUN |

公开仓库没有附带真实主机证据。私密候选的有限测试不能被当作这份公开样例的实际部署证明，
更不能替代完整 TUN、容器网络或正式切换验收。
