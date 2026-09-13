# Mac、Android、iOS 客户端

2026-09-13。按用户批准的兼容方案，已提供 Mac、Android 和 iOS 三份公开模板及检查入口，
客户端以交付时核实的最新稳定版本为目标。未生成真实密钥配置、安装应用、切换现用代理或连接真实 VPS。

## 本次核实的正式版本

| 平台 | 优先客户端 | 本次版本 | 说明 |
| --- | --- | --- | --- |
| Mac | 现有 sing-box CLI 与 launchd 部署 | 内核 1.14.0 | 沿用已验收的运行方式；其他 Mac 按自己的网络环境生成配置 |
| Android | 官方 sing-box for Android（SFA） | 1.14.0 | 官方 release 提供稳定 APK；普通设备使用系统 VPN 模式，无需 root |
| iPhone / iPad | 官方 sing-box MT | App Store 应用 1.14.4 | 官方新应用，要求 iOS/iPadOS 15+；应用版本与内置内核版本分别记录 |

GitHub Releases API 本次返回最新稳定内核 `v1.14.0`，发布于 2026-08-31，`prerelease=false`；
`1.15.0-alpha.*` 属于预发布，不作为本批日用基线。版本号不在运行时漂移：交付时记录精确版本、
来源和可获得的制品摘要；后续稳定更新需配置检查与验证，再明确替换。当前 VPS 不因客户端适配而自动升级。

