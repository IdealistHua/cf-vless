#!/usr/bin/env bash
# 备份：打包 Xray / nginx / 订阅 / 节点信息，最多保留 7 份
# 用法：bash backup-cf.sh        日志：/var/log/backup-cf.log
set -uo pipefail

BACKUP_DIR=/root/backup
KEEP=7
STAMP=$(date '+%Y-%m-%d_%H%M')
OUT="$BACKUP_DIR/cf-${STAMP}.tar.gz"
LOG=${LOG:-/var/log/backup-cf.log}

log() { echo "[$(date '+%F %T')] $*" >>"$LOG"; }
mkdir -p "$BACKUP_DIR" "$(dirname "$LOG")" 2>/dev/null

TOKEN=$(cat /root/sub-token.txt 2>/dev/null || true)

TARGETS=(
  /usr/local/etc/xray/config.json
  /etc/nginx/conf.d
  /root/xray-node.txt
  /root/sub-token.txt
  /root/clash.yaml
)

if [ -n "$TOKEN" ] && [ -d "/var/www/sub/$TOKEN" ]; then
  TARGETS+=("/var/www/sub/$TOKEN")
fi

EXIST=()
for t in "${TARGETS[@]}"; do
  [ -e "$t" ] && EXIST+=("$t")
done

if [ "${#EXIST[@]}" -eq 0 ]; then
  echo "没有可备份的文件，先跑 deploy.sh"
  log "ERROR: no targets found"
  exit 1
fi

if tar czf "$OUT" "${EXIST[@]}" 2>/dev/null; then
  SIZE=$(du -h "$OUT" | cut -f1)
  echo "备份完成: $OUT ($SIZE)"
  log "backup ok: $OUT ($SIZE)"
else
  echo "备份失败"
  log "ERROR: tar failed"
  exit 1
fi

# 轮转：只留最新的 KEEP 份
cd "$BACKUP_DIR" || exit 0
ls -1t cf-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  rm -f "$old"
  log "removed old backup: $old"
done

COUNT=$(ls -1 cf-*.tar.gz 2>/dev/null | wc -l)
echo "当前共 $COUNT 份"
