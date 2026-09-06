# Changelog

## 0.2.0 — 2026-09-06（开发中）

- 按用户追加要求，客户端改用 Homebrew 最新稳定依赖与 Homebrew Bash；移除固定客户端包下载和系统 Bash/plutil 依赖。

- 增加独立 Mac Bash 客户端：私密配置导入、回环 SOCKS5、物理网卡绑定和一次 HTTPS 检查。
- 用户现场输出确认服务端 AF_NETLINK 修复后服务运行并监听 TCP 443；Mac 链路尚待实测。

- 修复 systemd 地址族白名单遗漏 AF_NETLINK 导致的启动失败；支持失败后再次运行恢复启动。

- 按用户要求重建为一个 Bash 安装脚本，移除 Python 控制器和旧规范门禁。
- APT 更新/可选系统升级、条件 swap、固定 sing-box 二进制、私有配置和 systemd 服务。
- 保留基础备份、重复执行和隔离 VM 验证；真实 VPS/Mac 尚未运行。
- 下方 0.1.0 为历史设计，不是当前功能清单。

## 0.1.0 — 2026-09-04

- 建立 Ubuntu 24.04 / sing-box 1.14.0 / SS2022 TCP 443 设计基线。
- 定义失败关闭的 lifecycle、transaction、ownership、evidence 与退出码契约。
- 定义 SSH 两次 finalize、600 秒密钥轮换 fail-safe 和版本 hold/升级回滚。
- 固定 artifact size/redirect/payload/control，并在 unpack 前禁用包内 Polkit/D-Bus DNS 授权。
- 增加 controller release/runtime 绑定、恢复 runner identity 协议与 design-completeness gate。
- 固定 host resource policy、双端时间不确定性公式和官方 Darwin arm64 客户端 artifact trust anchor。
- 闭合 client export 的 desired-admin ownership、不覆盖传输和源端精确 unlink 语义。
- 将 20 次 smoke 与六 cell、每 variant 60 次的正式线路验收分离；闭合重测血缘与 MUX A/B 指标。
- 当前仅交付文档和规范；实现尚未开始。
