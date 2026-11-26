#!/usr/bin/env bash
# 给订阅加一个住宅 IP 出口节点（SOCKS5，经 VPS 中转）
# 用法：bash add-residential.sh <HOST> <PORT> <USER> <PASS> [域名]
set -euo pipefail

if [ $# -lt 4 ]; then
  cat <<'USAGE'
用法: bash add-residential.sh <HOST> <PORT> <USER> <PASS> [域名]

例:   bash add-residential.sh 203.0.113.45 12324 abc123 pass1234 vpn.example.com

说明:
  - 端口必须是服务商的 SOCKS5 端口（和 HTTP 端口不同）
  - 域名不传则从 /root/xray-node.txt 读取
USAGE
  exit 1
fi

RP_HOST=$1
RP_PORT=$2
RP_USER=$3
RP_PASS=$4
DOMAIN=${5:-}

if [ -z "$DOMAIN" ]; then
  DOMAIN=$(awk -F': *' '/^域名/{print $2; exit}' /root/xray-node.txt 2>/dev/null || true)
fi
[ -n "$DOMAIN" ] || { echo "❌ 读不到域名，请作为第 5 个参数传入"; exit 1; }

[ -f /root/sub-token.txt ] || { echo "❌ 找不到 /root/sub-token.txt，先跑 deploy.sh"; exit 1; }
TOKEN=$(cat /root/sub-token.txt)
SUB="/var/www/sub/$TOKEN/sub.yaml"
[ -f "$SUB" ] || { echo "❌ 找不到 $SUB"; exit 1; }

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

  - name: "住宅出口"
    type: socks5
    server: ${RP_HOST}
    port: ${RP_PORT}
    username: "${RP_USER}"
    password: "${RP_PASS}"
    udp: true
    dialer-proxy: "CF-中转"

proxy-groups:
  - name: "节点选择"
    type: select
    proxies: ["CF-中转", "住宅出口", "DIRECT"]

  - name: "住宅分流"
    type: fallback
    proxies: ["住宅出口", "CF-中转"]
    url: "https://www.gstatic.com/generate_204"
    interval: 300

rules:
  # ↓↓↓ 改成你要走住宅 IP 的域名，可以写多条
  - DOMAIN-SUFFIX,example.com,住宅分流
  # ↑↑↑
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - DOMAIN-SUFFIX,cn,DIRECT
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,节点选择
YAML

echo "== YAML 校验 =="
python3 -c "
import yaml
d = yaml.safe_load(open('$SUB'))
print('YAML OK, proxies=%d rules=%d' % (len(d['proxies']), len(d['rules'])))
"

echo "== 本地订阅 =="
curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1/sub/$TOKEN/sub.yaml"

echo "== 经 CDN 订阅 =="
curl -s -o /dev/null -w "%{http_code}\n" "http://${DOMAIN}/sub/$TOKEN/sub.yaml"

echo "== 从服务器实测住宅代理 =="
curl -s -m 25 -x "socks5h://${RP_USER}:${RP_PASS}@${RP_HOST}:${RP_PORT}" https://ipinfo.io/json \
  || echo "❌ 住宅代理连不通，检查 HOST/PORT/USER/PASS 是否为 SOCKS5 端口"

echo "== 完成 =="
echo "客户端刷新订阅后会出现：节点选择 / 住宅分流"
echo "别忘了把规则里的 example.com 改成你的目标域名"
echo "回滚: cp $BAK $SUB"
