# 1.14.2 / REALITY 验证记录

2026-09-26。实现提交 `e58376c11a2b1bdc6e185d43dba4049739a159e6` 的
[六项 CI](https://github.com/snkio027/sing-box-vps-bootstrap-simple/actions/runs/36248531505) 全部通过。
四份 VM 报告与 Mac 报告的源码摘要均已对照本地文件核验；后续本次报告提交仅补充文档/脱敏摘要。
[机器可读脱敏汇总](evidence/reality-upgrade-1.14.2.json) 不包含配置、实际地址或凭据。

| 环境/场景 | 实际结果 |
| --- | --- |
| 静态 Ubuntu CI | Bash 语法、ShellCheck、原安装/客户端/加固测试、新维护测试及两套平台策略测试通过 |
| Mac CI Darwin 25.6.0 arm64 / Python 3.14.7 | Homebrew sing-box 1.14.2；server、macos、android、ios 四份原生 check 均 exit 0，7 个源码摘要匹配；最小客户端组件检查通过 |
| Ubuntu 24.04 amd64 KVM，1 GiB / 20 GiB 安装与维护 VM | 18 项断言，exit 0，5 个源码摘要匹配 |
| 同规格 SSH socket 模式 VM | 20 项断言，exit 0，3 个源码摘要匹配 |
| 同规格 SSH service 模式 VM | 19 项断言，exit 0，3 个源码摘要匹配 |
| 同规格初始无 UFW VM | 16 项断言，exit 0，3 个源码摘要匹配 |

合计 **73 项 VM 断言**。新路径涵盖精确官方 1.14.0 → 1.14.2 升级、二进制发布后 TERM 恢复、
配置与密钥保留、重复升级 PID 不变、pending 阻止盲目重试、真实回环端口冲突、REALITY 配置发布后 TERM 恢复、
真实 VLESS + REALITY + Vision HTTPS、错误 UUID/short ID 拒绝、原 SS2022 HTTPS 并存、双协议重复执行、
旧单协议安装器拒绝覆盖，以及凭据不出现在维护输出中。

加固 VM 还覆盖增加 8443 后中断、旧规则恢复和新 SSH 连接，随后正确重试、重复放行、重复 apply，
以及受控 VM 重启后的 SSH/防火墙持久化。真实 VPS 未在该流程中出现。
升级 VM 由新装后的相同 unit/config 配合校验过的 1.14.0 程序启动，再调用真实维护入口升级；
这不等于重新运行一遍历史 1.14.0 安装器。握手目标与 HTTPS origin 都是 guest 内合成服务。

## 复现命令

Linux CI / 一次性测试环境：

```sh
for script in scripts/*.sh tests/*.sh; do bash -n "$script"; done
shellcheck -x scripts/*.sh tests/*.sh
sudo bash tests/unit.sh
bash tests/client-unit.sh
bash tests/hardening-unit.sh
bash tests/maintenance-unit.sh
python3 -B tests/client_profiles_test.py
python3 -B tests/reality_profiles_test.py
sudo python3 -B tests/run_vm.py
sudo python3 -B tests/run_hardening_vm.py --ssh-mode socket --scenario standard
sudo python3 -B tests/run_hardening_vm.py --ssh-mode service --scenario standard
sudo python3 -B tests/run_hardening_vm.py --ssh-mode socket --scenario without-ufw
```

Mac 只检查配置，不启动 TUN：

```sh
python3 -B tests/check_client_profiles.py --binary /path/to/verified-1.14.2/sing-box
```

VM 驱动使用明确 allowlist，导出断言、命令结果及源文件摘要，不导出配置、凭据或整台虚拟机磁盘。
本机另外完成三份官方归档与发布摘要核对，提取后记录内层程序大小/摘要；5 组维护函数、12 项原平台策略、
3 项新协议策略、ShellCheck 和四份原生配置检查均 exit 0。一次独立 Mac 回环实验也完成 REALITY HTTPS，
只作为辅助证据，正式可复现的运行路径以上述 VM 为准。
本机旧客户端测试前 8 项通过，后续因 Homebrew sing-box 缺失返回 exit 1；没有为此安装另一套本机程序。
完整依赖环境的成功证据来自 Mac CI，不能将本机该次返回码改写为 PASS。

## 已发现并修复

首轮 `763aa17` 的 VM 未通过：维护暂存使用 /run，包和候选程序超过 1 GiB VM 的 tmpfs 容量；
新增端口调用的备份函数跳过已加固主机。`e58376c` 改为磁盘暂存并检查空间，强制保存当前启用状态的
UFW 基线。故障测试同时要求已执行文件恢复，避免把发布前失败误计为发布后恢复；修正后的 VM 全部重跑通过。

真实 VPS 升级/新协议公网握手、Mac 后台升级/切换、Android/iOS 实机、Linux arm64 实际安装及任意断电恢复：
**NOT RUN**。本页不继承 1.14.0 的真实设备 PASS，也不作速度或抗识别效果的验收声明。
