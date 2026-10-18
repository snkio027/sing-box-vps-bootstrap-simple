# Mac 日用配置的网络切换

2026-10-19，从 `main@b1dc563` 开始。本批只修改仓库候选与测试，不改现用 JSON、launchd、
路由、DNS、系统代理或 Wi-Fi 设置，不连接真实 VPS。1.14.0 历史目录及手机配置保留。

## 问题与最小修改

本机只读查询得到：Wi-Fi 设备为 `en0`，默认接口为 `en0`，`en4` 不存在。
这是接口状态快照，没有读取或宣称核对过当前 root-only 私密配置。
仓库 `examples/1.14.2/macos.example.json` 则有五处 `bind_interface=en4`：

| 绑定位置 | 固定接口不可用时受影响的路径 |
| --- | --- |
| SS2022 / REALITY 出站 | 两种协议到 VPS 的新连接；规则下载与代理 DNS 也依赖 VPS |
| direct 出站 | 国内直连及显式路由到 direct 的公网连接 |
| dns-direct | 国内 DoH 查询 |
| dns-local | 由 sing-box 自行发往系统 DNS 上游的查询；不代表所有本地解析都走同一路径 |

已有 `auto_detect_interface=true` 不会覆盖显式绑定。将 en4 机械替换成 en0 仍会固定在 Wi-Fi，
再次更换出口时还需改文件。[官方优先级](https://sing-box.sagernet.org/configuration/route/#auto_detect_interface)
与 [1.14.2 拨号器](https://github.com/SagerNet/sing-box/blob/v1.14.2/common/dialer/default.go) 支持这一判断。

最小方案只删除上述五个字段，保留 `route.auto_detect_interface=true`，不设置 `default_interface`
或固定源地址。`local-direct` 继续使用自动接口保护；不恢复成无保护的系统路由直连。
分流、DNS 规则、广告规则、两个协议、凭据、缓存、端口和 MUX 策略均不改变。
不增加网络监控脚本、定时重启或自动直连回退，不将旧的不可达 Pod 地址写进规则。

`connect-vps.sh` 与 `fetch-vps-config.sh` 是有意选定物理网卡的诊断／取回入口，仍保持其已审查边界。
Wi-Fi 下须明确提供正确接口；它们不会更新日用 TUN 配置，也不能代替切网验收。

## DNS 与恢复边界

1.14.2 的 `dns-local` 通过共用拨号器发出非系统代发的上游查询；移除局部绑定后仍由全局自动接口保护处理。
`prefer_go=false` 并不是“所有查询由 macOS 代发”的保证。网络更新路径会重置连接，local DNS 的 Reset
会重置其系统配置来源。因此优先使用内核已有机制，不在外部重复维护网卡与 DNS 列表。
依据：[local transport](https://github.com/SagerNet/sing-box/blob/v1.14.2/dns/transport/local/local.go)、
[上游查询](https://github.com/SagerNet/sing-box/blob/v1.14.2/dns/transport/local/local_shared.go)、
[默认接口与网络更新](https://github.com/SagerNet/sing-box/blob/v1.14.2/route/network.go)。
这属于源码依据，尚不证明本机 Wi-Fi 事件、系统 DNS 变化与 TUN 组合已通过实测。

切网可能关闭旧 TCP 连接，应用需要重新连接；本方案不承诺已建立的 TCP 无损迁移。
目标是新连接随当前默认出口恢复，并继续经所选 VPS 协议。局域网记录须由当前网络的真实解析器提供；
新 Wi-Fi 没有旧内网记录时应解析失败，不使用公网 DNS 冒充局域网兜底。
仅 IPv6/NAT64 网络、多个 VPN 同时运行、跨网访问旧局域网和所有容器业务不在本批保证范围。

## 回归检查

```sh
python3 -B tests/client_profiles_test.py
python3 -B tests/reality_profiles_test.py
python3 -B tests/check_client_profiles.py --binary /opt/sing-box/1.14.2/sing-box --mode reviewed --output /tmp/mac-interface-check
```

前两组验证历史／手机策略仍然成立，现版 Mac 拒绝逐个出站或 DNS 的固定网卡、固定源地址、全局固定接口、
关闭自动保护及重新引入旧五处绑定。新配置除五处删除外与原 JSON 完全一致。
原生 `check` 只做配置构造，不启动 TUN。CI 另对 Homebrew 当前稳定内核执行同样四份公开配置检查。

曾尝试以“绑定不存在网卡的回环请求应失败”为对照，实际未失败；该尝试不能记作切网验证通过。
当前核心依赖会对回环等虚拟目的地址跳过绑定，故回环 HTTPS 不能证明物理网卡选择正确；
没有将这一无效判据加入 CI。[对应绑定实现](https://github.com/SagerNet/sing/blob/87c33f17688f/common/control/bind.go)

本地环境 Darwin 25.6 arm64、Python 3.15.0、已按记录核对大小与 SHA-256 的 sing-box 1.14.2。
上述两组测试 **12 + 6 项通过，exit 0**；四份原生配置检查 **exit 0**。
另用 `b1dc563` 的原版 Mac JSON 作反向对照，新检查器准确拒绝；结构比较确认只删除五个绑定字段。
[本地脱敏证据](evidence/mac-interface-candidate-20261019.json) 绑定八份输入/测试文件摘要。
CI 结果以包含此候选的 PR 同提交检查为准；CI 原安装 VM 的成功不等于 Mac 切网成功。
真实切网、DNS 上游更新、完整 TUN、OrbStack 与退出恢复：**NOT RUN**。

## 后续现场验收清单（本轮不执行）

先保存当前配置和启动项，核对对应版本的候选 `check`，安排可接受短时断网的操作窗口；
仅修改相同五处绑定，不更新程序、密钥或其他策略。出现循环或不能恢复时还原备份并重新验证旧链路。

1. 在起始网络记录默认接口、系统 DNS 上游、服务 PID、空闲 CPU 和循环会话基线。
2. 从有线切换 Wi-Fi，确认操作系统默认接口确实改变。分别选择 SS2022 和 REALITY，
   用新连接验证 TUN／SOCKS 的两项既定 HTTPS 目标、TLS、状态与 VPS 出口；用 nettop 确认实际新出口。
   旧连接中断单独记录，不把自动 TCP 迁移作为通过条件。
3. 更换另一个 Wi-Fi（即使仍叫 en0）并验证系统 DNS 已更新；测试当前网络中已知存在的本地域名、
   已有 OrbStack 域名，以及不可达私网目标不会形成自循环。旧局域网资源不可达不算自动接口故障。
4. 短时断网再恢复、恢复原有线网络，重复新连接与 DNS 验证；确认无持续重试回环、空闲 CPU 异常或意外公网直连。
5. 验证停止测试／恢复原服务后的网络可用性。记录版本、网络转换、命令、退出码、恢复时间与失败场景，
   不公开地址、密钥、SSID、系统 DNS 地址或原始私密报告。

只有这些对应路径通过后，才将相应现场项改为 PASS。现有 VM 安装、手机或静态检查不能替代它们。
