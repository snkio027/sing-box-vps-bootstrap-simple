# Mac TUN 通用防回环修复与验证

未显式绑定接口的 `local-direct` 曾将 UDP 再次送入自身 TUN，形成持续转发和异常 CPU 占用。
本次仅设置 `route.auto_detect_interface=true`；VPS 的显式 `bind_interface=en4` 保持不变。
现场用于短暂止血的两个 Pod `/32` 拒绝规则已移除，公开配置不依赖具体 Pod IP。

这项设置为未显式绑定的出站提供接口保护，但不会创建容器或私网路由。
不可达目标应失败或超时；本次不能判定 Pod 配置错误，也没有证明 sing-box 程序存在缺陷。
依据：[1.14.0 路由说明](https://github.com/SagerNet/sing-box/blob/v1.14.0/docs/configuration/route/index.md#auto_detect_interface)、
[接口选择实现](https://github.com/SagerNet/sing-box/blob/v1.14.0/route/network.go)、
[出站绑定优先级](https://github.com/SagerNet/sing-box/blob/v1.14.0/common/dialer/default.go)。

## 范围与环境

基线提交 `12963a7bb3dc243ec43ce4047ca72f06b0a9ff73`；现场于 2026-09-06 在 Apple Silicon、
macOS 26.6.2、固定 sing-box 1.14.0 上执行。结果汇总见
[脱敏证据](evidence/macos-auto-interface-20260906.json)。

现场运行的是私密生产配置，另有固定日志路径和回环 7890 兼容入口。
本次改动与公开样例相同，但没有使用示例地址或公开测试密钥联网。
原始配置、目标、API 响应、日志及一次性管理员脚本保持私密；此记录只公开审核需要的汇总值。
未执行 VPS 变更、容器变更、TCP 调参、DNS 或系统代理设置变更。

## 结果

| 项目 | 结论 |
| --- | --- |
| 自身 UDP 循环 | 原 2,075 条循环会话归零；换目标后未复发，现场验证通过 |
| CPU | 未主动测速时从约 180% 降到约 0.6%；100% 为一个逻辑核，两个采样窗口长度不同 |
| 有界负向探测 | 原两个目标、另一个 Pod及额外私网目标，共 8 个 UDP 数据报、2 个 TCP 探测；没有自有 socket 回流 |
| UDP 实际出口 | 观测接口为 en4，没有进入当前 utun |
| 本地访问 | 经 SOCKS 的本机回环、已有容器桥和 OrbStack 域名 HTTP 均返回 200 与预期正文 |
| TUN / SOCKS HTTPS | Apple、Cloudflare 均 HTTP 200、TLS 验证结果 0、无重定向、标记正确；出口为预期 VPS |
| 进程与系统设置 | 16 项断言全部通过，验证程序 exit 0；期间 PID 稳定，DNS、系统代理和 plist 未变 |
| 下载速度与稳定性 | 仍有波动，原因未定位；不属于本次防回环验收通过的结论 |
| 新配置整机重启、完整 Pod 业务网络、其他 VPN / 网卡切换 | NOT RUN |

循环判据同时使用管理 API 的 TUN 入站源地址/端口、`netstat` 中 sing-box 自有 UDP socket，
以及目标路由。仅看一个 TUN 地址或一个失败请求不足以认定循环。
CPU 使用两次进程累计 CPU 时间之差除以墙钟时间；应用后台流量仍可能存在。

修复前相同的三次 10 MB SOCKS 下载为 60.50、7.67、14.87 Mbps；修复后为
55.97、61.41、12.63 Mbps。均完整下载，curl exit 0、HTTP 200、TLS 验证通过、无重定向。
这是先后实验，不能据此精确量化性能收益。SSH 交替对照另行记录，不阻塞本次独立修复审核。

## 检查命令与证据边界

在本仓库根目录运行的公开样例检查不启动 TUN，也不连接示例服务器：

```sh
/opt/sing-box/1.14.0/sing-box version
/opt/sing-box/1.14.0/sing-box check -D "$PWD/examples/1.14.0" -c "$PWD/examples/1.14.0/macos.example.json"
git diff --check
```

以上配置检查及 diff 检查本次均 exit 0。这只是静态检查，不替代现场结果。

现场使用 `/usr/bin/python3` 执行一次性私密验证程序，exit 0。程序调用
`launchctl print system/org.sing-box`、`ps`、`netstat -anv -p udp`、
`route -n get <private-target>`、`nettop -m udp`、只读且鉴权的回环管理 API，以及少量 UDP/TCP/HTTPS 探测。
HTTPS 使用 `/usr/bin/curl -q`，关闭环境代理干扰，连接超时 5 秒、总超时 15 秒、响应上限 4096 字节，
正常验证 TLS且不跟随重定向。完整私密命令及原始数据由操作者保留，没有将这个一次性验证程序
作为仓库通用测试入口发布；公开汇总不等同于第三方已独立复跑。

该现场结果已经用户按防回环范围验收，提交差异仍待独立审查。现有 CI 会检查配置和原有脚本；
CI 不启动真实 Mac TUN，也不连接真实 VPS，因此不能将 CI 通过写成现场兼容性通过。
