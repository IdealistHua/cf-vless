# 域名接入 Cloudflare（含免费域名方案）

整套方案依赖一个**能改 NS 的域名**。不需要备案、不需要买证书，但必须能把域名整体托管给 Cloudflare。

## 一、域名从哪来

### 方案 A：免费域名（推荐先试）

**DigitalPlat FreeDomain** —— 支持改 NS，可整域托管 Cloudflare，不绑卡不实名。

1. 打开 <https://dash.domain.digitalplat.org/>，用 GitHub 账号登录
2. 认领一个前缀，后缀选 **`.dpdns.org`**（`.us.kg` 也可；过于冷门的后缀可能被 Cloudflare 拒绝）
3. 得到形如 `yourname.dpdns.org` 的域名

⚠️ **每年必须回面板手动 Renew 一次**，否则域名被回收，整套服务失效。

### 方案 B：买一个

阿里云 / 腾讯云的 `.top`、`.xyz` 首年通常 9–30 元，实名认证即可，**不需要备案**（只要不解析到境内服务器做网站）。

### 不能用的情况

| 服务 | 原因 |
|---|---|
| Freenom（`.tk` `.ml` `.ga`） | 已停止新注册，网上教程全部过期 |
| is-a.dev | 只支持 A/CNAME/TXT 记录，**不能改 NS**，无法托管 Cloudflare |
| `nic.eu.org` | 人工审核，可能等数周 |

## 二、接入 Cloudflare

### 1. 添加站点

Cloudflare 控制台 → **Add a site** → 输入你的域名 → 选 **Free** 计划。

### 2. 记下分配的两个 NS

添加完成后页面会显示：

```
xxx.ns.cloudflare.com
yyy.ns.cloudflare.com
```

名字是随机的，**必须逐字复制**。

### 3. 回域名商改成这两个 NS

DigitalPlat 的话：域名管理页 → **「使用其他名称服务器」** → 删除原有的 `dns1/dns2.digitalplat.org` → 填入上面两个 `*.ns.cloudflare.com` → 保存。

⚠️ 只能填 NS，**不要填 IP**。DigitalPlat 做的是纯委派，不提供普通 DNS 记录编辑。

### 4. 等激活

一般 3–5 分钟，Cloudflare 顶部状态从 Pending 变成 **Active**。

自查：

```bash
dig +short NS 你的域名 @1.1.1.1
```

返回两个 `ns.cloudflare.com` 就说明委派成功。

### 5. 加 A 记录

Cloudflare → **DNS → Records → Add record**：

| Type | Name | Content | Proxy status | TTL |
|---|---|---|---|---|
| `A` | `vpn` | `你的服务器 IP` | **Proxied**（橙云） | Auto |

保存后立刻验证（直接问公共 DNS，秒出结果）：

```bash
dig +short A vpn.你的域名 @1.1.1.1
```

应该返回 `104.x.x.x` 或 `172.67.x.x`（Cloudflare 的 Anycast IP）。

### 6. 关键：SSL/TLS 模式改成 Flexible

**SSL/TLS → Overview → Configure → Flexible**

原理：

| 模式 | Cloudflare → 源站 | 能不能用 |
|---|---|---|
| Off | 明文 | 不安全，不用 |
| **Flexible** | **明文 HTTP / 80** | ✅ 源站 443 被墙时唯一可行 |
| Full | HTTPS / 443 | ❌ 源站 443 封了就连不上 |
| Full (strict) | HTTPS + 校验证书 | ❌ 同上 |

因为整套方案的设计前提就是「源站 443 不可达」，所以**必须 Flexible**，让 Cloudflare 用 80 端口回源。

## 三、常见坑

### 记录加了但解析不到（NXDOMAIN）

```bash
curl -s -H 'accept: application/dns-json' \
  'https://1.1.1.1/dns-query?name=vpn.你的域名&type=A'
```

- `"Status": 0` + 有 `"Answer"` → 正常
- `"Status": 3` → 权威服务器上没有这个名字

Status 3 的常见原因：

1. 记录名填成了**全名** `vpn.example.com`，Cloudflare 拼成 `vpn.example.com.example.com`
2. 记录没保存成功（删掉重加一次，加完刷新页面确认）
3. DigitalPlat 里填的 NS 是**旧 zone 的**（域名加过两次，NS 对不上）。核对 Cloudflare **Overview** 页显示的 nameservers 和 DigitalPlat 里的是否一致

### 订阅拉取 502

`502 Bad Gateway` 说明请求没到你的 nginx（nginx 静态文件只会返回 404）。常见于本机 Clash 的系统代理/TUN 劫持了自己的请求。临时关掉代理再导入。

### 忘了关 Bot Fight Mode

Cloudflare **Security → Bots** 里的 Bot Fight Mode 可能误伤 WebSocket 连接，建议保持关闭。
