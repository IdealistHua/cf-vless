# 可选：加一个住宅 IP 出口

> 解决「代理生效了，但网站说你在不支持的地区」。
> 不需要就不用看，不影响主方案。

---

## 一、什么时候需要

机房 IP（`AS36352 ColoCrossing`、`AS16509 Amazon` 之类）会被目标服务的风控识别成代理。表现：

| 现象 | 说明 |
|---|---|
| 出口 IP 已经是美国，网站还是说「你所在地区不支持」 | 典型的风控判定 |
| 注册/登录被拒，提示「检测到异常网络」 | 同上 |
| 有的站点能开，有的不能 | 按站点风控强度不同 |

**判断是不是这个问题**：拿一个住宅 IP（机场的原生节点也行）访问同一页面。能开 → 是 IP 类型问题；还是不能 → 可能是账号/地区真的不支持，本方案无效。

> 反例：LinkedIn。如果你看到的登录页底部有 `沪 ICP 备 xxxxx 号`，说明你打开的是**领英中国版**（境内站点），它本来就不走代理。换成 `www.linkedin.com` 全球版再测。

---

## 二、原理

多一跳真实的住宅 IP，只让指定域名走它：

```
设备 → Cloudflare → VPS → 住宅IP → 目标网站
```

客户端配置的关键是 `dialer-proxy`：

```yaml
- name: "住宅-US"
  type: socks5
  server: 203.0.113.45
  port: 12324
  username: "xxx"
  password: "xxx"
  dialer-proxy: "CF-洛杉矶"   # ← 连住宅代理这一步先走 VPS
```

没有这一行，客户端会从国内直连美国住宅代理，延迟爆炸且经常连不上。有了它，链路是 `国内 → CF → VPS → 住宅IP`，走的是已经验证可用的通道。

---

## 三、买一个住宅 IP

常见服务商对比（价格会变，以官网为准）：

| 服务商 | 静态住宅 | 计费 | 备注 |
|---|---|---|---|
| IPRoyal | `ISP Dedicated` | 约 $5/30 天，含 100 GB | 支持支付宝 |
| Bright Data | Residential | 按 GB，$8+/GB | 贵，企业向 |
| 各家机场 | 原生 IP 节点 | 包月 | 最省事，共享 IP |

**买的时候注意三点**：

1. **选 SOCKS5 协议**，端口和 HTTP 不一样，要在订单页的 `Protocol` 下拉里选
2. **看流量上限**：100 GB/月对网页够用，看视频不够（4K 一小时约 7 GB）
3. **关掉自动续费**：多数是 30 天预付，订单页有 `Subscription` 开关，保持关闭

拿到四样东西：

```
HOST      203.0.113.45
PORT      12324
USER      xxxxxxxxxxxxx
PASS      xxxxxxxxxxxx
```

---

## 四、部署

```bash
curl -fsSL https://raw.githubusercontent.com/IdealistHua/cf-vless/main/scripts/add-residential.sh -o add-residential.sh
bash add-residential.sh <HOST> <PORT> <USER> <PASS> [你的域名]
```

例：

```bash
bash add-residential.sh 203.0.113.45 12324 abc123xyz pass1234 vpn.你的域名.com
```

脚本会：

1. 从 `/root/xray-node.txt` 读出域名（没传第 5 个参数时）
2. 从 `config.json` 读出 UUID
3. 备份现有 `sub.yaml`
4. 重写订阅：加 `住宅-US` 节点 + `住宅出口` fallback 组 + 一条分流规则
5. 校验 YAML、检查本地和 CDN 订阅、从服务器实测住宅代理

**成功的标志**：

```
UUID = xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
已备份
YAML OK, proxies=2 rules=6
本地订阅 200
经CDN订阅 200
住宅代理测试: {"ip":"203.0.113.45","country":"US",...}
```

客户端刷新订阅后，代理页会出现：

- `节点选择`（select：CF-洛杉矶 / 住宅-US / DIRECT）
- `住宅出口`（fallback：住宅-US → CF-洛杉矶）

---

## 五、分流规则

默认只让一个占位域名走住宅：

```yaml
rules:
  - DOMAIN-SUFFIX,example.com,住宅出口   # ← 改成你要走住宅的域名
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - DOMAIN-SUFFIX,cn,DIRECT
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,节点选择
```

改规则要改**服务端**的 `sub.yaml`（客户端改了会被订阅覆盖，除非你关了自动更新）：

```bash
SUB=/var/www/sub/$(cat /root/sub-token.txt)/sub.yaml
sed -i 's/DOMAIN-SUFFIX,example.com,住宅出口/DOMAIN-SUFFIX,你要的域名,住宅出口/' "$SUB"
```

然后客户端刷新订阅。

> **不要**把 `MATCH` 指向 `住宅出口`。100 GB 的配额看几小时视频就没了，而且住宅 IP 延迟比机房高。只让需要的那几个域名走。

---

## 六、验证

### 从服务器测（最直接）

```bash
curl -x socks5h://USER:PASS@HOST:PORT -s https://ipinfo.io/json
```

应该返回住宅 IP 的信息，`org` 是你买的服务商或它的上游。

### 从客户端测

1. 代理页选 `住宅-US`
2. 浏览器打开 https://ipinfo.io/json
3. 看 `ip` 是不是住宅 IP

### 测分流是否生效

- 打开分流规则里的域名 → 出口应是住宅 IP
- 打开其他网站 → 出口应是 VPS IP

---

## 七、到期和退役

住宅 IP 到期后，`住宅-US` 会变 `Error`。但 `住宅出口` 是 **fallback** 组，会自动切到 `CF-洛杉矶`——**不会断网**，只是住宅分流失效。

不想要了就移除：

```bash
curl -fsSL https://raw.githubusercontent.com/IdealistHua/cf-vless/main/scripts/remove-residential.sh -o remove-residential.sh
bash remove-residential.sh
```

订阅会变回单节点，客户端刷新后界面清爽。

---

## 八、踩过的坑

| 现象 | 原因 |
|---|---|
| 两个节点全 Timeout | 加了 `dns.fallback` + `fallback-filter.geoip`，客户端缺 GeoIP 库导致 DNS 模块整体失效 |
| 住宅节点一直 Error | 用了 HTTP 端口配 SOCKS5，或没写 `dialer-proxy` |
| 分流没生效 | 改了客户端配置，被订阅更新覆盖 |
| 流量一天用完 | 把 `MATCH` 指到了 `住宅出口` |
| 网站还是说地区不支持 | 该站点真的不支持该地区，或认的是账号而非 IP |
