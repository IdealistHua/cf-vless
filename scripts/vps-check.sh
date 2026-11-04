#!/usr/bin/env bash
# ============================================================
# 体检 + 清理：把试错留下的临时文件和冗余配置收拾干净
#
#   默认只体检，不动任何东西：
#       bash cleanup.sh
#
#   确认无误后执行清理：
#       bash cleanup.sh --apply
#
#   清理范围（都是可以安全删除的）：
#     - /tmp 下的调试残留（客户端配置、日志、抓包测试脚本）
#     - /root 下已经用不掉的一次性脚本
#     - 过期的节点信息快照（会重新生成当前真实状态）
#     - 多余的配置备份（只保留最近 1 份）
#     - nginx 默认站点（和我们的 default_server 冲突）
#     - 系统日志超过 100M 的部分
# ============================================================
set -uo pipefail

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

CONF=/usr/local/etc/xray/config.json
# 域名探测：先看 nginx 的 server_name，再看订阅 YAML 里的 server 字段
DOMAIN=$(grep -h 'server_name' /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/* 2>/dev/null \
         | awk '{print $2}' | tr -d ';' | grep -v '^_$' | head -1)
[ -n "$DOMAIN" ] || DOMAIN=$(grep -h '^    server:' /var/www/sub/*/sub.yaml 2>/dev/null \
         | awk '{print $2}' | head -1)
[ -n "$DOMAIN" ] || DOMAIN="<未检测到域名>"

LINE() { printf '%s\n' "------------------------------------------------------------"; }
SEC()  { echo ""; echo "## $*"; }

run() {
  if [ "$APPLY" = "1" ]; then
    eval "$@"
  else
    echo "  [dry-run] $*"
  fi
}

echo "============================================================"
echo "  VPS 体检 $( [ "$APPLY" = "1" ] && echo '（--apply 模式：会真的删除）' || echo '（只读模式）' )"
echo "  时间: $(date '+%F %T')  主机: $(hostname)"
echo "============================================================"

SEC "1. 服务状态"
systemctl is-active xray nginx 2>/dev/null | paste -sd' ' - | sed 's/^/  active: /'
echo "  xray: $(xray version 2>/dev/null | head -1)"
echo "  nginx: $(nginx -v 2>&1)"

SEC "2. 端口监听"
ss -tlnp 2>/dev/null | awk 'NR==1 || /:(80|8080|443|22) /' | sed 's/^/  /'

SEC "3. Xray 配置摘要"
python3 - "$CONF" <<'PY' 2>/dev/null || echo "  读取失败"
import json, sys
cfg = json.load(open(sys.argv[1]))
print("  配置文件: %s (%d bytes)" % (sys.argv[1], len(open(sys.argv[1]).read())))
print("  inbounds: %d 个" % len(cfg.get("inbounds", [])))
for ib in cfg.get("inbounds", []):
    ss = ib.get("streamSettings", {})
    extra = ss.get("security", "none")
    if ss.get("network"):
        extra += " + " + ss["network"]
    print("    - %-5s %-6s %-28s %s" % (
        ib.get("port"), ib.get("protocol"), ib.get("listen", "0.0.0.0"), extra))
print("  outbounds: %d 个 (%s)" % (
    len(cfg.get("outbounds", [])),
    ",".join(o.get("protocol", "?") for o in cfg.get("outbounds", []))))
PY

SEC "4. nginx 站点"
echo "  conf.d:        $(ls /etc/nginx/conf.d/*.conf 2>/dev/null | xargs -n1 basename 2>/dev/null | paste -sd' ' -)"
echo "  sites-enabled: $(ls /etc/nginx/sites-enabled/* 2>/dev/null | xargs -n1 basename 2>/dev/null | paste -sd' ' - || echo '(空)')"
if [ -e /etc/nginx/sites-enabled/default ]; then
  echo "  ⚠️  default 站点还在，它和我们的 default_server 抢同一个 80"
fi

SEC "5. 临时残留（/tmp）"
TMPJUNK=$(ls -1 /tmp/client.json /tmp/c.log /tmp/t443.py /tmp/t443.log /tmp/xray-test.log /tmp/vpn.conf /tmp/ports.* 2>/dev/null)
if [ -n "$TMPJUNK" ]; then echo "$TMPJUNK" | sed 's/^/  /'; else echo "  干净"; fi

