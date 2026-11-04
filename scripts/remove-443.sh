#!/usr/bin/env bash
# ============================================================
# 清理 443 直连节点，订阅回到单节点（走 Cloudflare）
#
#   用法：bash remove-443.sh <你的域名>
#   例：  bash remove-443.sh racknerd.idealist.dpdns.org
#
#   做了什么：
#     1. 备份配置
#     2. 从 xray 配置里删掉 443 的 REALITY inbound
#     3. 重启 xray，确认 443 不再监听
#     4. 重写订阅为单节点 CF-洛杉矶
# ============================================================
set -euo pipefail

DOMAIN="${1:-}"
[ -n "$DOMAIN" ] || { echo "用法: bash remove-443.sh <你的域名>"; exit 1; }

CONF=/usr/local/etc/xray/config.json
TOKEN_FILE=/root/sub-token.txt
SUBROOT=/var/www/sub
BACKUP=/root/xray-backup/$(date +%Y%m%d-%H%M%S)

[ -f "$CONF" ]       || { echo "找不到 $CONF"; exit 1; }
[ -f "$TOKEN_FILE" ] || { echo "找不到 $TOKEN_FILE"; exit 1; }

TOKEN=$(cat "$TOKEN_FILE")

echo "==> [1/5] 备份"
mkdir -p "$BACKUP"
cp "$CONF" "$BACKUP/config.json"
[ -f "$SUBROOT/$TOKEN/sub.yaml" ] && cp "$SUBROOT/$TOKEN/sub.yaml" "$BACKUP/sub.yaml" || true
echo "    $BACKUP"

echo "==> [2/5] 删除 443 inbound"
python3 - "$CONF" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)

before = len(cfg.get("inbounds", []))
cfg["inbounds"] = [ib for ib in cfg.get("inbounds", []) if ib.get("port") != 443]
after = len(cfg["inbounds"])

if before == after:
    print("    没有 443 inbound，跳过")
else:
    print("    已删除 %d 个" % (before - after))

with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
PY

echo "==> [3/5] 校验并重启"
if ! xray -test -config "$CONF" >/tmp/xray-test.log 2>&1; then
  echo "    校验失败，回滚"
  cat /tmp/xray-test.log
  cp "$BACKUP/config.json" "$CONF"
  systemctl restart xray || true
  exit 1
fi
echo "    Configuration OK."
systemctl restart xray
sleep 1

echo "==> [4/5] 重写订阅（单节点）"
UUID=$(python3 -c "
import json
cfg = json.load(open('$CONF'))
for ib in cfg['inbounds']:
    if ib.get('protocol') == 'vless':
        print(ib['settings']['clients'][0]['id'])
        break
")
[ -n "$UUID" ] || { echo "取不到 UUID"; exit 1; }
echo "    UUID: $UUID"

mkdir -p "$SUBROOT/$TOKEN"
cat > "$SUBROOT/$TOKEN/sub.yaml" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true
unified-delay: true
tcp-concurrent: true

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://223.5.5.5/dns-query
    - https://1.1.1.1/dns-query

proxies:
  - name: CF-洛杉矶
    type: vless
    server: $DOMAIN
    port: 443
    uuid: $UUID
    network: ws
    udp: true
    tls: true
    servername: $DOMAIN
    client-fingerprint: chrome
    ws-opts:
      path: /ws
      headers:
        Host: $DOMAIN

proxy-groups:
  - name: 节点选择
    type: select
    proxies:
      - CF-洛杉矶

rules:
  - DOMAIN-SUFFIX,cn,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,节点选择
EOF

echo "==> [5/5] 自检"
echo "--- 443 应该没有监听 ---"
if ss -tlnp | grep -q ':443 '; then
  echo "    !! 443 还在监听，检查一下"
  ss -tlnp | grep ':443 '
else
  echo "    OK，443 已释放"
fi
echo "--- 80 / 8080 应该还在 ---"
ss -tlnp | grep -E ':80 |:8080 ' || echo "    !! 端口异常，检查 nginx / xray"
echo "--- 本地订阅 ---"
curl -s -o /dev/null -w '    sub HTTP %{http_code}\n' "http://127.0.0.1/sub/$TOKEN/sub.yaml"
echo "--- 经 CDN 订阅 ---"
curl -s -o /dev/null -w '    via-CDN sub HTTP %{http_code}\n' "http://$DOMAIN/sub/$TOKEN/sub.yaml"

echo ""
echo "============================================"
echo "  清理完成：订阅只剩一个节点"
echo "============================================"
echo "节点名 : CF-洛杉矶"
echo "订阅   : http://$DOMAIN/sub/$TOKEN/sub.yaml"
echo "============================================"
echo ""
echo "客户端里点「更新订阅」，会只剩 CF-洛杉矶。"
