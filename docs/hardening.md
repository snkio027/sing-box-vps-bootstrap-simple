# 独立主机初始化：harden-vps.sh

`scripts/harden-vps.sh` 为 Ubuntu 24.04 amd64/arm64 的单用途主机准备管理员、收紧 SSH、
配置 UFW 和每日安全更新。它不安装 sing-box，也不修改 Mac 网络。入口已实现；
本批测试结果单独记录在 [初始化验证](hardening-validation.md)。

`prepare` 和 `apply` 必须分开调用。第一次只准备管理员并结束，第二次从新管理员的 SSH 会话调用。
旧 SSH 会话和服务商控制台保持可用，直到收紧后的另一条全新连接通过。
SSH 端口保持原值，TCP 443 留给代理；不支持同一主机多个 SSH 监听端口或非标准 Include 布局的自动接管。

## 准备管理员

先核验新主机的 SSH host key，通过已有入口上传脚本和 **Ed25519 公钥**，私钥始终留在 Mac。
以下 `operator` 和文件路径为示例，替换为本次明确的管理员和公钥路径；这里假定现有端口为 22。
公钥输入需要是 root 控制路径下、root 所有且其他用户不可写的单条普通公钥文件；
不能提供私钥、密码、带 authorized_keys 选项的行或多把密钥。

```sh
sudo install -o root -g root -m 0755 harden-vps.sh /usr/local/sbin/harden-vps.sh
sudo install -o root -g root -m 0600 operator.pub /root/operator.pub
sudo bash /usr/local/sbin/harden-vps.sh prepare \
  --admin operator --public-key /root/operator.pub --ssh-port 22
```

要求已具备 OpenSSH、sudo/visudo、iproute2 和 systemd。准备过程验证实际 SSH 端口、
目标账号、目录、公钥和 sudoers，再创建或采用严格兼容的目标账号。
账号密码锁定，home 不允许其他用户写入，`.ssh` 为 0700、`authorized_keys` 为 0600。
目标账号若已存在但无法确认兼容则停止，主机上的无关预置普通账号不影响准备。

sudo 规则是 `ALL=(ALL:ALL) NOPASSWD: ALL`：这是明确选择的**完整管理员提权权限**。
这一步不关闭旧登录方式，不修改 SSH 配置或 UFW。
重复准备要求同一管理员、端口和公钥，不会替换成另一把密钥或重复追加 authorized_keys。

## 新建连接，再收紧

在 Mac 新终端使用已确认的 host key 和本次私钥建立连接。下例的 `VPS_IP` 是占位符；
物理接口需要现场核对，当前操作者使用 en4。SSH 不使用 ControlMaster 复用旧连接。

```sh
ssh -F /dev/null -p 22 -i "$HOME/.ssh/operator_ed25519" \
  -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
  -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
  -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519 \
  -o ControlMaster=no -o ControlPath=none \
  -o 'ProxyCommand=/usr/bin/nc -4 -b en4 %h %p' operator@VPS_IP
```

在这个新会话里执行 `sudo -n id -u`，必须成功并返回 `0`。
确认服务商控制台可以进入后，单独执行：

```sh
sudo --preserve-env=SSH_CONNECTION bash /usr/local/sbin/harden-vps.sh apply \
  --admin operator --ssh-port 22 --confirm-console
```

`apply` 校验 SUDO_USER/UID 和 SSH_CONNECTION，用当前来源地址检查管理员/root 的有效 SSH 策略。
这些条件用于防止误调用，完整管理员可以伪造环境，不能把它说成不可伪造的远端登录证明。
操作者的新连接验证和 VM 驱动采集的真实 SSH 会话分别记录，不引入登录证明协议。

执行顺序：

1. 同时核对 `sshd -T`、`ss -ltnp` 的实际端口/所有者、活跃 `ssh.socket` 的 Listen。
   输入端口不符就停止，早于防火墙修改；不通过修改端口来迎合输入。
2. 按现有 Include 顺序生成 SSH 候选，做语法和实际用户上下文检查。
   不能生效的片段或不兼容的用户/组过滤策略会在 UFW 修改前被拒绝。
3. 建立普通私密备份；按需安装 jq、nftables、UFW、unattended-upgrades、needrestart。
   安装依赖期间临时阻止包脚本启动服务，保护文件只按本次身份和内容清理。
