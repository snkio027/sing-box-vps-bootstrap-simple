# 三端客户端模板验证

2026-09-13。本批只增加 Android/iOS 公开模板、版本记录、说明和测试，既有 Mac 与服务端 JSON 不变。
所有测试输入使用文档地址及公开测试密钥，不读取生产配置。没有连接真实 VPS、安装本机依赖或修改 Mac 网络。

## 可复现命令

在仓库根目录执行：

```sh
python3 -B tests/client_profiles_test.py
python3 -B tests/check_client_profiles.py --binary /path/to/sing-box-1.14.0
git diff --check
```

第一条检查三端公共策略和移动端限制，包含删除防回环保护、加入固定网卡、外部 API、未提供的规则文件、
启用 UDP/MUX、全局直连回退、排除私网及 UDP 旁路等负向案例。共 12 项测试。
这些是项目配置约束测试，不能替代 sing-box 解析器或证明 VPN 实际行为。

第二条要求精确 1.14.0，分别构建服务端、Mac、Android 和 iOS 配置，记录四次 check 的命令和退出码。
其 artifacts/client-profiles/summary.json 包含实际 OS/架构/Python、内核 version 输出，以及两份检查程序、
版本记录和四份 JSON 的 7 项 SHA-256。测试不调用 run，不下载规则或创建 TUN。
CI 仅上传该专用公开输入结果目录，不打包整个工作区。

## 本轮结果

- 本机：macOS 26.6.2 / Darwin 25.6.0、arm64、Python 3.9.6；12 项平台约束测试 PASS，exit 0。
- 本机 Bash 5.3.15 语法、ShellCheck、Python AST、修改文档的相对路径和 git diff --check：PASS，exit 0；
  既有 hardening-unit.sh 的 10 组检查 PASS，exit 0。
- 本机既有 client-unit.sh：exit 1，在前 8 组通过后因缺少 Homebrew 依赖停止；未把部分通过当作整套通过。
  不安装或升级本机依赖，完整客户端套件交给 macOS CI。
- 提交 `be373309a5e94e25748a17809d2ec298fca931b3` 的
  [CI 34752082076](https://github.com/snkio027/sing-box-vps-bootstrap-simple/actions/runs/34752082076)：
  static 与 mac-client 通过；macOS 完整 client-unit.sh 通过。
  该 CI 的四份配置构建检查全部 exit 0，使用 Homebrew sing-box 1.14.0 / Go 1.26.7、
  Darwin 25.6.0 arm64、Python 3.14.7。已下载 client-profiles 制品，核对全部 7 项源码摘要与该提交一致。
  原生检查未使用本机的 1.13.18 代替 1.14.0。
- Android / iOS 应用导入、VPN、无缓存启动、Wi-Fi/蜂窝切换、锁屏、退出恢复、局域网 DNS、
  不可达私网无回环、IPv6/NAT64：NOT RUN。
- 本批 Mac 完整 TUN 及真实 VPS 回归：NOT RUN；历史现网结论不作为移动端证据。
- 自动 SSH 私密取回、三端私密导出、干净 VM 完整组合部署：未实现 / NOT RUN。

仓库既有 Ubuntu 安装与加固 VM 回归仍按各 CI job 记账，不作为新增移动配置的运行证据。
手机内核版本尚未采集，特别是 iOS 的应用 1.14.4
不能用作内核 1.14.0 的证据。设备验收清单见 [客户端说明](client-platforms.md)。
