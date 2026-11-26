# 运维三件套：流量日报 / 守护 / 备份

装完 `deploy.sh` 之后，服务器能用了，但你还不知道：

- 这个月用了多少流量（超了会被限速或停服）
- 半夜 Xray 挂了没有人管
- 配置改坏了没有退路

三个脚本解决这三件事。**都不装也能正常用**，装了省心。

---

## 一、流量日报

### 1. 装 vnstat 和脚本

```bash
apt install -y vnstat
systemctl enable --now vnstat

curl -fsSL https://raw.githubusercontent.com/IdealistHua/cf-vless/main/scripts/traffic-report.sh \
  -o /usr/local/bin/traffic-report.sh
chmod +x /usr/local/bin/traffic-report.sh
```

> vnstat 装好后要等 5 分钟才有第一次采样，立刻跑会看到「暂无数据」。

### 2. 配置文件

```bash
cat > /etc/traffic-report.env <<'EOF'
# 套餐月流量（GB）。RackNerd 常见档位：1000 / 2000 / 3000
QUOTA_GB=3000

# 网卡，留空自动从 ip route 取
IFACE=

# 超过这个百分比开始告警
WARN_PCT=80

# Telegram（不要推送就留空）
TG_TOKEN=
TG_CHAT=
EOF
chmod 600 /etc/traffic-report.env
```

### 3. 配 Telegram（可选）

1. Telegram 搜 **@BotFather** → `/newbot` → 起名 → 拿到 token，形如 `1234567890:AAxxxxxxxxxxxxxxxxxxxx`
2. **给这个 bot 发一条消息**（随便发个 `hi`），否则它拿不到 chat_id
3. 拿 chat_id：

```bash
curl -s "https://api.telegram.org/bot<你的token>/getUpdates" | python3 -m json.tool | grep -A2 '"chat"'
```

4. 填进 `/etc/traffic-report.env`：

```bash
TG_TOKEN="1234567890:AAxxxxxxxxxxxxxxxxxxxx"
TG_CHAT="123456789"
```

> ⚠️ **token 抄错是最常见的失败**。数字 `0` 和字母 `O`、数字 `1` 和字母 `l` 极易混。如果返回 `{"ok":false,"error_code":401,"description":"Unauthorized"}`，就是抄错了，让 bot 重新生成一个（`/revoke`）。

### 4. 手动跑一次

```bash
/usr/local/bin/traffic-report.sh
tail -5 /var/log/traffic-report.log
```

正常输出：

```
2.84 GB / 3000 GB (0%) [====                    ]
```

日志里应该有两行：

```
[2026-11-02 10:53:16] ok 0% 2.84GiB/3000GiB (rx=1.44 tx=1.40)
[2026-11-02 10:53:16] Telegram 推送成功
```

### 5. 挂定时任务

```bash
( crontab -l 2>/dev/null | grep -v traffic-report; echo "0 9 * * * /usr/local/bin/traffic-report.sh" ) | crontab -
crontab -l
```

服务器时区是 `Asia/Shanghai` 的话，每天**北京时间 09:00** 推一次。

### 行为说明

| 项 | 值 |
|---|---|
| 数据来源 | `vnstat -m -i <网卡>` 的当月行 |
| 告警阈值 | ≥80% 提醒一次，≥95% 再提醒一次 |
| 去重 | 同级别每月只提醒一次（状态存在 `/var/lib/traffic-report.state`） |
| 日志 | `/var/log/traffic-report.log` |

> VPS 商家面板的流量和 vnstat 会有差异：面板按节点统计、通常含 CDN 回源的额外开销；vnstat 只统计本机网卡。**以面板为准**（超限是按面板算的）。

---

## 二、守护

```bash
curl -fsSL https://raw.githubusercontent.com/IdealistHua/cf-vless/main/scripts/watchdog.sh \
  -o /usr/local/bin/watchdog.sh
chmod +x /usr/local/bin/watchdog.sh

( crontab -l 2>/dev/null | grep -v watchdog; echo "*/10 * * * * /usr/local/bin/watchdog.sh" ) | crontab -
```

每 10 分钟检查：

1. `xray` / `nginx` 是否 `active`
2. 本地订阅是否还能返回 `200`
3. 任一不满足 → 重启 → 再检查一次 → 仍失败则写日志（配了 Telegram 就推送）

日志：`/var/log/watchdog.log`

手动验证：

```bash
systemctl stop nginx && /usr/local/bin/watchdog.sh && systemctl is-active nginx
```

应该看到 nginx 被拉回来。

---

## 三、备份

```bash
curl -fsSL https://raw.githubusercontent.com/IdealistHua/cf-vless/main/scripts/backup-cf.sh \
  -o /usr/local/bin/backup-cf.sh
chmod +x /usr/local/bin/backup-cf.sh
/usr/local/bin/backup-cf.sh

( crontab -l 2>/dev/null | grep -v backup-cf; echo "0 4 * * * /usr/local/bin/backup-cf.sh" ) | crontab -
```

输出：

```
备份完成: /root/backup/cf-2026-11-25_0400.tar.gz (4.0K)
当前共 7 份
```

**备份内容**：Xray 配置、nginx 配置、订阅文件、节点信息、token。**不含**日志和系统包。

**保留策略**：最多 7 份，自动删最旧的。

恢复：

```bash
cd /root/backup
tar xzf cf-<日期>.tar.gz -C /
systemctl restart xray nginx
```

---

## 四、体检

`vps-check` 默认**只读**，不会改任何东西，适合「感觉有点不对劲」时先看一眼：

```bash
bash scripts/vps-check.sh          # 只读，列 10 段
bash scripts/vps-check.sh --apply  # 清理（谨慎）
```

10 段内容：服务状态、端口、Xray 摘要、nginx 站点、临时残留、一次性脚本、备份、定时任务、磁盘日志、订阅现状。

> 它能发现「自己忘了的东西」。我们靠它查出服务器上跑着一个 2019 年装的 WireGuard + wg-easy Docker 容器，管理面板 `51821` 端口直接暴露在公网。

---

## 五、常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `ERROR: 本月还没有统计数据` | vnstat 刚装，还没采样 | 等 5 分钟 |
| `ERROR: vnstat 未安装` | 没装或没在 PATH | `apt install -y vnstat` |
| Telegram `ok:false 401` | token 抄错 | 重新生成，注意 `0/O`、`1/l` |
| 日报里的数字和面板差很多 | 统计口径不同 | 以面板为准 |
| 守护脚本每分钟重启一次 | 订阅 URL 里的 token 不对 | `cat /root/sub-token.txt` 对一下 |
| 备份一直只有 1 份 | cron 没生效 | `crontab -l` 检查 |
