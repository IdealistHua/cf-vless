# 实战记录：从零到可用（含全部踩坑）

> 这份文档记录了一次真实搭建的完整过程 —— 包括走过的弯路。
> README 讲「怎么做对」，这里讲「为什么这么做」和「哪里会错」。
>
> 环境：RackNerd 1C1G / Ubuntu 24.04 / Xray 26.x / Cloudflare Free / DigitalPlat 免费域名
> 时间：2026-10-31 ~ 2026-11-02

---

## 阶段 0：选型

目标很朴素：一台 VPS，能稳定科学上网，Windows 和安卓都能用。

第一版选了 **VLESS + XTLS-Vision + REALITY**，理由是：

- 不需要域名和证书
- 抗主动探测（没有 TLS 指纹特征）
- 内存占用小，1G 的小鸡扛得住

配置本身没问题，**问题出在一个后来才发现的前提上：它要求客户端的 443 端口能连到你的服务器。**

---

## 阶段 1：REALITY 直连失败

### 现象

服务器侧一切正常：

```
systemctl status xray        → active (running)
ss -tlnp | grep 443          → LISTEN *:443
xray -test                   → Configuration OK.
```

客户端侧全灭：

```
Clash Verge Rev  节点测速 → Timeout
FlClash（4G 流量）        → 失败
同页 DIRECT 测试          → 313 ms，正常
```

### 关键的一步：服务端回环测试

这一步值 90% 的排查时间。在服务器上起一个临时客户端，自己连自己：

```bash
# 用与线上完全相同的 UUID / 公钥 / shortId / SNI
cat > /tmp/client.json <<'JSON'
{
  "log": {"loglevel": "info"},
  "inbounds": [{"listen":"127.0.0.1","port":10808,"protocol":"socks","settings":{"udp":false}}],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext":[{"address":"127.0.0.1","port":443,
      "users":[{"id":"<UUID>","flow":"xtls-rprx-vision","encryption":"none"}]}]},
    "streamSettings": {"network":"tcp","security":"reality",
      "realitySettings":{"serverName":"<SNI>","fingerprint":"chrome",
        "publicKey":"<PUB>","shortId":"<SID>"}}
  }]
}
JSON

nohup xray run -c /tmp/client.json > /tmp/client.log 2>&1 &
sleep 3
curl -s --max-time 12 -x socks5h://127.0.0.1:10808 https://ipinfo.io/ip
```

返回 `107.150.2.73`（自己的 IP），日志里出现：

```
proxy/vless/outbound: tunneling request to tcp:ipinfo.io:443 via 127.0.0.1:443
```

**结论：服务端配置、密钥配对、REALITY 握手全部正确。** 问题在「中国 → 服务器」这一段。

> 💡 这个测试是整个排查过程里最有价值的一步。它把「服务端问题」和「链路问题」一刀切开，避免在错误的层里瞎改。

### 端口逐个体检

在 Windows 上用 PowerShell 扫一遍：

