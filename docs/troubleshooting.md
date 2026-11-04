# 排错手册

按「从底层到上层」的顺序查，每一步都有明确的判据，别跳步。

## 第 0 步：先搞清楚断在哪一层

浏览器直接打开你的订阅地址：

```
http://vpn.你的域名/sub/<token>/sub.yaml
```

| 结果 | 说明 | 往下看 |
|---|---|---|
| 能下载到 YAML | 域名 / Cloudflare / nginx 全活着 | **第 3 节**（节点侧） |
| 502 / 522 / 525 | 到了 Cloudflare，但源站有问题 | **第 2 节**（源站侧） |
| 超时 / 打不开 | DNS 或 Cloudflare 代理有问题 | **第 1 节**（接入侧） |

---

## 1. 接入层：域名和 Cloudflare

### 1.1 域名解析对不对

```bash
dig +short A vpn.你的域名 @1.1.1.1
```

- 返回 `104.x` / `172.67.x` → 正常，橙云代理生效
- 返回 `你的服务器IP` → 记录是**灰云**（DNS only），去 Cloudflare 点亮橙云
- 返回空 / NXDOMAIN → 见下面

### 1.2 拿权威答案（区分「不存在」和「没生效」）

```bash
curl -s -H 'accept: application/dns-json' \
  'https://1.1.1.1/dns-query?name=vpn.你的域名&type=A'
```

看 `"Status"`：

| Status | 含义 | 处理 |
|---|---|---|
| `0` + 有 `"Answer"` | 有记录 | 正常 |
| `0` + 无 `"Answer"` | 名字在、记录类型不对 | 检查 Type 是不是 A |
| `3` | NXDOMAIN，名字不存在 | 删记录重加；或 NS 指向了旧 zone |

### 1.3 NS 委派对不对

```bash
dig +short NS 你的域名 @1.1.1.1
```

应该返回两个 `*.ns.cloudflare.com`。如果返回 `dns1.digitalplat.org` 之类，说明域名商的 NS 还没改或没保存。

⚠️ 必须和 Cloudflare **Overview** 页显示的 nameservers **逐字一致**。域名加过两次的话，两套 NS 不同，填错了就会出现「面板里记录正常，公网却查不到」。

---

## 2. 源站层：nginx 和端口

### 2.1 服务活着吗

```bash
systemctl status xray nginx --no-pager
```

### 2.2 端口在听吗

```bash
ss -tlnp | grep -E ':80 |:8080 '
```

正确结果：

```
LISTEN 0 511  0.0.0.0:80        ← nginx
LISTEN 0 4096 127.0.0.1:8080    ← xray（必须是 127.0.0.1，不能是 0.0.0.0）
```

如果 8080 绑在 `0.0.0.0`，说明 Xray 配置里 `listen` 没写 `127.0.0.1`——能用，但不该暴露。

### 2.3 本地能不能取到订阅

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/sub/<token>/sub.yaml
```

- `200` → nginx 正常
- `404` → `location /sub/` 的 alias 路径不对，或 token 目录不存在

### 2.4 Cloudflare 返回 522 / 525

| 状态码 | 含义 | 处理 |
|---|---|---|
| 522 | Cloudflare 连不上源站 | 源站 80 没起来，或被防火墙挡了 |
| 525 | SSL 握手失败 | SSL 模式不是 **Flexible** |
| 521 | 源站拒绝连接 | nginx 挂了 |

---

## 3. 节点层：Xray 和 WebSocket

### 3.1 Xray 日志（最有信息量）

```bash
journalctl -u xray -n 50 --no-pager
```

正常收到连接时会看到类似：

```
accepted tcp:... from ...
proxy/vless/outbound: tunneling request to tcp:xxx.com:443 via ...
```

如果**完全没有新日志**，说明请求根本没到 Xray（问题在 nginx 或更前面）。

### 3.2 服务端回环测试（判断配置本身对不对）

在服务器上起一个临时客户端，绕过 Cloudflare 直接连本机：

```bash
cat > /tmp/c.json <<'EOF'
{
  "log": {"loglevel": "info"},
  "inbounds": [{"listen":"127.0.0.1","port":10808,"protocol":"socks","settings":{"udp":false}}],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext":[{"address":"127.0.0.1","port":80,
      "users":[{"id":"你的UUID","encryption":"none"}]}]},
    "streamSettings": {"network":"ws","security":"none",
      "wsSettings":{"path":"/ws","headers":{"Host":"你的域名"}}}
  }]
}
EOF

