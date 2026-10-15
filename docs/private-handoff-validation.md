# 私密交接与干净 VM 组合验证

本批从 `main@cfe2351` 开始，新增独立取回入口，保留 SS2022、物理网卡绑定、手动导入和独立客户端。
仅新增一个干净 VM 测试，不引入部署控制器、后台自动替换或三端配置分发。

## 检查命令

```sh
for f in scripts/*.sh tests/*.sh; do bash -n "$f"; done
shellcheck -x scripts/*.sh tests/*.sh
python3 -B tests/fetch_test.py
bash tests/client-unit.sh
bash tests/handoff-unit.sh
sudo python3 -B tests/run_deployment_vm.py
```

Mac 使用 Homebrew Bash；当前本机未安装 Homebrew sing-box，完整客户端组件测试交由 Mac CI。
新测试覆盖排他发布（竞争文件、目录、链接）、传输中断、SSH 失败、host-key 记录、权限、非法/非规范密钥、
OpenSSH 实际参数展开以及重复 setup 保留 inode。已有客户端测试增加错误/重复出口字段拒绝。

## 组合测试边界

一台全新 Ubuntu 24.04 amd64 KVM VM，1 GiB RAM / 20 GiB 磁盘，默认 ssh.socket：
prepare → 新管理员 SSH/sudo → apply → prepare-vps → 私密取回 → setup → HTTPS → 重复全流程 → 一次受控重启。
使用临时密钥、由 VM 输出通道固定的主机公钥以及 guest 回环 TLS origin，未禁用 SSH/TLS 验证。

取回运行真实 OpenSSH、sudo、共享锁、生产投影/校验和排他发布。外部 Linux 测试包装仅适配 Mac
依赖、stat、网卡查询与 QEMU 回环端口映射。导入运行真实 setup；客户端运行候选的服务器地址/端口和网卡
改为测试转发及 lo，curl 对原固定域名使用合成 CA 与 connect-to，TLS 主机名仍校验。
HTTPS origin 只在 guest 回环可达并回报实际 peer，错误 SS2022 密钥必须失败。
因此它验证干净 VM 的完整 SS2022 组合流程，**不证明 Mac en4、真实公网出口或现用 TUN 切换**。

## 执行结果

2026-10-16 核对实现提交 `e3e1409087ed78966686327d0b80db11f7e00d0e`：
[CI 38789768607](https://github.com/snkio027/sing-box-vps-bootstrap-simple/actions/runs/38789768607)
七项任务全部成功；[脱敏证据](evidence/private-handoff-20261016.json) 保存环境、退出码、断言与源码摘要。
后续报告提交只修改文档，不改变本次执行的脚本、测试和 workflow。

| 检查 | 环境 / 命令 | 结果 |
| --- | --- | --- |
| 本地聚焦测试 | Darwin 25.6 arm64、Python 3.9.6、Bash 5.3.20；下列本地命令 | 48 项／组，exit 0 |
| 语法与 ShellCheck | 同上，ShellCheck 0.11.0；上列语法与静态命令 | exit 0 |
| CI 静态 | Ubuntu 24.04 runner；workflow 中九套测试 | 67 项／组，exit 0 |
| 原安装与协议维护 VM | `sudo python3 -B tests/run_vm.py` | 22 项断言，exit 0 |
| SSH socket / service 加固 VM | `sudo python3 -B tests/run_hardening_vm.py --ssh-mode socket` / `--ssh-mode service` | 20 / 19 项，exit 0 |
| 初始无 UFW VM | `sudo python3 -B tests/run_hardening_vm.py --ssh-mode socket --scenario without-ufw` | 16 项，exit 0 |
| 新完整部署 VM | `sudo python3 -B tests/run_deployment_vm.py` | 15 项，exit 0；一次受控重启 |
| Mac 配置检查 | macOS 26 arm64；`tests/check_client_profiles.py`，分别指定已审查 1.14.2 / Homebrew 1.14.3 | 各四份配置，全部 exit 0；未启动 TUN |
| 制品与源码一致性 | 下载五份 VM 和两份 Mac summary，逐条 SHA-256 与该提交比对 | 35 条全部相同；VM 共 92 项断言 |

所有 VM 均为 Ubuntu 24.04 amd64、KVM、1 GiB RAM / 20 GiB 磁盘；新组合 VM 使用 ssh.socket。
新流程证明：新管理员 SSH/sudo、收紧后新连接、安装、SS2022 私密取回、setup 与真实协议 HTTPS 成功；
重复流程保留密钥、账号和防火墙，健康代理 PID 不变，重复导入保持配置 inode；重启后同组服务与链路再通过。
重启等待期间一次 SSH exit 255 属于有界探测，随后新 boot ID、新连接和最终命令均通过。

负向实跑覆盖错误 host key、有效载荷后 SSH 非零、无 sudo 权限、安装未完成、独占锁竞争及错误 SS2022 密钥。
单元测试另覆盖已有输出、发布竞争、软/硬链接边界、传输中断、非规范密钥及错误/重复出口字段。
重启后先证明 `/run/lock/sing-box-install.lock` 不存在，再验证取回安全创建 root 0600、单链接、零字节锁。

本地 48 项／组的可复现命令（从仓库根目录）：

```sh
python3 -B tests/fetch_test.py
python3 -B tests/client_profiles_test.py
python3 -B tests/reality_profiles_test.py
python3 -B tests/profile_check_test.py
/opt/homebrew/bin/bash tests/handoff-unit.sh
/opt/homebrew/bin/bash tests/hardening-unit.sh
/opt/homebrew/bin/bash -c 'jq() { /opt/homebrew/bin/jq "$@"; }; source tests/maintenance-unit.sh'
```

本机另用 `/opt/sing-box/1.14.2/sing-box` 执行四份公开候选的 `check`，全部 exit 0；未启动服务。
本机未安装 Homebrew sing-box，因此完整 `tests/client-unit.sh` 由 Mac CI 和 Linux CI 执行，不能记作本地运行。
CI 的实际命令和依赖准备见 [workflow](../.github/workflows/test.yml)。

首轮 `d528cf7` / [CI 38788210144](https://github.com/snkio027/sing-box-vps-bootstrap-simple/actions/runs/38788210144)：
静态、Mac 和原安装 VM 已通过，新组合 VM 完成取回、HTTPS、重复执行，在重启后的再次取回失败。
原因是 `/run` 锁不跨重启保留；修订为只安全重建零字节运行时锁后，以上最终版本重新实跑通过。
首轮失败未记为完整部署 PASS。

真实 VPS、Mac en4 / 公网出口、现用 TUN／后台切换及手机：**NOT RUN**。
REALITY 自动取回与多平台私密配置生成：**未实现**。本批不合并 PR、不操作现网。
