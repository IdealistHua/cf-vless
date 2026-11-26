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

## 4.6 改了订阅之后，所有节点突然全超时

这是**自己把自己搞死**的典型。特征是：

- 订阅能正常导入（说明网络和 nginx 都正常）
- 服务器日志一片安静（说明流量根本没发出来）
- 客户端所有节点 `Timeout` / `Error`

### 最常见的原因：DNS 配置

```yaml
# ❌ 这两段是杀手
find-process-mode: strict
dns:
  fallback:
    - https://1.1.1.1/dns-query
  fallback-filter:
    geoip: true
```

- `fallback-filter.geoip: true` 需要 GeoIP 数据库。客户端没有或版本不对，**整个 DNS 模块初始化失败**
- DNS 一挂，连代理服务器的域名都解析不出来 → 所有节点超时
- `find-process-mode: strict` 在 Windows 非管理员权限下也会直接报错

### 怎么确认

看客户端日志（Clash Verge：左侧「日志」；FlClash：工具 → 日志），会有类似：

```
level=error msg="Start initial configuration in progress"
level=error msg="initial proxy failed: ... dns ..."
```

### 怎么修

**立刻回滚**，不要在坏配置上继续调：

```bash
cp $(ls -t /var/www/sub/*/sub.yaml.bak.* | head -1) $(ls /var/www/sub/*/sub.yaml)
```

客户端刷新订阅，节点应该立刻恢复。

### 正确的加法

一次只加一处，加完先测节点再继续：

| 可以加 | 风险 |
|---|---|
| `tcp-concurrent: true` | 低 |
| `unified-delay: true` | 低 |
| `profile.store-fake-ip` | 低 |
| `IP-CIDR,私有网段,DIRECT,no-resolve` | 低 |
| `rule-providers` + `RULE-SET` | 中（规则下载失败会缺规则，但不断网） |
| `GEOSITE,...` | 中（内核没有 geosite 数据会报错） |
| `dns.fallback` + `fallback-filter` | **高，别加** |
| `find-process-mode: strict` | **高，别加** |

---

## 4.7 住宅节点不通 / 分流没生效

| 现象 | 原因 | 处理 |
|---|---|---|
| `住宅-US` 一直 Error | 用了 HTTP 端口，但节点写的是 `socks5` | 回服务商面板看 `Protocol` 下拉，取 SOCKS5 的端口 |
| `住宅-US` 慢到不可用 | 少了 `dialer-proxy` | 节点里必须写 `dialer-proxy: "CF-中转"`，否则客户端会从国内直连美国住宅代理 |
| 分流规则不生效 | 改的是客户端配置 | 改服务端 `sub.yaml`，客户端刷新 |
| 所有流量都走了住宅 | `MATCH` 指向了住宅组 | 改成 `MATCH,节点选择` |
| 住宅 IP 用了几天就失效 | 到期或流量用尽 | 面板看 `Expire date` 和 `Remaining traffic` |
| 网站还是提示地区不支持 | 该站点按账号或地区判定，不是 IP | 换节点对比，或用机场原生节点 A/B |

验证住宅链路是否通（在服务器上跑最直接）：

```bash
curl -x socks5h://USER:PASS@HOST:PORT -s -m 25 https://ipinfo.io/json
```

返回住宅 IP 就说明代理本身没问题，问题在客户端配置。

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

---

## 6. 客户端：两个代理内核在抢流量

**这是最容易被误判成「服务器坏了」的问题。** 我们实际踩过，花了几个小时才找到。

### 症状

- 客户端所有节点 `Timeout`
- 但服务器一切正常：服务 `active`、端口在听、回环测试能通、订阅能拉
- 换手机、换网络（4G）也一样

### 排查

Windows 上列出所有监听端口和对应进程：

```powershell
Get-NetTCPConnection -State Listen | Where-Object LocalPort -ge 7800 |
  Select-Object LocalPort, OwningProcess
```

```powershell
Get-Process -Id <上面查到的PID> | Select-Object Id, ProcessName, Path
```

如果看到**两个代理内核**同时在跑，就是它：

```
12160  iKuuuVPNCore   D:\Program Files\iKuuu_vpn\app\iKuuuVPNCore.exe   监听 7892
10132  verge-mihomo   D:\Program Files\Clash Verge\verge-mihomo.exe     监听 7897
```

系统流量被其中一个截走，送进它自己的死节点，另一个客户端自然全超时。

### 处理

**只留一个代理软件**：

- 托盘图标右键 → 退出（不是关窗口）
- 检查开机自启：任务管理器 → 启动 → 把不用的代理软件禁用
- 手机上同理：设置 → VPN → 确认只有 FlClash 一个

### 判断口诀

> **服务器日志一片安静 = 流量没出来 = 问题在客户端。**
> 这时候修改服务器是浪费时间。

### 顺带：别把配置文件粘进命令行

高发错误：

```
root@vps:~# fallback:
fallback:: command not found
root@vps:~# geoip: true
geoip:: command not found
```

这些是 **YAML 文件里的行**，不是命令。分辨方法：

| 长得像 | 性质 |
|---|---|
| `ls` / `cp` / `bash` / `grep` / `systemctl` 开头 | 命令，粘进终端 |
| 带 `:`、缩进、`- https://`、`proxies:` | 文件内容，只能写进文件 |

另一个高发错误：把 Windows 的 `scp` 命令粘进 SSH 会话里执行。`scp` 必须在 **PowerShell 窗口**（提示符 `PS C:\Users\...>`）跑，不是服务器窗口（提示符 `root@...:~#`）。
