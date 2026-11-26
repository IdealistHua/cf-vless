#!/usr/bin/env bash
# 移除住宅出口节点，把订阅恢复成单节点（CF 中转）
# 用法：bash remove-residential.sh
set -euo pipefail

[ -f /root/sub-token.txt ] || { echo "❌ 找不到 /root/sub-token.txt"; exit 1; }
TOKEN=$(cat /root/sub-token.txt)
SUB="/var/www/sub/$TOKEN/sub.yaml"
[ -f "$SUB" ] || { echo "❌ 找不到 $SUB"; exit 1; }

DOMAIN=$(awk -F': *' '/^域名/{print $2; exit}' /root/xray-node.txt 2>/dev/null || true)
[ -n "$DOMAIN" ] || { echo "❌ 读不到域名，检查 /root/xray-node.txt"; exit 1; }

UUID=$(python3 -c "
import json
c = json.load(open('/usr/local/etc/xray/config.json'))
print([i for i in c['inbounds'] if i.get('protocol') == 'vless'][0]['settings']['clients'][0]['id'])
")
echo "UUID = $UUID"

BAK="$SUB.bak.$(date +%Y%m%d%H%M%S)"
cp "$SUB" "$BAK"
echo "已备份: $BAK"

cat > "$SUB" <<YAML
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: false
tcp-concurrent: true
unified-delay: true

profile:
  store-selected: true
  store-fake-ip: true

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 223.5.5.5
    - 119.29.29.29

proxies:
  - name: "CF-中转"
    type: vless
    server: ${DOMAIN}
    port: 443
    uuid: ${UUID}
    network: ws
    tls: true
    udp: true
    servername: ${DOMAIN}
    client-fingerprint: chrome
    ws-opts:
      path: /ws
      headers:
        Host: ${DOMAIN}

proxy-groups:
  - name: "节点选择"
    type: select
    proxies: ["CF-中转", "DIRECT"]

rules:
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - DOMAIN-SUFFIX,cn,DIRECT
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,节点选择
YAML

python3 -c "
import yaml
d = yaml.safe_load(open('$SUB'))
print('YAML OK, proxies=%d rules=%d' % (len(d['proxies']), len(d['rules'])))
"
curl -s -o /dev/null -w "本地订阅 %{http_code}\n" "http://127.0.0.1/sub/$TOKEN/sub.yaml"
curl -s -o /dev/null -w "经CDN订阅 %{http_code}\n" "http://${DOMAIN}/sub/$TOKEN/sub.yaml"

echo "== 完成：订阅已恢复单节点 =="
echo "客户端刷新订阅后只剩 CF-中转"
echo "回滚: cp $BAK $SUB"
