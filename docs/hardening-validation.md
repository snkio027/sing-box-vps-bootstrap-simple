# 主机初始化验证

本页只记录 `harden-vps.sh`，不把此前手工加固的真实 VPS 证据冒充新入口实测。

## 2026-09-09 复审修订

`8255939` 复审发现跨来源 SSH Match 例外未被拒绝，以及初始没有 UFW 时缺少恢复文件。
下方旧 CI 证据只覆盖当时的用例，不代表这两条路径通过；本次修复已在 `d000432` 针对性复审中通过，P1、P2 闭合。

- SSH v1 限定为单层标准 Include 和全局配置，拒绝任何 Match、嵌套/额外 Include。
  10 组本地测试已通过（Bash/ShellCheck/单元测试 exit 0）。
- UFW 在依赖安装后、首次修改前单独保存四份恢复文件、摘要、包版本和阶段说明，安装前记录仍保留。
- VM 增加真实 sshd 的跨来源反例和嵌套 Include 拒绝用例；独立 `without-ufw` 场景在任何脚本调用前
  用 dpkg purge 构造并核对包及四份文件均不存在，第一次 apply 即注入 UFW 后中断。
  该场景恢复后保留依赖包，继续验证重试、重复执行和重启，不复用标准场景提前安装依赖的状态。

