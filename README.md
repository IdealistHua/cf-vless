# 从零搭建：Cloudflare + VLESS/WebSocket 科学上网

> 一台 1 核 1G 的小 VPS，加一个域名，就能搭一套**抗封锁、可维护、带运维**的梯子。
> 全程照着做约 40 分钟。命令都是复制粘贴。

**最终效果**：Windows / 安卓装上 Clash 类客户端，导入一个订阅地址，选节点就能上网；服务器上还有流量日报、守护进程、自动备份。

---

## 这套方案的三个关键决策

| 决策 | 选择 | 为什么不选另一个 |
|---|---|---|
| 传输方式 | **VLESS + WebSocket + TLS（经 Cloudflare）** | 直连 REALITY 在机房 IP 的 443 上大概率被 TLS 层 RST，端口扫描「开放」是假象 |
| 对外端口 | **只有 80** | 443 留给 Cloudflare 回源都用不满；80 反而最少被针对 |
| 订阅 | **nginx 托管的静态 YAML** | 自建订阅后端要维护、要鉴权，静态文件 200 就是 200 |

⚠️ **最常见的误解**：「端口开着 = 能用」。错。GFW 可以让你 SYN 通、握手时注入 RST。判断标准永远是**节点能不能跑通**，不是扫描结果。

---

## 目录

