# RackNerd + Cloudflare + VLESS/WebSocket 一键搭建

> 面向「VPS 的 443 端口被墙，但 80 还活着」这种情况的可用方案。
> 实测环境：RackNerd 1C1G / Ubuntu 24.04 / Xray 26.x / Cloudflare Free。

## 为什么需要这套方案

很多人第一次搭梯子的路线是 **VLESS + REALITY 直连 443**。这套配置本身没问题，但它有个死穴：**一旦 VPS 的 IP 被针对，443 端口从中国大陆连不上，整套就废了**，而且服务端日志看不出任何异常（握手请求根本没到服务器）。

典型症状：

| 检查项 | 结果 | 说明 |
|---|---|---|
| 服务器 `systemctl status xray` | `active` | 服务正常 |
| 服务器本机回环测试 | 成功 | 配置、密钥全部正确 |
| 客户端节点测速 | **Timeout** | 但就是连不上 |
| `Test-NetConnection IP -Port 22` | True | 服务器没死 |
| `Test-NetConnection IP -Port 80` | True | 80 还通 |
| `Test-NetConnection IP -Port 443` | **False** | 443 被墙 |

**结论**：问题不在配置，在链路。硬刚直连没有出路，换思路——**把流量塞进 80 端口，让 Cloudflare 帮你中转**。

## 架构

```
                    中国大陆                          境外
┌──────────┐      ┌─────────────┐      ┌──────────────────────┐
│  客户端   │─────▶│  Cloudflare │─────▶│  VPS:80 (nginx)      │
│ Clash/   │ TLS  │  CDN 边缘    │ HTTP │   ├── /ws → Xray:8080 │
│ FlClash  │ 443  │  (104.x.x.x)│  80  │   └── /sub → 订阅文件  │
└──────────┘      └─────────────┘      └──────────┬───────────┘
                                                   │ 直连
                                                   ▼
                                              目标网站
```

- **客户端 → Cloudflare**：正常 TLS（443），国内可直连 Cloudflare 边缘节点
- **Cloudflare → 你的 VPS**：明文 HTTP（80），所以服务器不需要开放 443
- **协议**：VLESS + WebSocket + TLS，WebSocket 保证能穿过 CDN
- **出口 IP**：目标网站看到的是 VPS 的 IP，不是 Cloudflare 的（CDN 只是中转）

## 前置条件