来源：[1.14.0 官方发布](https://github.com/SagerNet/sing-box/releases/tag/v1.14.0)、
[最新稳定发布接口](https://api.github.com/repos/SagerNet/sing-box/releases/latest)、
[sing-box MT 美区商店](https://apps.apple.com/us/app/sing-box-mt/id6785326793)。
官方客户端说明页仍保留 App Store 暂停更新的旧提示，最新发布说明已明确 MT 重新上架；
此次以发布说明和实际商店页面交叉核对。旧 sing-box VT 用户需要安装新应用。
MT 的 1.14.4 不能直接当作内核版本，设备导入前核对其内置内核，不能仅凭应用编号声明配置兼容。
精确版本、核心源码提交及 Android arm64 APK 摘要记录在
[client-versions.json](../examples/1.14.0/client-versions.json)。其他 Android 架构使用该正式 release
对应的 APK 并核对对应摘要，不套用 arm64 摘要。Mac 继续由 Homebrew 管理客户端依赖。

## 共享内容与平台差异

继续使用同一台 VPS 的 SS2022、TCP 443、`2022-blake3-aes-128-gcm` 和现有私密密钥。
共享节点参数与分流意图，输出三个独立完整配置；不要求一个 JSON 在所有运行环境中原样适用。
首批共用现有单用户凭据，不新增按设备密钥轮换或订阅服务。

| 配置部分 | Mac | Android / iOS |
| --- | --- | --- |
| 出口与网卡 | 当前机器保留已验证 en4；其他 Mac 另选实际接口 | 不硬编码 en4、en0、wlan0 或蜂窝接口名；通过移动客户端的系统 VPN 实现处理出站和切网 |
| 防回环 | 保留已验收的自动接口保护 | 保留 auto_detect_interface=true，使拨号器进入平台保护路径；实机效果另行验证 |
| TUN | 现有 root CLI 与 launchd | Android VpnService / Apple NetworkExtension；按各端支持字段输出 |
| 本地域 DNS | 当前 dns-local 上游经 en4 的前提仍有效 | 去掉固定 en4 绑定，使用平台本地解析；局域网名称仅在所在网络具备记录时才预期可用 |
| 本地 mixed 与控制 API | 保留现有回环入口 | 只保留 TUN 入站；clash_api 仅有 default_mode=rule，无 HTTP 监听和 secret；模式控制使用应用 UI |
| 规则、缓存、日志 | 现有独立系统目录 | 使用应用管理的目录和日志，不复制 Mac 系统绝对路径 |
| 规则初始文件 | 当前运行目录已有 rules/*.srs | 不引用未随配置交付的 initial_path；验证无缓存时经 VPS 首次下载与后续缓存启动 |

移动端配置仍保留国内域名直连、其余普通 TCP 经 VPS、广告规则及本地域例外。
GeoIP 继续只补充已有真实 IP，不宣称覆盖未显式解析的 FakeIP 域名。
不要把所有私网目标排除出 TUN 以掩盖不可达问题；不存在真实路由时应失败，不能形成自循环。

官方说明：[Android 平台能力](https://sing-box.sagernet.org/clients/android/features/)、
[Apple 平台能力](https://sing-box.sagernet.org/clients/apple/features/)、
[Local DNS](https://sing-box.sagernet.org/configuration/dns/server/local/)、
[Route](https://sing-box.sagernet.org/configuration/route/)。
例如移动图形客户端不实现桌面 strict_route 的相同行为，iOS 常规客户端也不支持按进程匹配；
这些限制应反映在导出配置和验收中，不靠相同字段名推断相同行为。

1.14.0 的 [拨号器](https://github.com/SagerNet/sing-box/blob/v1.14.0/common/dialer/default.go)
在未显式绑定接口且启用 auto_detect_interface 时，通过
[NetworkManager.ProtectFunc](https://github.com/SagerNet/sing-box/blob/v1.14.0/route/network.go)
进入图形客户端的平台 socket 保护回调；
[OS 常量](https://github.com/SagerNet/sing-box/blob/v1.14.0/constant/os.go)将 Android 纳入 Linux、iOS 纳入 Darwin。
因此移动模板保留自动接口保护，不能只删除 en4。此结论来自精确版本源码，
不等于已经在目标应用证明 DNS 上游绕过 TUN、Pod 不可达时无回环或 Wi-Fi/蜂窝切换成功。

## 能力边界

当前代理传输仅支持 TCP。网页、普通 HTTPS 等是本批目标；未获前置直连规则放行的 UDP/ICMP 仍拒绝。
因此不能承诺移动游戏、语音视频通话或 QUIC/HTTP3 全部可用。补齐 UDP 是单独的服务端与客户端变更，
不通过移动端偷偷直连来冒充代理支持。

当前节点是 IPv4 地址，公网 IPv6 规则也有限制；需要在实际蜂窝网络（含 IPv6/NAT64 环境）验证到节点的可达性，
不能由 Wi-Fi 成功推断所有 4G/5G 网络都成功。移动端不依赖 Mac 开机或 SSH 转发，直接连接 VPS。

## 与第二批私密交接的衔接

先完成原计划的 SSH 私密取回，再从同一份私密输入按平台生成候选配置；
输出只允许安全新建、禁止覆盖，延续发布竞争、权限、host-key 和无秘密日志等既定测试。
移动设备通过私密文件导入完整 JSON，不要求向公网提供含密钥的订阅地址。
公开仓库只放测试地址/测试密钥的模板和脱敏验证记录。
生成成功不等于已经替换本机后台，也不能自动启动移动系统 VPN。

实际模板为 [macos](../examples/1.14.0/macos.example.json)、
[android](../examples/1.14.0/android.example.json)、[ios](../examples/1.14.0/ios.example.json)。
本批提供模板，尚未实现自动 SSH 取回或三端私密配置生成入口；现有 connect-vps.sh 仅生成自己的最小 SOCKS 配置。
Mac 使用匹配版本的 check，移动端还必须通过目标应用的导入/配置检查。
桌面内核语法检查不能替代移动平台能力与权限验证。

## 私密导入步骤

1. 从官方来源安装表中稳定应用。记录应用与内核版本；内核与 1.14.0 不一致时先核对兼容性并运行检查，
   不把预发布版或未知内核当作本批已验证对象。Mac 无需为查看模板更换现用程序。
2. 在自己控制的私密目录中新建对应模板的副本。Mac 上目录设为 0700、文件设为 0600，
   不覆盖已有配置，不放入 Git、公共网盘链接或在线 JSON 编辑器。
3. 用本地编辑器填写同一台 VPS 的真实 IPv4：同时替换 vps 出站的 server 和 VPS 直连规则的 /32；
   将 password 换成已有服务端的同一份 SS2022 密钥。不要重新生成服务端密钥，也不要把密钥放入命令参数或日志。
   Mac 另设随机管理 API secret，核对所选物理接口及 DNS 上游路径；手机不添加网卡名。
4. Mac 对私密候选执行对应版本 check，再按既有部署流程单独切换。手机通过本地文件传送导入完整 JSON，
   选择该配置、执行应用的配置检查，确认后再授予系统 VPN 权限并启动；不需要含密钥的公网订阅地址。
5. 手机首次启动不附带 SRS 初始文件，需要经 VPS 下载三份规则。下载失败时查应用日志，
   不删除分流规则或改成直连来绕过失败。确认缓存后，再验证断开/重连和应用重启。
   两端模板均使用应用工作目录内的 cache.db；应用实际缓存保留行为仍须实测。
6. 按下面清单验收，记录脱敏结果。保留原配置直到新配置验收；不同时运行两套系统 VPN。

这些模板中的公开地址和测试密钥不能用于真实访问。它们不包含按设备隔离的凭据；
撤销某台设备访问所需的轮换仍是后续工作。

## 实机验收

每个平台记录设备、OS、应用版本、内核版本、配置摘要与实际结果。Android 与 iOS 各覆盖：

1. 新安装、无规则缓存时导入和启动；现有两个 HTTPS 目标成功，出口为所选 VPS。
2. Wi-Fi 与蜂窝各自使用、双向切网、短时断网后恢复；确认不会意外改为公网直连。
3. 锁屏/后台后恢复，以及关闭 VPN 后正常联网与本地 DNS 恢复。
4. 当前网络的局域网访问、本地域名、不可达私网 UDP；观察无持续自循环和异常空闲耗电。
5. UDP/IPv6 的实际行为符合声明，额外 SOCKS/API 端口没有暴露到局域网。

Mac 按既有日用路径回归；移动验收不替代原计划的干净 VM 完整组合部署。
三端模板与检查已实现，实际命令、环境和退出码见 [验证记录](client-platforms-validation.md)。
Android/iOS 实机、首次规则下载、切网、锁屏、IPv6/NAT64 和本批 Mac TUN 回归：**NOT RUN**。