首轮修订 `23489ab` 的独立 `without-ufw` VM 通过 14 组断言（exit 0）；两套标准 VM
停在新增反例的构造阶段，尚未执行本轮 SSH 拒绝断言，不能计为通过。
Ubuntu OpenSSH 9.6 在已有全局 `AuthenticationMethods publickey` 后解析 Match 内的 `any` 时
报 `"any" must appear alone`（sshd exit 255）。这与[该版本解析实现](https://github.com/openssh/openssh-portable/blob/V_9_6_P1/servconf.c#L2308)
一致；用例改为显式的 `AuthenticationMethods password`，继续要求真实语法通过、当前来源关闭认证、
另一来源允许 root 密码认证。没有放宽生产检查或忽略失败。
[首轮 CI 与失败制品](https://github.com/snkio027/sing-box-vps-bootstrap-simple/actions/runs/34348174852)保留原始结果。

本轮测试提交：[7a61f63](https://github.com/snkio027/sing-box-vps-bootstrap-simple/commit/7a61f63c9433830a840a82b22af8593c2f6f1f23)。
[CI 六个任务全部通过](https://github.com/snkio027/sing-box-vps-bootstrap-simple/actions/runs/34348853016)，
包括静态、Mac 配置、原安装器 VM 和下列三套加固 VM。

| 加固 VM | 断言组 | SSH 命令记录 | 驱动退出码 |
| --- | ---: | ---: | ---: |
| 默认 ssh.socket，standard | 18 | 77 | 0 |
| ssh.service，standard | 17 | 74 | 0 |
| 默认 ssh.socket，without-ufw | 14 | 61 | 0 |

三套共 49 组断言、212 条 SSH 命令记录。每台 VM 安排两次受控重启，共 **6 次重启**；
加上三台 VM 的初始开机，共 9 次启动。该测试提交的记录另含 **9 条重启轮询期间的短暂 exit 255**，
这是断连记录条数，不是重启次数。其余退出码全部符合预期；包括布局拒绝的 exit 1、UFW 后 TERM 的 exit 143 和禁止认证的 exit 255。
环境为 Ubuntu 24.04.4 amd64、KVM、1 GiB / 20 GiB、2 vCPU，初始内核 6.8.0-138-generic，
Bash 5.2.21、Python 3.12.3。本轮未操作真实 VPS 或本机网络。

- 两套标准 VM 中，真实 `sshd -t/-T -C` 先证明当前来源的管理员/root 为关闭 root 和密码认证、
  仅 publickey；合成来源 `203.0.113.5` 则为允许 root、PasswordAuthentication yes、AuthenticationMethods password。
  加固入口对该配置及原生语法合法的嵌套 Include 均精确返回布局拒绝；防火墙摘要不变，尚未创建 apply 备份。
- 独立 VM 在任何脚本调用前以及首次 apply 前两次核对 UFW 包、命令和四份配置均不存在。
  第一次 apply 安装依赖、启用 UFW 后注入中断；顶层 absent-before 保留四个路径，
  安装后恢复基线的四份文件和摘要齐备。恢复配置并受控重启后保留 UFW 包，后续 apply、重复执行及最终重启均通过。
- 三套摘要共 9 项均与测试提交一致；后续验证文档提交不修改这些输入。

| 文件 | SHA-256 |
| --- | --- |
| `scripts/harden-vps.sh` | `6a102d5d4ced1c2090d8cafcc7c45a2d4f1d272de99639b3e5e30cd639e3b8f5` |
| `tests/run_hardening_vm.py` | `02c6c0ba981484d9975763730917002da0720b83c03cdb7da29a5b6d801f9425` |
| `tests/fixtures/ubuntu-cloud-image.json` | `24a98767febc0a76f6fe1012dee5180ebf72b6ed240bb3cadf6fae97f3a18e28` |

复现命令（在一次性 Linux 测试主机运行；实际命令和退出码在对应 CI 制品 `summary.json`）：

```sh
sudo python3 -B tests/run_hardening_vm.py --ssh-mode socket --scenario standard
sudo python3 -B tests/run_hardening_vm.py --ssh-mode service --scenario standard
sudo python3 -B tests/run_hardening_vm.py --ssh-mode socket --scenario without-ufw
```

制品分别为 `hardening-vm-socket`、`hardening-vm-service` 和 `hardening-vm-socket-without-ufw`，
保留 14 天。本轮修复实现与上述测试已完成；用户针对 `d000432` 的复审通过，允许合并。
该文档提交的[六项 CI 也全部成功](https://github.com/snkio027/sing-box-vps-bootstrap-simple/actions/runs/34349644277)。
真实 VPS 新入口、私密导出、完整组合部署和 arm64 VM 仍为 **NOT RUN**。

## 先前实现的测试记录

已验证的实现提交：[46bf541](https://github.com/snkio027/sing-box-vps-bootstrap-simple/commit/46bf541b67b5b42d6e88917b1db12714a649e1a0)。
[本轮 CI](https://github.com/snkio027/sing-box-vps-bootstrap-simple/actions/runs/34234154464) 的静态、Mac、原安装器 VM 和两套加固 VM 全部通过。
当时执行的测试通过；后续复审发现上面列出的覆盖缺口，不能作为第一批最终验收。

| 加固 VM | 断言组 | SSH 命令记录 | 驱动退出码 |
| --- | ---: | ---: | ---: |
| 默认 ssh.socket | 15 | 64 | 0 |
| ssh.service | 14 | 63 | 0 |

两套均为 Ubuntu 24.04.4 amd64、KVM、1 GiB / 20 GiB、2 vCPU；初始内核 6.8.0-138-generic，
Bash 5.2.21、Python 3.12.3。首次 apply 实际安装了安全更新并记录待重启；重复 apply 的包版本无变化。
账号、公钥、组和 UFW 规则保持不变。UFW 中断恢复及最终完成后各做一次明确安排的 VM 重启，
重新连接并检查 SSH、sudo、双栈防火墙和更新策略；轮询期间预期的短暂 SSH exit 255 单独保留。
两份汇总中 127 次 SSH 命令的其余退出码与预期一致，6 项源码摘要（每份 3 项）全部匹配下表。

本轮三个证据输入的 SHA-256：

| 文件 | SHA-256 |
| --- | --- |
| `scripts/harden-vps.sh` | `e818d91a59e7e8c1e203f52676a858238b019d747c8fc016c770a9a01106d91f` |
| `tests/run_hardening_vm.py` | `fe6f431f00bc6e64d4fdc5b30e8aee03c324a3087f4bd1517178d2644f2b211f` |
| `tests/fixtures/ubuntu-cloud-image.json` | `24a98767febc0a76f6fe1012dee5180ebf72b6ed240bb3cadf6fae97f3a18e28` |

2026-09-08：Bash 语法、ShellCheck 和 8 组本地参数/解析测试通过（macOS 26.6.2 arm64，Homebrew Bash，exit 0）。
命令：

```sh
bash -n scripts/harden-vps.sh
shellcheck -x scripts/harden-vps.sh tests/hardening-unit.sh
bash tests/hardening-unit.sh
```

CI 首轮 `bd9f321` 的默认 socket 和 service 两台 VM 都在启用 UFW 前停止：
实现误把包自带的非可执行初始化钩子视为未知文件。失败为 exit 1，未计为加固通过；
同轮原始日志保留在 CI，汇总上传还因测试输出目录权限失败。
后续改为比对受信包模板、拒绝修改过的控制文件，并仅对脱敏测试汇总开放读取权限。
该首轮的“未知防火墙”用例只检查失败退出码，未限定拒绝原因；后续补充精确错误断言，首轮不算该路径证据。

第二轮 `6a4b8db` 两个 VM 已通过精确的未知原生防火墙拒绝检查，但仍在首次 UFW 采用前停止：
空用户规则模板本身含有限流辅助链，不能把所有 `-A` 行都视为用户添加的规则。
改为完整比对包模板，另加真实自定义用户规则的拒绝与保留用例。该轮失败和诊断制品已保留。

第三轮 `495ad9a` 两个 VM 通过 UFW 后中断、新连接和备份文件恢复；恢复后重新 apply 在
原生防火墙检查处 exit 1。继续采集内核规则区分检查范围与恢复步骤，尚未计为首批通过。
随后核对 Ubuntu UFW 包的 `ufw-init-functions`：disable 特意保留空主链和跳转直到下次启动。
恢复步骤据此增加操作者安排的 VM 重启，再验证恢复状态；生产脚本的未知规则检查保持不变，未加入全局清空。

`135cd00` 的 service VM 通过 14 组；socket VM 完成实际安全更新后在最终 sshd 检查处失败，
新管理员仍能建立连接。`ebafd61` 的诊断版再次复现，原始检查日志为
`Missing privilege separation directory: /run/sshd`：更新后 socket 保持监听，但 daemon 的运行目录已移除。
修正为由 systemd 激活原 daemon 后再检查，不手工创建目录或跳过语法验证；另加真实 socket-only 状态的回归用例。
`0c3fd51` 的 socket 完整 apply 与新连接通过；附加回归用例的日志匹配没有处理
OpenSSH stderr 的 CRLF 而失败，改为仅去除 CR 后精确匹配，原有状态和退出码断言保留。
`46bf541` 已通过上述全部 VM 场景。复现命令（仅一次性 Linux 测试主机）：

```sh
sudo python3 -B tests/run_hardening_vm.py --ssh-mode socket
sudo python3 -B tests/run_hardening_vm.py --ssh-mode service
```

规格为 Ubuntu 24.04 amd64、1 GiB 内存、20 GiB 虚拟磁盘、两个 vCPU。
固定云镜像的大小与 SHA-256 先验证。只共享明确列出的脚本和合成公钥，私钥留在测试 host。
host key 从本次受控 guest 的只读公钥材料建立信任，全新 SSH 不复用连接、不跳过身份验证。
每份 `summary.json` 保存实际命令、退出码、断言、环境、首次/重复 apply 输出和源码摘要。
CI 制品名为 `hardening-vm-socket`、`hardening-vm-service`，包含汇总与结果日志，保留 14 天。
这些是合成目标证据；只共享明确文件，未上传私钥、完整 VM 磁盘或真实 VPS 材料。

已覆盖：错误输入端口、有效配置/实际 socket 不一致、非法公钥、不兼容目标账号、
准备与收紧分开、新管理员公钥及 sudo、SSH Include 冲突、未知 nftables、UFW 后中断、
普通备份恢复、禁止认证方式、每日更新、重复执行和受控 VM 重启。

真实 VPS 新入口：**NOT RUN**。第二批导出与完整组合部署、APT 迁移、arm64 VM：**NOT RUN**。
