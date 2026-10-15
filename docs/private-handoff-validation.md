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

本机新 8 组测试 PASS；语法与 ShellCheck PASS。CI、完整 VM、Mac CI：**NOT RUN**，待推送实跑后更新。
真实 VPS、Mac 网络/服务变更、手机与 REALITY 自动导出：**NOT RUN**。
