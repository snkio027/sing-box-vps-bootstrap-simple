# 私密交接：只取客户端必要字段

服务端 `/etc/sing-box/config.json` 和 `reality-keypair.private` 均不得整份下载给客户端。
双协议服务端配置包含 REALITY 私钥；即使 Mac 文件为 0600，也不应扩大这把私钥的存放范围。
下文先给出独立取回入口，再保留可选人工交接；只在已授权、核验 host key 的目标上执行。

## 自动取回，然后单独导入

`scripts/fetch-vps-config.sh` 已实现。使用普通 Apple Silicon Mac 用户及当前 Homebrew Bash 5.3+、jq、OpenSSL；
依赖由操作者先按 [客户端准备](mac-client.md) 更新，脚本不自动安装。它不启动代理或修改现用配置。
先独立核验 VPS 的 Ed25519 host key，将对应记录保存在当前用户的 0600 `known_hosts` 文件；
端口非 22 时使用 `[VPS_IP]:PORT` 形式。不使用网络扫描到的未验证公钥自动建立信任。

```bash
mkdir -m 700 "$HOME/vps-private"
/opt/homebrew/bin/bash scripts/fetch-vps-config.sh \
  VPS_IP 22 operator "$HOME/.ssh/operator_ed25519" \
  "$HOME/.ssh/vps_known_hosts" en4 "$HOME/vps-private/ss2022.json"
/opt/homebrew/bin/bash scripts/connect-vps.sh setup VPS_IP "$HOME/vps-private/ss2022.json" en4
/opt/homebrew/bin/bash scripts/connect-vps.sh check
```

七个位置参数依次为地址、SSH 端口、管理员、私钥路径、已核验主机密钥文件、物理网卡、输出文件。
两个输入文件须为当前用户所有、0600 或更严格、单硬链接普通文件；路径使用绝对路径，拒绝 SSH
路径展开字符。指定的加密私钥须先在本机 agent 解锁，脚本不提示密码、不转发 agent。
SSH 强制全新连接、Ed25519 主机密钥及公钥认证，通过 `nc -b enN` 绑定所选物理网卡。

服务端以 `sudo -n` 执行固定只读投影，持有安装锁的共享锁；重启后只在 `/run/lock` 排他重建零字节运行时锁，
不创建持久状态。安装或维护未完成时拒绝导出。
不会在 VPS 创建导出文件、调整配置权限、增加服务账号组成员或发送私钥。
本地先接入同文件系统的私有临时目录，检查 SSH 返回码、精确 JSON 形状和规范 16 字节密钥，
才用 `link(2)` 排他发布 0600 文件。已有文件、目录、软链接以及发布时竞争创建都失败且不覆盖。
SSH 断连、sudo 失败、主机密钥不匹配、非法 JSON 等路径不发布目标；正常退出清理本次临时文件。
原生 [link 的 EEXIST 语义](https://man.openbsd.org/link.2) 与 [OpenSSH 身份选项](https://man.openbsd.org/ssh_config) 是这两个边界的依据。

每次取回选择新文件名；原输出存在时直接失败。重复 `setup` 相同配置会保留原文件和上一份备份；
`check` 还要求 HTTPS trace 的唯一 `ip=` 与配置中的 VPS IPv4 相等。出口为其他 NAT 地址时会失败，需先核查部署拓扑。
SIGKILL 无法执行清理：可能留下私有 `.fetch.*` 目录或已完整发布的文件，检查后人工处理；不自动覆盖重试。
传输诊断可能含远端文本，不回显，随临时目录清理；根据报错私下核查 SSH 身份和服务状态。
实测结果及平台适配边界见 [组合验证](private-handoff-validation.md)。

## 可选人工交接：在服务器生成最小投影

在 VPS 的 root 会话中执行下面代码。它只输出新建私密文件的路径，不回显密钥。
`mktemp` 排他创建 root 0600 文件，不覆盖既有文件。投影适用于单协议和双协议服务端；
只接受一个 SS2022 TCP 443 入站，并按白名单新建对象，不复制其他入站或未知字段。
此函数由 `tests/handoff-unit.sh` 原样提取测试，不维护另一份测试专用过滤器。

```bash
set +x
set -euo pipefail
umask 077
project_ss2022() {
    jq -e -s '
      if length == 1 then .[0] else error("Expected one JSON document") end |
      [.inbounds[] | select(.type == "shadowsocks")] |
      if length == 1 then .[0] else error("Expected one SS2022 inbound") end |
      if .method == "2022-blake3-aes-128-gcm" and .listen_port == 443 and
         .network == "tcp" and (.password | type == "string") and
         (.password | test("^[A-Za-z0-9+/]{22}==$")) then
        {inbounds: [{type, method, listen_port, network, password}]}
      else error("Unsupported SS2022 input") end
    ' "$1"
}
export_file=$(mktemp /root/sing-box-ss2022.XXXXXXXX.json)
if ! project_ss2022 /etc/sing-box/config.json > "$export_file"; then
    rm -- "$export_file"
    exit 1
fi
printf 'Private SS2022 export: %s\n' "$export_file"
```

通过已核验主机身份的 SSH 与 `sudo -n` **只读取该投影文件**，输出直接进入 Mac 新建的
私密临时文件；不要直接在终端执行会回显正文的命令。服务端原配置权限保持不变，普通 SFTP
不能读取 root-only 文件，不能为下载放宽权限。Mac 输出目录须由当前用户控制且其他用户不可写，
最终文件为 0600；已有目标必须拒绝，成功检查后才排他发布。自动取回入口遵守以上规则；人工方式也必须自行保证这些条件。

投影在 Mac 保存为 `vps-config.json` 后，沿用 `connect-vps.sh setup VPS_IP /path/vps-config.json en4`。
它会继续验证密钥解码长度和规范 Base64；地址仍由操作者明确提供。该人工过滤器的合成测试
不能替代完整组合验证；自动入口的 VM 结果见上文，真实目标及手机仍须单独验收。

## REALITY：单独交接客户端字段

客户端所需字段仅为 VPS 地址、8443、UUID、`xtls-rprx-vision`、server name、REALITY 公钥及 short ID。
公钥从服务器对应本次部署的公私钥记录中仅提取 `PublicKey`；记录与当前服务配置的对应关系需核对。
**不复制 `PrivateKey`、`tls.reality.private_key` 或整份公私钥记录。**
已有 [双协议模板](../examples/1.14.2/README.md) 继续用于生成私密候选；自动 REALITY 参数导出和三端
配置生成不属于本次修复。SS2022 投影不携带 REALITY 参数，也不会改变默认协议或切换正在运行的客户端。
