# 精简版验证

本轮是全新的 Bash 实现；旧 Python 控制器的 VM PASS 不替代本轮验证。

- Bash 语法：PASS。
- 本地函数/文件检查：7 项 PASS，包括固定制品、损坏与链接拒绝、SS2022 配置、密钥复用、非法输入。
- ShellCheck 0.11.0：PASS。
- 新版实际 Ubuntu VM 安装与 SS2022：NOT RUN。本环境无 QEMU/KVM；GitHub 连接拒绝写入，无法触发新版 CI。
- 真实 VPS：用户回报旧候选版在服务启动阶段 FAIL，错误为订阅路由更新时 address family not supported。
- 修复后真实 VPS 启动：用户提供输出确认 active (running)、enabled，sing-box 主进程拥有 0.0.0.0:443 监听。
  这是用户现场证据；本助手未连接 VPS。
- 真实 Mac 公网链路：NOT RUN。

复现命令见 README。VM 测试运行完整安装（含 --upgrade-system）、首次 swap、原密钥与进程保留、
实际 TCP 443 冲突、非 root 服务、经 SS2022 到本地 HTTPS 证书验证、错误密钥拒绝。
测试日志不含配置或密钥；凭据只存在于一次性 guest 的私有目录中。

尚未验证 arm64 实际安装、xfs 实际 swap、断电/重启及真实公网端到端链路。脚本不承诺一般性失败回滚。

初版来源：提交 `1c2cb4dae0052edd4580bfceaf5551b4e5f14205`。本次在 `6880574` 上修复 AF_NETLINK 遗漏；
修复版本重新通过 Bash 语法、ShellCheck 0.11.0 和 7 项本地检查。
终端推送缺少凭证，GitHub 连接创建 tree 返回 403（Resource not accessible by integration）；
本轮未推送、未创建 PR、未修改远端 main。下载包是开发候选版本，不是 VM 验收版本。

## AF_NETLINK 启动故障修复

旧 unit 的 RestrictAddressFamilies 未包含 AF_NETLINK，阻止了 Linux NETLINK_ROUTE socket，
导致 sing-box 启动时无法订阅路由变化。sing-box check 的配置校验不会覆盖该 systemd 运行环境。
修复增加这一地址族，保留非 root 账号与原有 capability；启动失败后的再次运行会先 reset-failed。

新增 VM 回归会故意移除 AF_NETLINK，验证同一错误，再执行安装脚本验证服务恢复且密钥不变。
该回归目前 NOT RUN。本地环境直接创建 NETLINK_ROUTE socket 返回 EPERM，不能在此验证成功路径；
未绕过环境限制。以上结论区分用户提供的失败事实、本地静态检查和仍待执行的运行验证。

## 配套 Mac 客户端

用户追加要求所有客户端项目依赖使用最新稳定版。已替换首次草案中的系统 Bash/plutil 与固定
Darwin 下载逻辑，改用当前 Homebrew Bash、curl、jq、OpenSSL、sing-box。
脚本核对 Homebrew Bash 路径/版本及过期依赖；准备命令负责刷新、安装和升级。

本地语法、ShellCheck 0.11.0、10 项客户端逻辑检查 PASS；真实 jq 解析参与检查。
本地环境为 Linux Bash 5.2.21、jq 1.7、OpenSSL 3.0.13，不能代表最新 Homebrew 组合。
最新依赖组合、真实 Mac 启动/绑定及公网链路仍为 NOT RUN。Mac CI 已配置但尚未运行。

历史固定包大小/SHA 与最低 macOS 26 的检查已完成，但不再用于当前客户端安装。
当前客户端开发基线 `d117141`；脚本 SHA-256：
`ca3c310235d4e7b62979c80926e12da97dea39ed34e00b79c9204b7a01a0762f`。
使用方法与依赖版本快照见 [客户端说明](mac-client.md)。