SEC "6. /root 下的一次性脚本和快照"
for f in /root/add443.sh /root/add-443.sh /root/remove443.sh /root/remove-443.sh \
         /root/traffic-report.sh /root/xray-443.txt /root/sub-token.txt \
         /root/xray-node.txt /root/clash.yaml; do
  [ -e "$f" ] && echo "  $(ls -lh "$f" | awk '{print $5"\t"$9}')"
done

SEC "7. 配置备份"
if [ -d /root/xray-backup ]; then
  echo "  共 $(ls -1 /root/xray-backup 2>/dev/null | wc -l) 份，占用 $(du -sh /root/xray-backup | cut -f1)"
  ls -1 /root/xray-backup | tail -5 | sed 's/^/    /'
else
  echo "  无"
fi

SEC "8. 定时任务"
crontab -l 2>/dev/null | grep -v '^#' | sed 's/^/  /' || echo "  无"

SEC "9. 磁盘与日志"
echo "  磁盘: $(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
JDU=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[KMG]' | head -1)
echo "  日志: ${JDU:-未知}（journalctl）"

SEC "10. /var/www/sub 订阅现状"
ls -1 /var/www/sub 2>/dev/null | sed 's/^/  token: /' || echo "  无"

echo ""
LINE
if [ "$APPLY" = "1" ]; then
  echo "  开始清理..."
else
  echo "  以上为体检结果，没有做任何修改。"
  echo "  确认无误后执行：bash cleanup.sh --apply"
  LINE
  exit 0
fi
LINE

# ---------------------------------------------------------------
SEC "清理 1/6：/tmp 调试残留"
run 'rm -f /tmp/client.json /tmp/c.log /tmp/t443.py /tmp/t443.log /tmp/xray-test.log /tmp/vpn.conf /tmp/ports.*'
echo "  完成"

SEC "清理 2/6：一次性脚本"
run 'rm -f /root/add443.sh /root/add-443.sh /root/remove443.sh /root/traffic-report.sh'
echo "  完成（保留了：xray-node.txt、sub-token.txt、clash.yaml）"

SEC "清理 3/6：443 残留节点信息"
run 'rm -f /root/xray-443.txt'
echo "  完成"

SEC "清理 4/6：旧配置备份（只留最近 1 份）"
if [ -d /root/xray-backup ]; then
  run 'ls -1dt /root/xray-backup/*/ 2>/dev/null | tail -n +2 | xargs -r rm -rf'
fi
echo "  完成"

SEC "清理 5/6：nginx 默认站点"
if [ -e /etc/nginx/sites-enabled/default ]; then
  run 'rm -f /etc/nginx/sites-enabled/default'
  run 'nginx -t && systemctl reload nginx'
fi
echo "  完成"

SEC "清理 6/6：系统日志压缩"
if [ "$APPLY" = "1" ]; then
  journalctl --vacuum-size=100M 2>/dev/null | tail -2
else
  echo "  [dry-run] journalctl --vacuum-size=100M"
fi

# ---------------------------------------------------------------
SEC "重新生成节点信息"
UUID=$(python3 -c "
import json
cfg = json.load(open('$CONF'))
for ib in cfg['inbounds']:
    if ib.get('protocol') == 'vless':
        print(ib['settings']['clients'][0]['id']); break
" 2>/dev/null)
TOKEN=$(cat /root/sub-token.txt 2>/dev/null)

if [ "$APPLY" = "1" ] && [ -n "$UUID" ]; then
  cat > /root/xray-node.txt <<EOF
# 当前生效的节点（单一出口：Cloudflare 中转）
IP          : $(curl -s4 --max-time 5 https://api.ipify.org || echo '?')
域名        : $DOMAIN
客户端端口  : 443 (Cloudflare)
UUID        : $UUID
传输        : VLESS + WebSocket + TLS (CDN)
WS 路径     : /ws
Host 头     : $DOMAIN
订阅        : http://$DOMAIN/sub/$TOKEN/sub.yaml
# 说明：直连 443 (REALITY) 已下线 —— 该 IP 的 443 在 TLS 层被阻断
EOF
  echo "  已重写 /root/xray-node.txt"
  cat /root/xray-node.txt | sed 's/^/  /'
fi

echo ""
LINE
echo "  清理完成。"
echo "  建议再跑一次只读体检确认：bash cleanup.sh"
LINE
