#!/usr/bin/env bash
# 流量日报：读 vnstat 当月数据，算百分比，可选推 Telegram
# 配置：/etc/traffic-report.env  日志：/var/log/traffic-report.log
set -uo pipefail

ENV_FILE=/etc/traffic-report.env
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

QUOTA_GB=${QUOTA_GB:-1000}
WARN_PCT=${WARN_PCT:-80}
LOG=${LOG:-/var/log/traffic-report.log}
STATE=${STATE:-/var/lib/traffic-report.state}

mkdir -p "$(dirname "$LOG")" "$(dirname "$STATE")" 2>/dev/null

log() { echo "[$(date '+%F %T')] $*" >>"$LOG"; }

command -v vnstat  >/dev/null || { log "ERROR: vnstat 未安装（apt install -y vnstat）"; exit 1; }
command -v python3 >/dev/null || { log "ERROR: python3 缺失"; exit 1; }

# 网卡
IFACE=${IFACE:-}
if [ -z "$IFACE" ]; then
  IFACE=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
fi
[ -n "$IFACE" ] || { log "ERROR: 找不到默认网卡，请在 env 里设置 IFACE"; exit 1; }

MONTH=$(date +%Y-%m)
LINE=$(vnstat -m -i "$IFACE" 2>/dev/null | awk -v m="$MONTH" '$1==m{print; exit}')
if [ -z "$LINE" ]; then
  log "ERROR: vnstat 里还没有 $MONTH 的数据（刚装需等几分钟）"
  exit 1
fi

# 从 "2026-11  1.44 GiB | 1.40 GiB | 2.84 GiB | ..." 里取 total 并换算字节
read -r BYTES DISPLAY <<<"$(printf '%s\n' "$LINE" | python3 -c '
import sys, re
line = sys.stdin.read()
units = {"B":1, "kB":1e3, "KB":1e3, "KiB":1024, "MB":1e6, "MiB":1024**2,
         "GB":1e9, "GiB":1024**3, "TB":1e12, "TiB":1024**4}
m = re.findall(r"(\d+(?:\.\d+)?)\s*(TiB|GiB|MiB|KiB|TB|GB|MB|kB|B)", line)
if len(m) < 3:
    print("0 0 B"); raise SystemExit
rx, tx, tot = m[-3], m[-2], m[-1]
val = float(tot[0]) * units[tot[1]]
print("%d %.2f %s" % (val, val, tot[1]))
')"

GB=$(awk -v b="$BYTES" 'BEGIN{printf "%.2f", b/1024/1024/1024}')
PCT=$(awk -v g="$GB" -v q="$QUOTA_GB" 'BEGIN{ if (q<=0) {print 0} else {printf "%d", g*100/q} }')

# 级别
LEVEL="ok"
[ "$PCT" -ge "$WARN_PCT" ] && LEVEL="warn"
[ "$PCT" -ge 95 ]          && LEVEL="crit"

# 进度条
BAR=$(python3 -c "
p = min($PCT, 100)
n = int(p / 5)
print('[' + '#' * n + '-' * (20 - n) + ']')
")

MSG="$GB GB / $QUOTA_GB GB ($PCT%) $BAR"
echo "$MSG"
log "$LEVEL $PCT% ${GB}GiB/${QUOTA_GB}GiB (raw=${DISPLAY})"

# 同级别每月只提醒一次
KEY="$MONTH:$LEVEL"
if [ "$LEVEL" != "ok" ]; then
  if [ -f "$STATE" ] && [ "$(cat "$STATE")" = "$KEY" ]; then
    log "本月 $LEVEL 已提醒过，跳过"
    exit 0
  fi
fi

# 推送
if [ -z "${TG_TOKEN:-}" ] || [ -z "${TG_CHAT:-}" ]; then
  log "未配置 Telegram，只写日志"
  exit 0
fi

TEXT="📊 VPS 流量日报
$(date '+%Y-%m-%d')
${GB} GB / ${QUOTA_GB} GB（${PCT}%）
${BAR}
级别：${LEVEL}"

if curl -s -m 15 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
     --data-urlencode "chat_id=${TG_CHAT}" \
     --data-urlencode "text=${TEXT}" | grep -q '"ok":true'; then
  log "Telegram 推送成功"
  echo "$KEY" > "$STATE"
else
  log "Telegram 推送失败（检查 token / chat_id）"
fi