xray run -c /tmp/c.json > /tmp/c.log 2>&1 &
sleep 2
curl -s --max-time 12 -x socks5h://127.0.0.1:10808 https://ipinfo.io/ip || echo "失败"
tail -15 /tmp/c.log
kill %1 2>/dev/null
```

- 返回服务器 IP → 服务端配置正确，问题在 Cloudflare 或客户端
- 返回失败 → 看 `/tmp/c.log`，通常是 UUID 不匹配或 WS 路径不对

### 3.3 客户端侧

| 现象 | 原因 |
|---|---|
| 节点测速 Timeout，订阅能拉 | WS 路径 / Host 头不匹配 |
| 测速正常但浏览器还是国内 IP | **系统代理没打开** |
| 部分网站打不开 | UDP 走不通（CF 免费版不转发 UDP） |

**「测速通但浏览器显示国内 IP」是最常见的假故障**：节点握手成功证明链路通，只是 Clash 没接管系统流量。去 Clash Verge **首页 → 系统代理** 打开；或 Windows 设置 → 网络 → 代理，确认是 `127.0.0.1:7890`。

---

## 4. 确认是 IP 被墙（不是配置问题）

当直连方案（REALITY 443）Timeout 时，用这套方法证明「是链路问题，不是配置问题」。

### 4.1 服务端：抓包看请求到没到

```bash
tcpdump -ni any 'tcp port 443 or tcp port 80' -c 30
```

- 有 SYN 进来，没有 SYN-ACK 回去 → 出站被拦
- **连 SYN 都没有** → 请求在中间就被丢了（IP/端口被墙）

### 4.2 客户端：端口扫描对照

Windows PowerShell：

```powershell
$ports = 22,80,443,8443,2053,2083,2087,2096
foreach ($p in $ports) {
  $c = New-Object System.Net.Sockets.TcpClient
  $ok = $false
  try { $null = $c.ConnectAsync("你的服务器IP", $p); $ok = $c.Connected } catch { $ok = $false }
  $c.Close()
  "$p`t$ok"
}
```

判据：

| 结果 | 结论 |
|---|---|
| 22 ✓、80 ✓、443 ✗ | 典型：**IP 的 443 被针对**，其他端口还活着 |
| 22 ✓、80 ✓、443 ✓，但节点仍 Timeout | 端口通但协议被识别，考虑换方案 |
| 全部 ✗ | IP 整体被封，需要换 IP |

对照组（排除本地网络问题）：

```powershell
Test-NetConnection www.cloudflare.com -Port 443
```

如果这个 `True` 而你的 IP `False`，就确认是针对性封锁。

---

## 4.5 「端口通，但 TLS 永远失败」怎么判断

这是最容易被误判的一种情况：**端口探测显示 443 开放，客户端却始终 Timeout**。

### 现象

```
Test-NetConnection IP -Port 443   → True     ← 端口扫描认为通
客户端节点测速                     → Timeout  ← 实际用不了
```

端口扫描只做 TCP 三次握手，握手成功不代表能传数据。GFW 可以是「放行 SYN，识别到 TLS 后注入伪造 RST」——扫描器看到通，真实连接被掐断。

### 判定方法：tcpdump + 服务端日志

**第一步**，服务端抓包：

```bash
timeout 40 tcpdump -ni any 'tcp port 443 and host <你的家宽公网IP>' -c 20
```

**第二步**，客户端立刻点一次测速。

**第三步**，看结果：

| tcpdump 看到 | 服务端 `journalctl -u xray` | 结论 |
|---|---|---|
| 只有 `[S]`，无回包 | 无日志 | 端口被封，SYN 都没到 |
| `[S]` → `[S.]` → `[.]`，然后出现 `[R]` | **完全无日志** | **TLS 层被 RST**，应用层没收到数据 |
| `[S]` → `[S.]` → `[.]`，之后有数据 | 有 `accepted tcp` | 通了，问题在别处 |

第二种最关键：**TCP 建连成功，但 Xray 日志一行都没有**，说明 ClientHello 在到达应用层之前就被中间设备打断。

那个 `[R]` 包的源地址看起来是「客户端」，像是客户端主动断开——其实是伪造的。判据是它紧跟 SYN-ACK 之后出现，且 seq 对得上。

### 结论

这种情况**与配置无关**，改 UUID、换 SNI、换 flow 都无效，因为数据在出国那一跳就没了。

唯一出路：

1. 换 IP（RackNerd 工单）
2. 走 CDN（本项目的方案，流量从 80 端口经 Cloudflare 进来）
3. 换到其他地区的服务器

> 附带教训：**不要用端口扫描判断「能不能用」**。它只能证明 SYN 能到，不能证明数据能过。

---

## 5. 应急：IP 被彻底封了怎么办

RackNerd 支持免费换 IP（开工单，一般几小时内回复）：

```
Subject: Request IP replacement - IP blocked in China

Hello,

My VPS (hostname: xxxx, primary IP: x.x.x.x) has been blocked by the GFW.
Ports 443 and most high ports are unreachable from China, which makes the
server unusable for my legitimate use.

Could you please assign a new IPv4 address to this VPS?
I'm happy to reinstall the OS if needed.

Thank you.
```

⚠️ 换 IP 后记得同步更新 Cloudflare 的 A 记录，否则 CDN 会指向旧 IP（表现为 522）。

> 注意：如果已经在用本项目的 Cloudflare 方案，**IP 被墙的影响会小很多**——因为流量从 80 端口经 CF 进来，443 被封不影响。真正需要换 IP 的场景是「连 80 端口都被封」。
