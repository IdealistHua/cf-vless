#!/usr/bin/env bash
# 守护：每 10 分钟检查 xray / nginx / 本地订阅，异常自动重启
# 日志：/var/log/watchdog.log   可选 Telegram（复用 /etc/traffic-report.env）
set -uo pipefail

ENV_FILE=/etc/traffic-report.env
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

LOG=${LOG:-/var/log/watchdog.log}
mkdir -p "$(dirname "$LOG")" 2>/dev/null

log() { echo "[$(date '+%F %T')] $*" >>"$LOG"; }

notify() {
  [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ] || return 0
  curl -s -m 10 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT}" \
    --data-urlencode "text=$1" >/dev/null 2>&1
}

FAILED=0

# 1. 服务
for svc in xray nginx; do
  if ! systemctl is-active --quiet "$svc"; then
    log "$svc 不在运行，尝试重启"
    systemctl restart "$svc" >/dev/null 2>&1
    sleep 3
    if systemctl is-active --quiet "$svc"; then
      log "$svc 已恢复"
      notify "🔧 $svc 掉线，已自动重启恢复"
    else
      log "ERROR: $svc 重启失败"
      notify "🚨 $svc 重启失败，请手动检查"
      FAILED=1
    fi
  fi
done

# 2. 本地订阅
TOKEN=$(cat /root/sub-token.txt 2>/dev/null || true)
if [ -n "$TOKEN" ]; then
  CODE=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1/sub/${TOKEN}/sub.yaml" 2>/dev/null || echo 000)
  if [ "$CODE" != "200" ]; then
    log "本地订阅返回 $CODE，重启 nginx"
    systemctl restart nginx >/dev/null 2>&1
    sleep 3
    CODE2=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1/sub/${TOKEN}/sub.yaml" 2>/dev/null || echo 000)
    if [ "$CODE2" = "200" ]; then
      log "订阅已恢复"
      notify "🔧 订阅异常（$CODE），已重启 nginx 恢复"
    else
      log "ERROR: 订阅仍为 $CODE2"
      notify "🚨 订阅仍不可用（$CODE2），检查 /var/www/sub/"
      FAILED=1
    fi
  fi
else
  log "WARN: /root/sub-token.txt 不存在，跳过订阅检查"
fi

[ "$FAILED" = "0" ] && log "检查通过"
exit 0
