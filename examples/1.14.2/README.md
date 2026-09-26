# 1.14.2 双协议候选配置

本目录全部地址与凭据为公开测试值，禁止原样部署。它们不是现网私密配置。
`server.example.json` 保留 SS2022 TCP 443，加入 VLESS + REALITY + Vision TCP 8443；
`macos` / `android` / `ios` 提供同一策略的完整客户端，默认 selector 选择 SS2022，REALITY 为手动选项。

[部署与恢复步骤](../../docs/reality-upgrade.md) · [验证范围](../../docs/reality-validation.md)

1.14.0 目录保留历史基线。新目录沿用原 DNS、广告、私网和真实 IP GeoIP 补充策略；
不支持公网 UDP/ICMP 或完整公网 IPv6，不叠加 Vision 与 MUX，不自动退回直连。
Mac 保留 en4、规则 initial_path 和回环监听；手机不带固定网卡/额外监听/未提供规则文件。
三份规则必须可读或能首次下载；桌面 check 不证明移动 VPN、无缓存启动、切网或锁屏成功。

私密交接时替换两个出站的 VPS 地址和 /32 规则，SS2022 密钥、REALITY UUID/公钥/short ID、
已核验握手 server name；Mac 还要使用独立 API secret。REALITY 私钥仅留服务器，不导入手机。
缓存 ID 保留以便已有部署迁移；首次安装仍会创建自己的缓存。

内核、Android 应用及制品记录见 [client-versions.json](client-versions.json)。iOS 应用版本与内置内核
需在目标设备另行确认；不能用应用版本号代替内核版本。
