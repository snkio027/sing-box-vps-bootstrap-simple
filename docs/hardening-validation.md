# 主机初始化验证

本页只记录 `harden-vps.sh`，不把此前手工加固的真实 VPS 证据冒充新入口实测。

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

VM 当前正在执行修订版，结果未验收。复现命令（仅一次性 Linux 测试主机）：

```sh
sudo python3 -B tests/run_hardening_vm.py --ssh-mode socket
sudo python3 -B tests/run_hardening_vm.py --ssh-mode service
```

规格为 Ubuntu 24.04 amd64、1 GiB 内存、20 GiB 虚拟磁盘、两个 vCPU。
固定云镜像的大小与 SHA-256 先验证。只共享明确列出的脚本和合成公钥，私钥留在测试 host。
host key 从本次受控 guest 的只读公钥材料建立信任，全新 SSH 不复用连接、不跳过身份验证。
每份 `summary.json` 保存实际命令、退出码、断言和本次脚本/驱动/镜像定义的源码摘要。

覆盖目标：错误输入端口、有效配置/实际 socket 不一致、非法公钥、不兼容目标账号、
准备与收紧分开、新管理员公钥及 sudo、SSH Include 冲突、未知 nftables、UFW 后中断、
普通备份恢复、禁止认证方式、每日更新、重复执行和受控 VM 重启。

真实 VPS 新入口：**NOT RUN**。第二批导出与完整组合部署、APT 迁移、arm64 VM：**NOT RUN**。
