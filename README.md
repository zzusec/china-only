# china-only

一个 macOS 出站防火墙脚本，基于系统自带的 **PF（Packet Filter）** 实现「中国 IP 白名单」：

- **未开代理**：只允许访问中国 IP（以及内网 / 回环），禁止访问任何国外 IP。
- **开了代理**：访问国外站点必须经过代理（代理服务器地址被单独放行），无法用中国 IP 直连国外。

规则直接写入系统网络层（内核 PF），支持 **安装 / 卸载 / 重装 / 更新**，重启后依然生效。

---

## 原理

在出站方向做白名单过滤：

| 出站目标 | 处理 |
| --- | --- |
| 中国 IP（公开 IP 库） | ✅ 放行直连 |
| 内网 / 回环 / 链路本地 / 组播 | ✅ 放行 |
| 代理服务器地址（需自己配置） | ✅ 放行（让代理能连国外服务器） |
| 国外 DNS（默认放行，可关闭） | ✅ / 🚫 可配置 |
| **其余一切（即国外 IP）** | 🚫 `drop` |

这样两条需求天然同时成立：不开代理时没有放行通道，国外全断；开代理时唯一能连国外的只有代理服务器本身，你的国外流量只能走代理。

> 中国 IP 段默认下载自 [17mon/china_ip_list](https://github.com/17mon/china_ip_list)，失败自动回退到 [ipdeny](https://www.ipdeny.com)，并本地缓存。可通过 `CHINA_ZONE_URL` 换源。

## 要求

- macOS（使用系统自带 `pf`）
- `sudo` 权限（脚本会自动提权）
- 可选：`dig`（系统自带，用于解析代理域名；也可直接用网段 `PROXY_CIDRS`）

## 安装

一键安装：

```bash
curl -fsSL https://raw.githubusercontent.com/zzusec/china-only/main/china-only.sh -o china-only.sh \
  && chmod +x china-only.sh \
  && sudo ./china-only.sh install
```

或克隆仓库：

```bash
git clone https://github.com/zzusec/china-only.git
cd china-only
sudo ./china-only.sh install
```

安装后命令会链接到 `/usr/local/bin/china-only`，之后直接使用 `china-only ...`。

## 使用

```bash
# 配置代理服务器（关键一步，否则代理自己也无法连国外）
china-only set PROXY_HOSTS "节点1.example.com,节点2.example.com"
china-only set PROXY_CIDRS "1.2.3.0/24"          # 用网段更稳，不依赖 DNS 解析

# 日常
china-only status        # 查看状态与配置
china-only update        # 更新中国 IP 库并重载
china-only reload        # 改完配置后重新加载
china-only disable       # 临时关闭（不删除安装）
china-only enable        # 恢复

# 严格模式（可选）：禁止国外 DNS + 使用国内 DNS
china-only set ALLOW_FOREIGN_DNS 0
china-only set-china-dns

# 卸载
china-only uninstall          # 保留 IP 库与配置
china-only uninstall --purge  # 连 IP 库一起删除
```

## 配置项

存放于 `/usr/local/share/china-only/china-only.conf`，也可用 `china-only set KEY VALUE` 修改。

| 配置项 | 说明 |
| --- | --- |
| `PROXY_HOSTS` | 代理服务器域名，逗号分隔（reload 时解析成 IP 放行） |
| `PROXY_CIDRS` | 代理服务器网段，逗号分隔，直接放行 |
| `PROXY_UIDS` | 代理进程所属 UID，逗号分隔（实验性） |
| `ALLOW_FOREIGN_DNS` | `1` 允许访问任意 DNS（默认，保证可用）；`0` 禁止国外 DNS（需配国内 DNS） |
| `BLOCK_IPV6` | `1` 封禁国外 IPv6（默认，防泄露）；`0` 不处理 IPv6 |
| `CHINA_ZONE_URL` | 中国 IP 库下载地址 |
| `CHINA6_ZONE` | 可选的中国 IPv6 段文件路径 |

## 注意事项

- **代理服务器必须显式放行**。PF 无法自动识别「哪个进程是代理」，需用 `PROXY_HOSTS` / `PROXY_CIDRS` 把节点地址加进白名单；节点 IP 变更后请重新 `reload` / `update`。
- **逃生通道**：若误把自己锁死，`sudo pfctl -d` 直接关闭 PF，或 `sudo china-only uninstall`。
- **IPv6**：默认封禁国外 IPv6，防止只封 IPv4 被 IPv6 绕过。
- **DNS**：默认放行任意 DNS 以保证系统可用；严格模式（`ALLOW_FOREIGN_DNS=0`）需配合国内 DNS（`china-only set-china-dns`）。

## License

[MIT](LICENSE) © 2026 zzusec

> 本工具用于个人网络访问控制。请遵守所在地区法律法规，勿用于绕过网络审查等用途。
