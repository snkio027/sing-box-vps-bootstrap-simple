# sing-box-vps-bootstrap

上传一个 Bash 文件到 Ubuntu VPS，执行后安装 sing-box、生成 SS2022 配置并启动 systemd 后台服务。
目标：Ubuntu 24.04，amd64/arm64，1 GiB 内存、20 GiB 磁盘，单用户 IPv4 TCP 443。

## 使用

通过你已经验证主机指纹的 SSH/SFTP 连接，上传 `scripts/prepare-vps.sh`。在 VPS 上执行：

```sh
sudo bash /root/prepare-vps.sh
```

默认刷新 APT 索引并安装依赖。如果本次也要升级 Ubuntu 已安装的软件：

```sh
sudo bash /root/prepare-vps.sh --upgrade-system
```

后一个选项执行 `apt-get upgrade`，保留既有包配置；依赖和条件 swap 先就绪。脚本不自动重启，
有 reboot-required 时会提示你安排。执行系统升级前保留现有 SSH 会话和服务商救援入口。

脚本没有 Python 运行时依赖，无需上传仓库、构建脚本、配置模板或 release manifest。
VPS 需要可工作的 APT/HTTPS 网络、已同步的系统时间和 systemd。既有 SSH 与防火墙规则保持原状；
请自行确认主机和服务商防火墙允许 IPv4 TCP 443。

## 脚本做什么

1. 检查 root、Ubuntu 24.04、架构、端口、现有安装、时间与磁盘；使用一个 `flock` 防止同时运行。
2. 执行 APT update，安装 curl、jq、OpenSSL 等依赖。
3. 创建锁定密码、不可登录的 `sing-box` 服务账号。内存不超过 2 GiB、无现有 swap，且 ext4/xfs
   剩余空间至少 5 GiB 时创建 1 GiB swap；已有活动或 fstab 配置的 swap 保持原样。
4. 下载固定版本 **1.14.0** 的官方 `.deb`，验证固定大小与 SHA-256，只取出并再次校验
   `usr/bin/sing-box`，安装到 `/usr/local/bin/sing-box`。不执行包脚本或安装包内 Polkit/D-Bus 授权。
   sing-box 是手工安装的单一二进制，不登记为 APT 软件包，也不会随 APT 隐式升级。
5. 在 VPS 本地生成 16 字节随机密钥；重复执行读取原密钥。生成配置并以服务账号运行 `sing-box check`，
   检查成功后替换配置。配置固定为 `2022-blake3-aes-128-gcm`、IPv4 TCP 443、direct outbound，服务端接受 MUX。
6. 安装 systemd unit，以非 root 账号和绑定低端口所需 capability 运行；启用开机启动，限制 journald 占用。
7. 检查服务持续运行 5 秒、主进程和监听归属。输出状态和文件位置，不输出密钥。

## 配置与维护

- 配置：`/etc/sing-box/config.json`，`root:sing-box 0640`。
- 服务：`/etc/systemd/system/sing-box.service`。
- 条件 swap：`/var/lib/sing-box/swapfile`，root 0600。
- 修改前的备份：`/var/backups/sing-box/run.*`，仅 root 可读。
- 日志上限：`/etc/systemd/journald.conf.d/60-sing-box-limits.conf`，全机 journal 磁盘 128 MiB、运行时 32 MiB。

```sh
systemctl --no-pager status sing-box
journalctl --no-pager -u sing-box -n 50
systemctl restart sing-box
```

重复执行仍会刷新 APT，但保留密钥，不重复添加 swap 行；配置与 unit 未变且服务健康时不重启进程。
脚本维护的配置会收敛到上述固定形式：保留密钥，其他自定义字段会被替换并备份。已有非本脚本的
配置、服务、不同二进制或旧控制器状态会被拒绝，不自动迁移。

失败会返回非零并说明阶段，已完成的安装/更新可能保留。检查错误和备份后再重试；swap 创建中断
留下的文件需要人工检查。没有通用回滚、事务恢复或自动删除主机状态。

把配置通过已经验证主机身份的私密连接交给 Mac，再用独立客户端验证 HTTPS。Mac 当前需要使用
已确认的物理网卡 en4；SSH 的接口绑定不会自动作用于 sing-box。客户端配置须显式设置并验证
`bind_interface`，且基线关闭 MUX。VPS 本地服务检查不等于公网链路已经通过。

## Mac 客户端

配套的 `scripts/connect-vps.sh` 是独立 Bash 文件：私密导入服务端配置，启动本机 SOCKS5，
绑定 en4 并验证一次 HTTPS。Apple Silicon Mac；Bash、curl、jq、OpenSSL 和 sing-box
使用 Homebrew 当前稳定版，明确使用 Homebrew 工具路径。无需 sudo 或 Python。
使用方法与限制见 [Mac 客户端说明](docs/mac-client.md)。

## 开发与验证

```sh
for script in scripts/*.sh tests/*.sh; do bash -n "$script"; done
shellcheck -x scripts/*.sh tests/*.sh
sudo bash tests/unit.sh
bash tests/client-unit.sh
```

GitHub Actions 在一次性 Ubuntu 24.04 VM（1 GiB / 20 GiB）中运行真实安装、系统升级、重复执行、
SS2022 HTTPS、错误密钥和端口冲突检查，并覆盖缺少 AF_NETLINK 的启动失败及重复安装修复。
Python 仅用于此测试环境和本地 HTTPS 测试服务。
`tests/run_vm.py` 只复制三个明确列出的源文件，绝不分享整个工作区。

验证结果与范围见 [docs/validation.md](docs/validation.md)。重建决定与旧实现位置见
[docs/reset.md](docs/reset.md)。
