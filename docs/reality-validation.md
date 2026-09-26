# 1.14.2 / REALITY 验证记录

2026-09-26，开发中。本页不继承 1.14.0 的真实设备 PASS。

已在 macOS arm64 完成：三份官方归档 SHA-256 与发布 API 一致，提取后记录内层程序大小/摘要；
1.14.2 原生程序执行四份公开配置 `check`，均 exit 0；5 组维护纯函数测试和 3 项新平台策略测试通过。
完整结果在提交/CI 后补充。旧客户端组件测试的前 8 项通过，后续依赖检查因本机未安装 Homebrew sing-box
而停止（exit 1）；不为了测试安装另一套本机程序，完整入口由 Mac CI 验证。

```sh
bash tests/maintenance-unit.sh
python3 -B tests/reality_profiles_test.py
python3 -B tests/check_client_profiles.py --binary /path/to/verified-1.14.2/sing-box
shellcheck -x scripts/*.sh tests/*.sh
```

VM 驱动使用明确 allowlist；仅导出断言、命令结果及源文件摘要，不导出配置、合成凭据或整台虚拟机磁盘。
新增路径：1.14.0 → 1.14.2 升级、发布后 TERM 恢复、pending 拒绝重试、回环端口冲突、REALITY HTTPS、
错误 UUID/short ID、SS2022 并存和重复运行；加固 VM 增加 8443 放行与后续 apply/重启保持检查。
本地未运行 Linux root 单元或完整 VM，由本分支 CI 实跑后记录结果。

真实 VPS 升级、新协议公网握手、Mac 后台升级/切换、Android/iOS 实机：**NOT RUN**。
