# 从零搭建：Cloudflare + VLESS/WebSocket 科学上网

> 一台 1 核 1G 的小 VPS，加一个域名，就能搭一套稳定可用的梯子。
> 全程照着做，大约 40 分钟。不需要懂网络原理，命令都是复制粘贴。

**最终效果**：Windows 和安卓手机上，打开 Clash 类客户端，选一个节点，就能访问外网。

---

## 目录

1. [你需要准备什么](#1-你需要准备什么)
2. [它是怎么工作的](#2-它是怎么工作的)
3. [第一步：登录服务器](#3-第一步登录服务器)
4. [第二步：域名接进 Cloudflare](#4-第二步域名接进-cloudflare)
5. [第三步：一键部署](#5-第三步一键部署)
6. [第四步：客户端导入](#6-第四步客户端导入)
7. [第五步：验证](#7-第五步验证)
8. [日常维护](#8-日常维护)
9. [卡住了怎么办](#9-卡住了怎么办)
10. [可选：加一个 443 直连节点](#10-可选加一个-443-直连节点)

---

## 1. 你需要准备什么

| 东西 | 说明 | 花费 |
|---|---|---|
| **一台 VPS** | 1 核 1G 够用，Ubuntu 22.04 / 24.04 系统 | 约 $15–25/年 |
| **一个域名** | 免费域名也可以，见 [docs/cloudflare-setup.md](docs/cloudflare-setup.md) | 0 或 ¥10/年 |
| **Cloudflare 账号** | Free 计划足够，注册免费 | 0 |
| **一个客户端** | Windows 用 Clash Verge Rev，安卓用 FlClash | 0 |

### 关于 VPS

买的时候只看两个参数：

- **系统选 Ubuntu 24.04**（本文所有命令都按这个写）
- **内存 1G 就够**（Xray 常驻只占 50–80MB）

带宽、流量一般不用纠结，1T/月对个人使用绰绰有余。

买完商家会给你：**IP 地址**、**root 密码**、**SSH 端口**（通常是 22）。

### 关于客户端

⚠️ 必须用 **mihomo 内核**的客户端，老版 Clash for Windows / ClashX **不支持** VLESS，装了也用不了。

| 平台 | 推荐 | 下载地址 |
|---|---|---|
| Windows | Clash Verge Rev | https://github.com/clash-verge-rev/clash-verge-rev/releases |
| Android | FlClash | https://github.com/chen08209/FlClash/releases |
| macOS | Clash Verge Rev | 同上 |

---

## 2. 它是怎么工作的

```
   你的设备                   Cloudflare                 你的 VPS
┌──────────┐   加密连接   ┌──────────────┐   普通 HTTP  ┌─────────────────┐
│ Clash    │────────────▶│  全球边缘节点  │────────────▶│ nginx   :80     │
│ FlClash  │   (TLS)     │              │    (:80)    │  ├ /ws  → Xray   │
└──────────┘             └──────────────┘             │  └ /sub → 订阅   │
                                                      └────────┬────────┘
                                                               │
                                                               ▼
                                                          目标网站
```

三句话讲完：

1. 你的设备连的是 **Cloudflare**，不是直接连 VPS。Cloudflare 在全球有节点，国内可以正常访问。
2. Cloudflare 再把流量转给你的 VPS（这一步走普通 HTTP，80 端口）。
3. VPS 上的 Xray 收到后，替你去访问目标网站。

**好处**：外界看到的是你和 Cloudflare 之间的正常 HTTPS 流量，看不到你真正连的服务器。VPS 的 IP 不暴露，也就不容易被针对。

---

## 3. 第一步：登录服务器

### Windows

按 `Win + X`，选 **终端** 或 **Windows PowerShell**，输入（把 IP 换成你的）：

```powershell
ssh root@你的服务器IP
```

第一次连接会问 `Are you sure you want to continue connecting?`，输入 `yes` 回车。

然后输入密码（**输入时屏幕上不显示任何字符，这是正常的**，打完直接回车）。

### 成功的标志

看到类似这样的提示符，就登进去了：

```
root@racknerd-xxxxx:~#
```

### 先做一件事：更新系统

```bash
apt update && apt upgrade -y
```

这一步可能要几分钟。如果中途弹出紫色/蓝色的配置界面，直接按回车用默认值。

> 💡 之后所有命令都在这个窗口里敲。命令前面的 `#` 或 `$` 是提示符，**不要复制进去**。

---

## 4. 第二步：域名接进 Cloudflare

### 4.1 把域名加进 Cloudflare

1. 登录 https://dash.cloudflare.com
2. 点 **Add a site**，输入你的域名
3. 选 **Free** 计划
4. Cloudflare 会给你**两个名称服务器**，长得像：

```
xxx.ns.cloudflare.com
yyy.ns.cloudflare.com
```

**先把这两个记下来。**

### 4.2 回域名商改 NS

去你买域名的地方（阿里云、Namesilo、DigitalPlat……），找到 **DNS 服务器 / Nameservers** 设置，把原来的删掉，填上 Cloudflare 给的那两个。

保存后回 Cloudflare 点 **Check nameservers**。生效通常几分钟到几小时，Cloudflare 会发邮件通知。

> 免费域名（DigitalPlat）的完整操作步骤见 [docs/cloudflare-setup.md](docs/cloudflare-setup.md)。

### 4.3 加一条 A 记录

Cloudflare 里进入 **DNS → Records → Add record**：

| 字段 | 填什么 |
|---|---|
| Type | `A` |
| Name | `vpn`（或者你喜欢的，比如 `node`、`us1`） |
| IPv4 address | 你的 VPS IP |
| Proxy status | **Proxied（橙色云）** ← 必须橙色 |
| TTL | Auto |

点 Save。

**验证一下**，在服务器上敲：

```bash
dig +short vpn.你的域名.com
```

应该返回一个 `104.x.x.x` 或 `172.67.x.x` 的地址（Cloudflare 的 IP，不是你 VPS 的）。

- ✅ 返回 `104.x` / `172.67.x` → 成功
- ❌ 返回你自己的 VPS IP → 云朵没点成橙色
- ❌ 什么都没返回 → NS 还没生效，等一会儿再试

### 4.4 改 SSL 模式

左侧 **SSL/TLS → Overview**，模式选 **Flexible**。

> 必须是 Flexible。选 Full 的话 Cloudflare 会尝试用 HTTPS 回源，而你的服务器只开了 80，会直接 522 报错。

---

## 5. 第三步：一键部署

回到 SSH 窗口，**把 `vpn.你的域名.com` 换成你刚才建的域名**，然后执行：

```bash
curl -fsSL https://raw.githubusercontent.com/IdealistHua/cf-vless/main/scripts/deploy.sh -o deploy.sh
```

```bash
bash deploy.sh vpn.你的域名.com
```

脚本会自动做完这些事（大约 1–2 分钟）：

| 步骤 | 做什么 |
|---|---|
| 1 | 装依赖：curl、openssl、nginx |
| 2 | 开启 BBR（提升传输速度） |
| 3 | 安装 Xray，生成随机 UUID |
| 4 | 写 Xray 配置：VLESS + WebSocket，只监听本机 8080 |
| 5 | 写 nginx 配置：80 端口对外，`/ws` 转给 Xray，`/sub/` 放订阅 |
| 6 | 生成 Clash 订阅和节点信息 |
| 7 | 自检并打印结果 |

### 成功的标志

最后会打印一块信息，长这样：

```
============================================
  部署完成
============================================
IP        : 1.2.3.4
域名      : vpn.你的域名.com
端口      : 443
UUID      : xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
传输      : VLESS + WebSocket + TLS (CDN)
WS 路径   : /ws
Host 头   : vpn.你的域名.com
订阅      : http://vpn.你的域名.com/sub/xxxxxxxx/sub.yaml
============================================
```

**把「订阅」那一行完整复制下来**，下一步要用。

自检部分应该看到两个 `200`：

```
sub HTTP 200
via-CDN sub HTTP 200
```

两个都是 200 就说明服务器这边全通了。

> 📌 这些信息也备份在服务器上：`/root/xray-node.txt`。忘了订阅地址就 `cat /root/xray-node.txt` 看一眼。

---

## 6. 第四步：客户端导入

### Windows：Clash Verge Rev

1. 打开 Clash Verge Rev
2. 左侧点 **订阅**
3. 顶部输入框粘贴订阅地址，点 **导入**
4. 导入成功后，左侧点 **代理**，应该能看到一个节点（名字类似 `CF-VLESS`）
5. 点一下节点选中它
6. 回到 **设置**，打开 **系统代理**

### Android：FlClash

1. 打开 FlClash，底部点 **配置**
2. 右上角 **+** → **从 URL 导入**
3. 粘贴订阅地址，确定
4. 回到 **代理** 页，选中节点
5. 打开底部的总开关

> ⚠️ **只开一个代理软件**。如果电脑上还装着别的 VPN 客户端（机场客户端、其他 Clash），先彻底退出（托盘图标右键 → 退出），否则两个内核会抢流量，表现就是「节点全部超时但服务器一切正常」。

---

## 7. 第五步：验证

### 看出口 IP

浏览器打开 https://ipinfo.io/json

应该看到：

```json
{
  "ip": "你的VPS IP",
  "city": "Los Angeles",
  "country": "US",
  "org": "AS36352 HostPapa"
}
```

- ✅ `country` 是 `US`（或其他境外国家）→ 成功
- ❌ `country` 是 `CN`，IP 是你家宽带 → 系统代理没开

### 看延迟

Clash Verge 的 **代理** 页，节点右边会显示延迟数字（比如 `350`）。

- ✅ 有数字 → 通
- ❌ `Timeout` / `Error` → 看下一节

### 三个常见故障

| 现象 | 先查这个 |
|---|---|
| 节点 Timeout，但订阅能导入 | 服务器上 `ss -tlnp \| grep 8080`，Xray 有没有在跑 |
| 订阅也导入不了 | `dig +short 你的域名` 有没有返回 `104.x` |
| 网页打不开但延迟有数字 | Clash 里模式选的是「规则」还是「直连」 |

更多排错见 [docs/troubleshooting.md](docs/troubleshooting.md)。

---

## 8. 日常维护

### 换订阅链接（怀疑泄露时）

```bash
NEW=$(openssl rand -hex 16)
echo "$NEW" > /root/sub-token.txt
mkdir -p /var/www/sub/$NEW
cp /root/clash.yaml /var/www/sub/$NEW/sub.yaml
echo "新订阅：http://你的域名/sub/$NEW/sub.yaml"
```

然后在客户端里删掉旧订阅，重新导入新的。

### 看服务状态

```bash
systemctl status xray nginx --no-pager
```

两个都要 `active (running)`。

### 看日志

```bash
journalctl -u xray -n 50 --no-pager
```

### 重启

```bash
systemctl restart xray nginx
```

### 看用了多少流量

```bash
apt install -y vnstat
vnstat -m
```

按月份列出收发流量。VPS 商家的控制面板里也有统计，两边数字可能略有差异（统计口径不同）。

---

## 9. 卡住了怎么办

### 命令报错「command not found」

命令敲错了，或者前面多复制了字符。重新手打一遍，**不要从聊天窗口整段复制带格式的文字**。

### 粘贴长命令后终端乱套

按 `Ctrl + C` 中断，回到提示符重新来。

### 部署脚本跑一半失败

先看报错最后一行。最常见的两个：

- `nginx: command not found` → 依赖没装上，重跑 `apt install -y nginx`
- `xray: command not found` → Xray 没装上，检查服务器能不能访问外网

### 全部检查都没问题但还是连不上

按这个顺序排查（详细版见 [docs/troubleshooting.md](docs/troubleshooting.md)）：

1. `systemctl status xray nginx` —— 两个服务都活着吗
2. `ss -tlnp | grep -E ':80 |:8080 '` —— nginx 占 80、xray 占 8080 吗
3. `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/sub/<token>/sub.yaml` —— 本地订阅 200 吗
4. `journalctl -u xray -n 30` —— 有连接进来的日志吗

**如果服务器日志里一片安静（没有任何连接记录），问题就在客户端**，别再去改服务器了——检查是不是有第二个代理软件在跑。

---

## 10. 可选：加一个 443 直连节点

前面 1–9 步做完，梯子已经能用了。这一节是**可选项**——不装也完全不影响使用。

### 为什么要加

默认方案的所有流量都绕道 Cloudflare。多一跳中转，换来的是抗封锁，代价是：

- 延迟多 50–150ms
- **不支持 UDP**（游戏、语音通话、QUIC 会失败）

如果你服务器的 443 能直连，可以再加一个「不经 Cloudflare」的节点：

| | 直连 443 | 经 Cloudflare |
|---|---|---|
| 延迟 | 低 | 高一截 |
| UDP | 支持 | 不支持 |
| IP 暴露 | 暴露 | 隐藏 |
| 抗封锁 | 弱 | 强 |

两个节点同时存在，平时用直连，直连挂了切 CF，是最舒服的状态。

### 先说清楚风险

**不是每台服务器都能用 443 直连。** 机房 IP 的 443 是最容易被针对的端口——GFW 不封 SYN，而是等你发 TLS 握手时注入 RST 打断。表现就是：

```
端口扫描显示 443 开放      ← 假象
节点测速永远 Timeout        ← 真相
```

这种封锁**在应用层完全看不出来**：服务器上 Xray 日志一行都没有，因为它压根没收到数据。所以加之前要有心理准备：**大概率失败，失败不亏**。

### 怎么加

```bash
bash scripts/add-443.sh 你的域名
```

脚本会：

1. 备份现有配置
2. 生成新的 REALITY 密钥对（并校验 43 字符长度、反推公钥验证配对）
3. 追加一个监听 443 的 inbound，`dest` 伪装成 `www.tesla.com:443`
4. 重写订阅，变成两个节点：`直连-洛杉矶` + `CF-中转`
5. `xray -test` 失败自动回滚

然后在客户端刷新订阅，测一下 `直连-洛杉矶`。

### 怎么判断成功还是被封

| 现象 | 结论 | 该做什么 |
|---|---|---|
| 测速有数字（150–200ms） | ✅ 能用 | 留着，设为常用节点 |
| Timeout，但服务器日志有连接记录 | 应用层问题 | 查 UUID / 公钥 / ShortID 是否配对 |
| Timeout，服务器日志**完全空白** | ❌ 443 被 RST | 执行下面的清理 |

第三种情况可以用 tcpdump 确认（详见 [docs/troubleshooting.md](docs/troubleshooting.md) 第 4.5 节）：

```bash
timeout 40 tcpdump -ni any 'tcp port 443 and host <你的公网IP>' -c 20
```

看到 `[S] → [S.] → [.] → [R]`，同时 Xray 日志什么都没有，就是被中间设备打断了。

### 失败就清掉

```bash
bash scripts/remove-443.sh 你的域名
```

删掉 443 的 inbound、重写订阅为单节点，回到第 9 步的干净状态。**主方案完全不受影响。**

### 一句话总结

> 443 直连是「锦上添花」，Cloudflare 中转是「雪中送炭」。
> 先保证能用，再追求更快。

---

## 附：这套方案的边界

**能做什么**

- 网页浏览、YouTube、Twitter/X、Telegram、GitHub
- 手机和电脑同时用（把订阅地址填到多个设备）

**不能做什么**

| 限制 | 原因 |
|---|---|
| 游戏、语音通话、QUIC 类应用可能失败 | Cloudflare 免费版只转发 HTTP/HTTPS，不转发 UDP |
| 延迟偏高（150–400ms） | 取决于 Cloudflare 分配的边缘节点离你多远 |
| 部分网站的登录被拒（如 LinkedIn） | 机房 IP 被目标站点的风控拦，与配置无关 |
| 域名过期就全断 | 免费域名要每年手动续期 |

**安全提醒**

- 订阅地址里的那串随机字符**等于密码**，不要发到群里或论坛
- 仓库里不要提交真实的 UUID、订阅 token、服务器 IP
- 建议关掉 Cloudflare 的 **Bot Fight Mode**（可能误伤正常连接）

---

## 参考资料

- [docs/cloudflare-setup.md](docs/cloudflare-setup.md) —— 域名和 Cloudflare 的详细操作、免费域名申请
- [docs/troubleshooting.md](docs/troubleshooting.md) —— 分层排错手册
- [docs/build-log.md](docs/build-log.md) —— 一次真实搭建的完整记录，含所有踩过的坑

## 免责声明

本项目仅供网络技术学习与研究使用。使用者应遵守所在国家和地区的法律法规，自行承担使用后果。作者不对任何滥用行为负责。

## License

MIT