```powershell
$ports = 22,80,443,8443
foreach ($p in $ports) {
  $c = New-Object System.Net.Sockets.TcpClient
  try { $null = $c.ConnectAsync("107.150.2.73", $p).Wait(2500); $ok = $c.Connected } catch { $ok = $false }
  $c.Close()
  "$p`t$ok"
}
```

结果：

| 端口 | 结果 | 说明 |
|---|---|---|
| 22 | True | SSH 在用，基准 |
| 80 | True | 通 |
| 443 | False | **被封** |
| 8443 | False | 换端口也没用 |
| 2053/2083/2087/2096/4443/8443/2095/34567 | 全 False | 高位端口一并封死 |

对照组：`Test-NetConnection www.cloudflare.com -Port 443` → **True**。

**说明你的网络本身不封 443，是这个 IP 的 443 被针对了。**

### 为什么端口 80 还活着

推测是运营商对 80 端口做了透明代理/审查，TCP 能建连，但 TLS 握手会被吞。这也解释了后面为什么必须把流量塞进 80 —— 它不是「完全没问题」，而是「能通，但只认 HTTP」。

---

## 阶段 2：换思路，走 Cloudflare

既然直连没戏，就把流量藏进 80 端口，让 Cloudflare 中转：

```
客户端 ──TLS(443)──▶ Cloudflare 边缘 ──HTTP(80)──▶ VPS
```

代价是延迟（190ms），收益是**抗封锁**：GFW 看到的是你和 Cloudflare 之间的正常 TLS，看不到后面的 VPS。

### 域名

先用 DigitalPlat 的免费域名（`.dpdns.org`）。申请要点：

- 需要 GitHub 账号授权登录
- **支持修改 NS**（这是它能接 Cloudflare 的关键；`is-a.dev` 之类只支持 A/CNAME 记录的就不行）
- 每年要手动 Renew，否则回收

### Cloudflare 接入

1. Add site → 填域名 → Free 计划
2. Cloudflare 给你两个 NS，形如 `xxx.ns.cloudflare.com`
3. 回 DigitalPlat 的「使用其他名称服务器」，删掉默认的 `dns1/dns2.digitalplat.org`，填上这两个
4. 等 Cloudflare 显示 Active
5. 加 A 记录：名字随意（如 `vpn`），内容填 VPS IP，**橙色云 Proxied**
6. SSL/TLS 模式改成 **Flexible**（因为回源走 80，不是 443）

### 这里踩的坑

**坑 1：NXDOMAIN 卡了很久**

```bash
dig +short vpn.example.com        # 空
```

看起来像 NS 没生效，其实是**记录没建好**。用 DoH 拿精确状态，绕过本机解析器：

```bash
curl -s -H 'accept: application/dns-json' \
  'https://1.1.1.1/dns-query?name=vpn.example.com&type=A'