1. [准备](#1-准备)
2. [原理（三句话）](#2-原理三句话)
3. [部署：五步](#3-部署五步)
4. [客户端导入](#4-客户端导入)
5. [验证](#5-验证)
6. [日常运维](#6-日常运维)
7. [进阶](#7-进阶)
   - [7.1 住宅 IP 出口](#71-住宅-ip-出口可选)
   - [7.2 443 直连（多数会失败）](#72-443-直连可选多数会失败)
   - [7.3 订阅调优：能加什么、千万别加什么](#73-订阅调优能加什么千万别加什么)
8. [排错决策树](#8-排错决策树)
9. [边界与安全](#9-边界与安全)

---

## 1. 准备

| 东西 | 说明 | 花费 |
|---|---|---|
| **VPS** | 1 核 1G，Ubuntu 22.04 / 24.04 | 约 $15–25/年 |
| **域名** | 免费域名也行，见 [docs/cloudflare-setup.md](docs/cloudflare-setup.md) | 0 或 ¥10/年 |
| **Cloudflare 账号** | Free 计划足够 | 0 |
| **客户端** | Windows: Clash Verge Rev；安卓: FlClash | 0 |

### 客户端必须是 mihomo 内核

老版 Clash for Windows / ClashX **不支持 VLESS**，装了也用不了。

| 平台 | 推荐 | 地址 |
|---|---|---|
| Windows | Clash Verge Rev | https://github.com/clash-verge-rev/clash-verge-rev/releases |
| Android | FlClash | https://github.com/chen08209/FlClash/releases |

> 📌 **一台设备只装一个代理客户端**。两个内核同时在跑会抢流量，症状是「节点全超时，服务器却一切正常」——这个坑我们踩过，见 [docs/troubleshooting.md](docs/troubleshooting.md) 第 5 节。

---

## 2. 原理（三句话）

```
   你的设备                   Cloudflare                 你的 VPS
┌──────────┐   加密连接   ┌──────────────┐   普通 HTTP  ┌─────────────────┐
│ Clash    │────────────▶│  全球边缘节点  │────────────▶│ nginx   :80     │
│ FlClash  │   (TLS)     │              │    (:80)    │  ├ /ws  → Xray   │
└──────────┘             └──────────────┘             │  └ /sub → 订阅   │
                                                       └────────┬────────┘
                                                                ▼
                                                           目标网站
```

1. 设备连的是 **Cloudflare**，不是 VPS。
2. Cloudflare 用普通 HTTP 把流量转给你的 VPS（80 端口）。
3. VPS 上的 Xray 替你去访问目标网站，出口是 VPS 自己的 IP。

**好处**：外界只看到「你 ↔ Cloudflare」的正常 HTTPS；VPS 的真实 IP 不暴露，换 IP 也只改一条 DNS 记录，客户端和订阅都不用动。

---

## 3. 部署：五步

### 第一步：登录服务器

```powershell
ssh root@你的服务器IP
```

- 第一次问 `Are you sure you want to continue connecting?` → 输 `yes`
- 输密码时**屏幕不显示任何字符**，是正常的

成功的标志：

```
root@racknerd-xxxxx:~#
```

先更新系统：

```bash
apt update && apt upgrade -y
```

> 💡 之后所有命令都在这个窗口敲。命令前面的 `#` / `$` 是提示符，**不要复制进去**。

### 第二步：域名接进 Cloudflare

1. https://dash.cloudflare.com → **Add a site** → 输域名 → 选 **Free**
2. 记下 Cloudflare 给的两个 NS（`xxx.ns.cloudflare.com`）
3. 去域名商把 NS 改成这两个（免费域名见 [docs/cloudflare-setup.md](docs/cloudflare-setup.md)）
4. 回 Cloudflare 点 **Check nameservers**，等生效
5. **DNS → Records → Add record**：

| 字段 | 填什么 |
|---|---|
| Type | `A` |
| Name | `vpn`（随意，记住就行） |
| IPv4 | 你的 VPS IP |
| Proxy status | **Proxied（橙云）** ← 必须橙 |

6. **SSL/TLS → Overview** → 选 **Flexible**

> 必须 Flexible。选 Full 时 Cloudflare 会用 HTTPS 回源，而服务器只开 80，直接 522。

**验证**（在服务器上）：

```bash
dig +short vpn.你的域名.com
```

| 返回 | 结论 |
|---|---|
| `104.x` / `172.67.x` | ✅ 成功 |
| 你自己的 VPS IP | ❌ 云朵没点橙 |
| 空 | ❌ NS 还没生效，等 |

### 第三步：一键部署

```bash
curl -fsSL https://raw.githubusercontent.com/IdealistHua/cf-vless/main/scripts/deploy.sh -o deploy.sh
bash deploy.sh vpn.你的域名.com
```

脚本做七件事：

| 步骤 | 做什么 |
|---|---|
| 1 | 装依赖：curl、openssl、nginx |
| 2 | 开 BBR |
| 3 | 装 Xray，生成随机 UUID |
| 4 | 写 Xray 配置：VLESS + WS，只监听 `127.0.0.1:8080` |
| 5 | 写 nginx：80 对外，`/ws` 转 Xray，`/sub/` 放订阅 |
| 6 | 生成订阅和节点信息 |
| 7 | 自检 |

**成功的标志**：末尾打印节点信息，并且自检出现两个 200：

```
sub HTTP 200
via-CDN sub HTTP 200
```

**把「订阅」那一行完整复制下来。**

> 📌 信息也备份在 `/root/xray-node.txt`，忘了就 `cat /root/xray-node.txt`。

### 第四步：客户端导入

**Windows（Clash Verge Rev）**

1. 左侧 **订阅** → 粘贴地址 → **导入**
2. 左侧 **代理** → 点节点选中
3. **设置** → 打开 **系统代理**

**Android（FlClash）**

1. 底部 **配置** → 右上 **+** → 从 URL 导入
2. **代理** → 选中节点
3. 打开总开关

### 第五步：验证

浏览器打开 https://ipinfo.io/json：

```json
{ "ip": "你的VPS IP", "city": "Los Angeles", "country": "US", "org": "AS36352 HostPapa" }
```

| 看到 | 结论 |
|---|---|
| `country: US`，IP 是 VPS 的 | ✅ 通了 |
| `country: CN`，IP 是你家宽带 | ❌ 系统代理没开 |
| 打不开 ipinfo | ❌ 看第 8 节 |

Clash 节点右边有延迟数字（如 `350`）就是通；`Timeout` / `Error` 看第 8 节。

---

## 4. 客户端导入

见上一节。补充两点：

- **订阅地址泄漏 = 密码泄漏**。怀疑泄漏就换 token（见第 6 节）。
- 手机和电脑可以同时用一个订阅，互不影响。

---

## 5. 验证

已经放在「第五步」里，避免重复。

---

## 6. 日常运维

常用命令速查：

```bash
systemctl status xray nginx --no-pager        # 服务活着吗
journalctl -u xray -n 50 --no-pager           # 最近日志
ss -tlnp | grep -E ':80 |:8080 '              # 端口监听
systemctl restart xray nginx                  # 重启
bash /usr/local/bin/vps-check                 # 只读体检（10 段）
```

### 换订阅 token（怀疑泄漏时）

```bash
NEW=$(openssl rand -hex 16)
echo "$NEW" > /root/sub-token.txt
mkdir -p /var/www/sub/$NEW
cp /root/clash.yaml /var/www/sub/$NEW/sub.yaml
echo "新订阅：http://你的域名/sub/$NEW/sub.yaml"
```

然后客户端删掉旧订阅，重新导入。

### 三件套：日报 / 守护 / 备份

装完 deploy.sh 后可选装这三个，让服务器自己照顾自己：

```bash
curl -fsSL https://raw.githubusercontent.com/IdealistHua/cf-vless/main/scripts/traffic-report.sh -o /usr/local/bin/traffic-report.sh
curl -fsSL https://raw.githubusercontent.com/IdealistHua/cf-vless/main/scripts/watchdog.sh       -o /usr/local/bin/watchdog.sh
curl -fsSL https://raw.githubusercontent.com/IdealistHua/cf-vless/main/scripts/backup-cf.sh      -o /usr/local/bin/backup-cf.sh
chmod +x /usr/local/bin/{traffic-report,watchdog,backup-cf}.sh

( crontab -l 2>/dev/null | grep -vE 'traffic-report|watchdog|backup-cf';
  echo "0 9 * * * /usr/local/bin/traffic-report.sh";
  echo "*/10 * * * * /usr/local/bin/watchdog.sh";
  echo "0 4 * * * /usr/local/bin/backup-cf.sh" ) | crontab -
crontab -l
```

详细配置（Telegram 推送、阈值、日志位置）见 **[docs/operations.md](docs/operations.md)**。

---

## 7. 进阶

### 7.1 住宅 IP 出口（可选）

**解决什么**：机房 IP 被目标站点识别为代理。典型症状是「代理明明生效了，但网站说你在不支持的地区」。

**原理**：再加一跳真实的住宅 IP，只让指定域名走它：

```
设备 → Cloudflare → VPS → 住宅IP → 目标网站
```

关键在 `dialer-proxy`：连住宅代理这一步先走 VPS，比从国内直连美国住宅代理快得多。

完整步骤见 **[docs/residential-exit.md](docs/residential-exit.md)**。

### 7.2 443 直连（可选，多数会失败）

直连比 CDN 快，但机房 IP 的 443 是最容易被针对的端口。判断方法：

```bash
# 客户端打这个端口
timeout 40 tcpdump -ni any 'tcp port 443 and host <你的公网IP>' -c 20
```

| 抓到的包 | 结论 |
|---|---|
| `[S] → [S.] → [.] → [R]` 且 Xray 日志空白 | ❌ TLS 层被 RST，放弃 |
| 正常握手 + 日志有连接 | ✅ 可用 |

真被 RST 了就不用折腾了，清掉即可。**主方案完全不受影响。**

### 7.3 订阅调优：能加什么、千万别加什么

这条最值钱，是我们实际把整台代理搞挂之后总结的。

**可以加（低风险）**

```yaml
tcp-concurrent: true          # 多 IP 并发握手，明显提速
unified-delay: true           # 延迟数字更真实
profile:
  store-selected: true
  store-fake-ip: true
```

**千万别加（会全盘失败）**

```yaml
# ❌ 会炸
find-process-mode: strict     # Windows 非管理员下报错
dns:
  fallback: [...]             # 需要 GeoIP 库
  fallback-filter:
    geoip: true               # 缺库 → 整个 DNS 模块失效 → 所有节点超时
```

**为什么 DNS 那两条是致命的**：mihomo 的 DNS 模块一旦初始化失败，连代理服务器域名都解析不出来，表现就是「订阅能导入，但所有节点 Timeout」。看起来像服务器坏了，实际是配置把客户端搞死了。

**原则**：一次只加一处，刷新订阅后先测节点，再继续。改之前先备份：

```bash
cp /var/www/sub/<token>/sub.yaml /var/www/sub/<token>/sub.yaml.bak
```

回滚：

```bash
cp $(ls -t /var/www/sub/*/sub.yaml.bak.* | head -1) $(ls /var/www/sub/*/sub.yaml)
```

---

## 8. 排错决策树

按顺序问自己：

```
订阅能导入吗？
├─ 不能 → 域名解析对不对？dig +short 你的域名
│         ├─ 没返回 104.x → NS / 橙云 / SSL 模式（第 3 节第二步）
│         └─ 返回正常 → 服务器上 curl 本地订阅 200 吗？
│                        ├─ 不是 200 → nginx 没跑或 token 不对
│                        └─ 200 → Cloudflare 的 SSL 模式是 Flexible 吗
└─ 能，但节点 Timeout
   ├─ 服务器日志有连接记录吗？journalctl -u xray -n 30
   │   ├─ 有 → 客户端问题：UUID/路径/Host 头/多开代理软件
   │   └─ 完全没有 → 流量没到服务器
   │                  ├─ 别的代理软件抢流量？（最常见）
   │                  ├─ 手机 TUN 没接管？看 IPv4 是否也直连
   │                  └─ 订阅刚改过？回滚配置
   └─ 订阅能导入、日志有记录、还是不通 → 看 docs/troubleshooting.md
```

**一句经验**：服务器日志一片安静时，**别再改服务器**，问题在客户端。

完整排错手册（含 tcpdump、DoH 查状态、端口扫描脚本）：**[docs/troubleshooting.md](docs/troubleshooting.md)**。

---

## 9. 边界与安全

**能做什么**

- 网页、YouTube、Twitter/X、Telegram、GitHub
- 手机 + 电脑同时用

**不能做什么**

| 限制 | 原因 |
|---|---|
| 游戏、语音、QUIC 可能失败 | Cloudflare 免费版不转发 UDP |
| 延迟 150–400ms | 取决于边缘节点离你多远 |
| 部分站点登录被拒 | 机房 IP 被风控，见 7.1 |
| 域名过期就全断 | 免费域名要每年手动续 |

**安全**

- 订阅地址里那串随机字符**等于密码**，别发群里
- 仓库里不要提交真实 UUID / token / IP（`.gitignore` 已挡）
- 建议关掉 Cloudflare 的 **Bot Fight Mode**（可能误伤正常连接）

---

## 文件结构（部署后）

```
/usr/local/etc/xray/config.json   Xray 配置（VLESS + WS，127.0.0.1:8080）
/etc/nginx/conf.d/vpn.conf        nginx：/ws 反代，/sub/ 静态订阅
/var/www/sub/<token>/sub.yaml     客户端订阅（Clash 配置）
/root/xray-node.txt               节点信息备份
/root/sub-token.txt               订阅 token
/root/clash.yaml                  订阅的原始副本
/root/backup/                     每日备份
/usr/local/bin/traffic-report.sh  流量日报
/usr/local/bin/watchdog.sh        守护
/usr/local/bin/backup-cf.sh       备份
/usr/local/bin/vps-check         只读体检
```

## 脚本清单

| 脚本 | 用途 |
|---|---|
| `scripts/deploy.sh` | 一键部署 |
| `scripts/add-residential.sh` | 加住宅 IP 出口节点 |
| `scripts/remove-residential.sh` | 移除住宅 IP 出口 |
| `scripts/traffic-report.sh` | 流量日报（可推 Telegram） |
| `scripts/watchdog.sh` | 服务守护 |
| `scripts/backup-cf.sh` | 配置备份 |
| `scripts/vps-check.sh` | 只读体检 |
| `scripts/add-443.sh` / `remove-443.sh` | 443 直连实验（多数失败） |

## 参考资料

- [docs/cloudflare-setup.md](docs/cloudflare-setup.md) —— 域名接入、免费域名申请
- [docs/operations.md](docs/operations.md) —— 日报 / 守护 / 备份配置
- [docs/residential-exit.md](docs/residential-exit.md) —— 住宅 IP 出口
- [docs/troubleshooting.md](docs/troubleshooting.md) —— 分层排错
- [docs/build-log.md](docs/build-log.md) —— 一次真实搭建的完整记录

## 免责声明

本项目仅供网络技术学习与研究使用。使用者应遵守所在国家和地区的法律法规，自行承担使用后果。作者不对任何滥用行为负责。

## License

MIT