4. 核查全部原生 nftables、legacy 防火墙、存储的 UFW 用户规则和控制文件。
   只在无未知规则时首次采用；UFW 默认控制文件必须与已安装包的原始模板一致。
   重跑时比较本项目保存的文件与内核规则摘要，发现外部变更就停止。
5. 先添加已核对的 SSH TCP 放行规则和 TCP 443 放行规则，再设置入站/转发拒绝、出站允许并启用双栈 UFW。
   保留默认网络控制规则；不 reset/flush 规则，不为改变 routed 显示文本启用内核转发。
6. 发布 SSH 片段，再次校验真实配置，内容变化时 reload SSH；不关闭现有会话。
   关闭 root、密码和键盘交互认证，保持公钥认证和原端口。
7. 设置每日索引刷新与仅 Ubuntu security 来源的无人值守更新，启用两个 APT timer；
   明确配置 needrestart 自动模式并核对最终生效值。
   首次运行包含实际刷新、dry-run 和实际更新；未找到更新时如实记录没有包版本变化。

**每日安全更新允许必要的服务重启和短暂中断，禁止自动整机重启。**
首次 apply 应在可接受中断的时间运行。系统包的默认服务排除项仍由 Ubuntu 管理；
以后需要固定维护时段，再调整 timer，不增加调度框架。
`prepare-vps.sh` 安装依赖时临时使用的 needrestart 环境覆盖，不会写成每日更新的持久策略。

apply 返回成功表示本机检查通过。此时还要在另一个新终端验证管理员密钥登录和 sudo，
检查 root/密码认证的拒绝行为。已有代理则检查 HTTPS；新主机接下来运行 `prepare-vps.sh`。
最后才关闭旧会话，重启另由操作者明确安排。

## 文件、重复执行与失败恢复

- 简单归属记录：`/var/lib/sing-box-hardening`，root 0700，保存管理员/端口/公钥和受管文件摘要。
- 普通备份和有限日志：`/var/backups/sing-box-hardening/run.*`，root-only。
- SSH：`/etc/ssh/sshd_config.d/00-sing-box-hardening.conf`。
- sudo：`/etc/sudoers.d/90-sing-box-<管理员>`，0440。
- 更新：`/etc/apt/apt.conf.d/99-sing-box-hardening` 与
  `/etc/needrestart/conf.d/99-sing-box-hardening.conf`。

重复执行要求记录、配置和规则仍然兼容；账号、公钥、组与规则不重复。
安全更新会再次检查并执行，可能出现允许的包变化和服务重启，不能声称整次 apply 绝对零变化。
脚本没有通用自动回滚。失败后已安装的包、已创建的账号或已经启用的规则可能保留。

首次 apply 中断后，`applying` 记录使盲目重试失败。使用仍可用的 SSH 或控制台，读取
`last-backup` 指向的目录，按实际失败阶段恢复：

- SSH 片段：若备份中存在原片段，只恢复该文件；若 `absent-before` 记录它原本不存在，
  先私密保存当前片段，再移出加载目录。执行 `sshd -t` 成功后 reload，验证全新连接。
- 首次 UFW 采用：确认当前仍是本次规则且没有外部变更后，可以在恢复入口临时 `ufw disable`，
  仅恢复备份中 `/etc/default/ufw`、`ufw.conf`、`user.rules`、`user6.rules` 对应文件。
  不对未知规则执行全局清空，也不整体覆盖其他系统配置。
- 更新设置：按 `absent-before` 和备份恢复两个精确片段；包安装和已应用补丁不会因此撤销。
- 依赖安装被强制终止时，可能留下 `/usr/sbin/policy-rc.d`。只有文件身份与内容均匹配
  备份中的 `policy-rc.d.identity` / `policy-rc.d.created`，且确认没有包管理进程仍在运行后，
  才人工删除本次保护文件；未知的原有保护文件不接管。

确认恢复后的新连接、语法和防火墙状态后，才移走 `applying` 记录并决定重试。
保留备份以供核对。测试可以丢弃失败 VM 重建，生产恢复不能把“重跑脚本”作为检查的替代品。

完整部署需要第二批在同一干净 VM 串起 prepare → 新 SSH → apply → prepare-vps → 私密取回 →
客户端导入 → HTTPS 出口，再重复执行及受控重启。第一批独立通过不代表这条组合流程已经通过。