1. **一台 VPS**，80 端口能从中国大陆访问
2. **一个域名**（免费域名也行，见 [docs/cloudflare-setup.md](docs/cloudflare-setup.md)）
3. **Cloudflare 账号**（Free 计划足够）
4. 一个 **mihomo 内核**的客户端：
   - Windows：[Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)
   - Android：[FlClash](https://github.com/chen08209/FlClash)
   - ⚠️ 老版 Clash for Windows / ClashX **不支持** VLESS，别用

## 快速开始

### 1. 域名接入 Cloudflare

详见 [docs/cloudflare-setup.md](docs/cloudflare-setup.md)。核心就三步：

1. 域名加进 Cloudflare，拿到两个 `*.ns.cloudflare.com`
2. 回域名商把 NS 改成这两个
3. 加一条 `A` 记录指向 VPS IP，**橙色云 Proxied**

然后**务必**把 SSL/TLS 模式改成 **Flexible**（Cloudflare 到源站走 HTTP，因为源站 443 通常是封的）。

### 2. 服务器一键部署

SSH 登录 VPS，用 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/IdealistHua/cf-vless/main/scripts/deploy.sh -o deploy.sh
bash deploy.sh vpn.example.com
```

或者 clone 下来跑：

```bash
git clone https://github.com/IdealistHua/cf-vless.git
cd cf-vless
sudo bash scripts/deploy.sh vpn.example.com
```

脚本会依次完成：

| 步骤 | 内容 |
|---|---|
| 1 | 装依赖（curl / openssl / nginx） |
| 2 | 开启 BBR |
| 3 | 安装 Xray，生成随机 UUID |
| 4 | 写 Xray 配置：VLESS + WS，**只监听 `127.0.0.1:8080`** |
| 5 | 写 nginx 配置：监听 80，`/ws` 反代到 8080，`/sub/` 托管订阅 |
| 6 | 生成 Clash 订阅 YAML 和节点信息，打印出来 |

跑完记下最后打印的**订阅地址**和 **VLESS 链接**。

### 3. 客户端导入

把订阅地址填进 Clash Verge Rev（订阅 → 新建 → Remote），或者安卓 FlClash（配置 → 从 URL 导入）。

导入后记得：

- 打开 **系统代理**（Windows）或顶部总开关（FlClash）
- 模式选 **规则**

## 部署后的结构

```
/usr/local/etc/xray/config.json      # Xray 配置（WS，监听 127.0.0.1:8080）
/etc/nginx/conf.d/vpn.conf           # nginx 配置（80 端口反代 + 订阅）
/var/www/sub/<token>/sub.yaml        # Clash 订阅文件
/root/xray-node.txt                  # 节点参数备份（含 UUID）
/root/clash.yaml                     # 订阅备份
```

## 常用运维命令

```bash
# 服务状态
systemctl status xray nginx --no-pager

# 实时日志（排查问题首选）
journalctl -u xray -n 50 --no-pager

# 端口监听（应该看到 nginx 占 80，xray 占 127.0.0.1:8080）
ss -tlnp | grep -E ':80 |:8080 '

# 验证订阅（本地 + 走 CDN 各测一次）
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/sub/<token>/sub.yaml
curl -s -o /dev/null -w '%{http_code}\n' http://vpn.example.com/sub/<token>/sub.yaml

# 换订阅 token（链接泄露时用）
openssl rand -hex 16 > /root/sub-token.txt

# 重载配置
systemctl restart xray && systemctl restart nginx
```

## 排错

完整排错流程见 [docs/troubleshooting.md](docs/troubleshooting.md)。

想知道这套方案是怎么一步步试出来的（含全部踩坑、错误判断和最终修复），看 [docs/build-log.md](docs/build-log.md) —— 一次真实搭建的完整记录：REALITY 直连失败、端口扫描、Cloudflare 接入的 NXDOMAIN 问题，以及那个让所有人抓狂的「两个代理内核打架」。

三个最高频的问题：

| 现象 | 原因 | 解决 |
|---|---|---|
| 节点测速 Timeout，订阅能拉 | Xray 没在监听 / WS 路径不对 | `ss -tlnp \| grep 8080`，核对 `/ws` |
| 订阅也拉不到 | 域名解析或 Cloudflare 代理没生效 | `dig +short 你的域名`，应返回 `104.x` / `172.67.x` |
| HTTP 522 / 525 | SSL 模式不是 Flexible / 源站 80 没起来 | Cloudflare 改 Flexible，查 nginx 状态 |

## 已知限制

- **UDP 不通**：Cloudflare 免费版只转发 HTTP/HTTPS。游戏、语音、QUIC 类应用会失败；网页浏览、YouTube、Telegram 文字消息正常。
- **延迟偏高**：经 Cloudflare 中转，中国大陆通常 200–400ms，取决于 CF 边缘节点分配。
- **依赖域名**：域名过期或被回收，整套就失效。免费域名（如 DigitalPlat）需要**每年手动续期**。
- **Cloudflare 免费版无 SLA**：偶尔会抽风，属于 CF 侧问题，等或换节点。

## 安全提示

- 订阅地址里的 `token` 等于密码，**不要公开贴在论坛/群里**
- 仓库里**不要提交**真实的 UUID、token、服务器 IP（`.gitignore` 已排除常见配置文件名）
- 建议开启 Cloudflare 的 **Under Attack Mode 关**、**Bot Fight Mode 关**，避免误伤正常连接

## 免责声明

本项目仅供网络技术学习与研究使用。使用者应遵守所在国家和地区的法律法规，自行承担使用后果。作者不对任何滥用行为负责。

## License

MIT
