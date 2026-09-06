# 注释与独立建仓记录

日期：2026-09-06。精简版单独建立 `sing-box-vps-bootstrap-simple` 仓库；后续工作以本仓库为主目录。
原始文件快照提交：`7d9ad6ed3f70054720e264e2aee25281b322f18c`。

## 改动范围

- 服务端入口新增 71 行注释/空行：安装阶段、固定制品、路径与权限、密钥复用、单文件原子发布、
  swap 中断边界、systemd 沙箱与本机验证范围。
- Mac 入口新增 57 行注释/空行：私密导入、依赖来源、网卡绑定、独占回环端口、HTTPS 验证与子进程清理。
- 五个测试脚本新增 51 行注释：合成数据、平台适配、负向用例、一次性 VM 的修改范围及证据限制。
- README、工作约定和历史链接调整为独立仓库；忽略 macOS `.DS_Store`。

七个脚本的差异只包含新增注释/空行。检查保留 shell heredoc 原文后，可执行内容逐字节一致；
两个 Python 文件去除行号后的 AST 一致。未改 CLI、依赖版本、配置模板、权限、网络或清理行为。

| 入口 | 注释版 SHA-256 |
| --- | --- |
| `scripts/prepare-vps.sh` | `0dff75e5a441e246f04dd9957b5a0720029dbfadf4ab3a3e8311017f2476bb3b` |
| `scripts/connect-vps.sh` | `f3186e1469e993bb272703d89d946a223a9834e98d6ac06dfb74b602dc50a1b5` |

## 本机检查

环境：macOS 26.6.2 / arm64、Homebrew Bash 5.3.15、ShellCheck 0.11.0、Python 3.14.7。
在仓库根目录执行：

```bash
for script in scripts/*.sh tests/*.sh; do /opt/homebrew/bin/bash -n "$script" || exit; done
/opt/homebrew/bin/shellcheck -x scripts/*.sh tests/*.sh
/opt/homebrew/bin/bash tests/client-unit.sh
git diff --check 7d9ad6ed3f70054720e264e2aee25281b322f18c
```

| 检查 | 结果 |
| --- | --- |
| 五个 Shell 文件语法 | PASS，exit 0 |
| ShellCheck | PASS，exit 0 |
| 七个脚本仅新增注释；heredoc/可执行内容与 Python AST 比较 | PASS，exit 0 |
| 两个 Python 文件编译检查 | PASS，exit 0；未执行 VM runner |
| Mac 客户端单元测试 | 前 8 项通过；缺少 Homebrew sing-box，完整命令 exit 1 |
| Linux root 单元测试、一次性 VM 安装与协议测试 | 本机 NOT RUN；由新仓库 CI 执行 |

本轮没有为了注释检查安装或升级本机依赖。部分测试通过不代表完整套件通过。
CI 的实时结果以当前提交对应的 GitHub Actions 为准，不能用旧控制器的测试替代。

## 已有真实链路证据的范围

2026-09-06，操作者授权后，以私密 SSH 只读检查确认服务端进程、固定二进制、配置权限、
TCP 443 监听及时间同步等 11 项检查通过，exit 0。
另用官方校验过的独立 sing-box 1.14.0 临时客户端，MUX 关闭并实际验证 en4 出接口：
Apple、Cloudflare 两项 SS2022 HTTPS 请求及前后四项直连对照均为 HTTP 200，TLS 与响应标记通过，
整次命令 exit 0。测试前后已有代理进程、系统代理、DNS、默认路由和物理网卡观测一致；临时进程、
密钥配置已清理。

这证明当时的真实链路连通性；不是 `connect-vps.sh` 的完整 Homebrew 流程验收，也不是本注释版的
VM 安装、断电恢复、吞吐或长期稳定性测试。真实地址、账号、凭据及原始报告只留在操作者本机，
不进入本仓库或 CI 制品。此前候选版记录见 [历史验证记录](validation.md)。