```

返回 `"Status":3` = NXDOMAIN（域名不存在），而不是解析失败。再看 AUTHORITY 段是 `kpip.ns.cloudflare.com` 的 SOA —— 说明 zone 已经接管了，只是记录不存在。

删掉记录重新 Add 一次，再查就变成：

```json
{"Status":0,"Answer":[{"type":1,"TTL":300,"data":"104.21.16.135"}]}
```

**坑 2：`dig @NS主机名` 报错**

```
dig: couldn't get address for 'kpip.ns.cloudflare.com': not found
```

服务器自己的 DNS 解析不了这个主机名，直接指定 `@1.1.1.1` 就行。

**坑 3：SSL 模式选成 Full**

默认可能是 Full，那样 Cloudflare 会尝试用 443 回源，而你的 443 是封的 → 522/525。必须 **Flexible**。

---

## 阶段 3：服务端改造

### Xray 换成 VLESS + WebSocket

关键配置（`/usr/local/etc/xray/config.json`）：

```json
{
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": 8080,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "<UUID>"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {"path": "/ws"}
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
```

**只监听 `127.0.0.1`**，不对外暴露 8080。

### nginx 反代

```nginx
server {
    listen 80 default_server;
    server_name _;

    location /ws {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location /sub/ {
        alias /var/www/sub/;
        add_header Cache-Control "no-store";
    }

    location / { return 404; }
}
```

`Upgrade` / `Connection` 两个头是 WebSocket 的关键，漏了会变成 400 或连接立即断开。

### 自检

```bash
# 本地订阅（不经过 CDN）
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/sub/<token>/sub.yaml

# 经 CDN 订阅
curl -s -o /dev/null -w '%{http_code}\n' http://vpn.example.com/sub/<token>/sub.yaml
```

两个都要 `200`。

---

## 阶段 4：客户端 —— 最坑的一段

服务端已经证明没问题了，但 Clash Verge 里节点还是 Timeout。

### 排查过程

```powershell
# 1. 系统代理开着吗？看出口 IP
curl.exe -s https://ipinfo.io/json
# 第一次返回 125.108.141.233 / CN —— 根本没走代理

# 2. 代理端口到底是多少？YAML 里写的 7890 可能被覆盖
Get-NetTCPConnection -State Listen | Where-Object LocalPort -ge 7800
# 实际是 7897

# 3. 走这个端口能通吗？
curl.exe -x http://127.0.0.1:7897 -s -o NUL -w "%{http_code}" https://www.google.com
# 000 —— 还是不通
```

### 根因

```powershell
Get-Process -Id 10132,12160 | Select-Object Id,ProcessName,Path
```

```
12160  iKuuuVPNCore  D:\Program Files\iKuuu_vpn\app\iKuuuVPNCore.exe
10132  verge-mihomo  D:\Program Files\Clash Verge\verge-mihomo.exe
```

**两个代理内核同时在跑**：一个机场客户端，一个 Clash Verge。系统流量被先启动的那个抢走，送进了一个已经失效的节点 —— 而服务器日志里干干净净，因为请求根本没到。

> 💡 判断依据：**服务器日志完全没反应 + 客户端全线 Timeout = 请求没出你的电脑。** 别再去改服务器了。

### 修复

彻底退出 iKuuu（托盘右键退出，不是关窗口），只留一个代理内核。

---

## 阶段 5：流量监控（可选）

`vnstat` 装好，配合脚本每天推 Telegram：

```bash
apt install -y vnstat
systemctl enable --now vnstat

# 5 分钟后再看，刚装时没有数据
vnstat -m
```

注意 vnstat 2.12 的 JSON 结构里没有 `months` 键，直接解析 `--json` 会踩空。**解析文本表格更稳**：

```bash
vnstat -m -i eth0
# eth0  /  monthly
#    month        rx      |     tx      |    total    |   avg. rate
# 2026-11     1.44 GiB   |  1.40 GiB   |  2.84 GiB   | ...
```

定时任务：

```bash
( crontab -l 2>/dev/null | grep -v traffic-report; \
  echo "0 9 * * * /usr/local/bin/traffic-report.sh" ) | crontab -
```

---

## 踩坑总表

| 坑 | 现象 | 原因 | 解决 |
|---|---|---|---|
| **heredoc 粘贴事故** | `bash -n` 只报 warning，脚本运行到一半失败 | 把说明文字整段粘进 `cat > x <<'EOF'`，文件里出现嵌套 heredoc | 长脚本用 `scp` 传文件，不要粘贴 |
| **`bash -n` 会骗人** | 打印「语法 OK」但跑不起来 | 未闭合的 heredoc 只给 warning，退出码仍是 0 | 用 `bash -n` 之外再实际跑一次 |
| **bracketed paste** | `tail: command not found`，命令名前面多了 `^[[200~` | 终端粘贴模式带入了控制字符 | 短命令手打 |
| **sed 替换含 `&` 的链接** | 文件里那行变成重复长串 | `&` 在 sed 替换串里代表「整个匹配内容」 | 用 heredoc 重写，不要 sed 替换含 `&` / `|` 的内容 |
| **公钥被截断 1 位** | `invalid REALITY public key` | 43 字符的公钥复制成了 42 字符 | 生成后 `[ ${#PUB} -eq 43 ]` 校验 |
| **443 间歇性可达** | 早上 False，下午 True | GFW 阻断可能是间歇的，或测试时被干扰 | 多次测，取多数；别依赖单次结果 |
| **两个代理内核** | 节点全 Timeout，服务器日志正常 | iKuuu + Clash Verge 同时跑 | 只留一个 |
| **mixed-port 被覆盖** | YAML 写 7890，实际监听 7897 | Clash Verge 有自己的端口设置 | `Get-NetTCPConnection` 查实际端口 |
| **订阅 502** | `failed to fetch remote profile with status 502` | 请求根本没到 nginx（静态文件只会 404） | 查本机代理是否劫持了订阅请求 |

---

## 最终架构

```
中国大陆                      Cloudflare                  VPS (RackNerd)
┌──────────┐   TLS 443    ┌──────────────┐   HTTP 80   ┌─────────────────┐
│ Clash    │─────────────▶│  边缘节点     │────────────▶│ nginx :80       │
│ FlClash  │              │ 104.21.x.x   │             │  ├ /ws → :8080  │
└──────────┘              └──────────────┘             │  │   Xray(VLESS)│
                                                       │  └ /sub → 订阅  │
                                                       └────────┬────────┘
                                                                │ freedom
                                                                ▼
                                                            目标网站
```

### 参数一览（全部占位符，实际值在 `/root/xray-node.txt`）

| 项 | 值 |
|---|---|
| 协议 | VLESS + WebSocket + TLS（CDN 终结 TLS） |
| 服务器地址 | `vpn.example.com`（域名，不是 IP） |
| 端口 | 443（客户端侧） |
| WS 路径 | `/ws` |
| Host / SNI | `vpn.example.com` |
| 传输 | ws |
| 跳过证书验证 | false（Cloudflare 证书是有效的） |

---

## 学到的几条原则

1. **先分层，再动手。** 服务端 / 链路 / 客户端三层，先用回环测试把服务端摘出去。
2. **服务器日志没反应，问题就在客户端。** 这是最快的判据。
3. **`bash -n` 通过 ≠ 能跑。** 一定实际执行一次。
4. **别在 SSH 里粘贴大段文本。** scp 传文件，或者 `curl -O`。
5. **CDN 方案解决的是「连不上」，不是「慢」。** 延迟是物理距离决定的，换 CDN 不会变快。
6. **机房 IP 有天花板。** LinkedIn、银行、部分电商会按 ASN 拒绝，这不是配置能解决的。

---

## 附录：收尾时的体检与清理

搭完之后又花了一轮做「减负」——因为试错过程会在服务器上堆积东西。写了一个体检脚本（`vps-check`），只读模式打印 10 个区块：服务状态、端口监听、Xray 配置摘要、nginx 站点、/tmp 残留、/root 脚本、备份数量、定时任务、磁盘、订阅目录。

清理时发现了几样**完全不该在那儿**的东西：

| 发现 | 风险 |
|---|---|
| 两个 WireGuard 网卡（`XWQ` / `XDH`），`UP,LOWER_UP` | 可能抢路由，走 UDP 与方案无关 |
| Docker 在跑，容器 `wg-easy` | 一个 WireGuard 网页面板 |
| `wg-easy` 监听 `0.0.0.0:51821`、`0.0.0.0:51820` | **管理面板直接暴露在公网** |

`51821` 是 wg-easy 的 Web UI，默认虽然有密码，但对公网开放本身就是靶子。这些大概率是早期试别的教程（angristan 的 `wireguard-install`）留下的。

清理顺序：

```bash
# 1. WireGuard
systemctl disable --now wg-quick@XWQ wg-quick@XDH
ip link del XWQ; ip link del XDH
rm -f /etc/wireguard/*.conf /etc/wireguard/params

# 2. wg-easy 容器
docker rm -f wg-easy
docker system prune -af

# 3. Docker 整套
systemctl disable --now docker docker.socket containerd
apt purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
apt autoremove -y

# 4. docker0 网桥（内核对象，purge 不会删）
ip link del docker0
```

清理后的最终状态：

```
ip route
  default via 107.150.2.1 dev eth0
  107.150.2.0/24 dev eth0

ss -tlnp
  0.0.0.0:80        nginx
  127.0.0.1:8080    xray
  0.0.0.0:22        sshd
```

只剩四件事：nginx、xray、sshd、vnstat。每一样都必须存在，多一样都没有。

**教训**：搭完之后跑一次体检，比出问题再翻要省事得多。尤其是「公网监听」这一项——`ss -tlnp` 里每一个 `0.0.0.0` 都值得看一眼它是谁。
