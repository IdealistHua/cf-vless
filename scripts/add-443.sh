#!/usr/bin/env bash
# ============================================================
# 在现有 CF + VLESS/WS 部署上，追加一个 443 直连 REALITY 节点
#
#   用法：bash add-443.sh <你的域名>
#   例：  bash add-443.sh vpn.example.com
#
#   结果：订阅里变成两个节点
#     - 直连-洛杉矶     直连 VPS:443（不走 CDN，延迟更低，支持 UDP）
#     - CF-中转         走 Cloudflare（CF 挂了还能用）
#
#   幂等：重复执行只会替换 443 那个 inbound，不会叠加
# ============================================================
set -euo pipefail

DOMAIN="${1:-}"
[ -n "$DOMAIN" ] || { echo "用法: bash add-443.sh <你的域名>"; exit 1; }

CONF=/usr/local/etc/xray/config.json
TOKEN_FILE=/root/sub-token.txt
SUBROOT=/var/www/sub
NODE443=/root/xray-443.txt
BACKUP=/root/xray-backup/$(date +%Y%m%d-%H%M%S)

[ -f "$CONF" ]          || { echo "找不到 $CONF，先跑 deploy.sh"; exit 1; }
[ -f "$TOKEN_FILE" ]    || { echo "找不到 $TOKEN_FILE，先跑 deploy.sh"; exit 1; }

TOKEN=$(cat "$TOKEN_FILE")

echo "==> [1/6] 备份"
mkdir -p "$BACKUP"
cp "$CONF" "$BACKUP/config.json"
[ -f "$SUBROOT/$TOKEN/sub.yaml" ] && cp "$SUBROOT/$TOKEN/sub.yaml" "$BACKUP/sub.yaml" || true
echo "    备份到 $BACKUP"

echo "==> [2/6] 生成 REALITY 密钥对"
KEYOUT=$(xray x25519)
PRIV=$(printf '%s\n' "$KEYOUT" | grep -i 'private'  | awk '{print $NF}')
PUB=$(printf  '%s\n' "$KEYOUT" | grep -iE 'public|password' | awk '{print $NF}')
[ ${#PRIV} -eq 43 ] || { echo "私钥长度异常: ${#PRIV}"; exit 1; }
[ ${#PUB}  -eq 43 ] || { echo "公钥长度异常: ${#PUB}";  exit 1; }
SID=$(openssl rand -hex 8)

# 回验：用私钥反推公钥，确认配对
VERIFY=$(xray x25519 -i "$PRIV" | grep -iE 'public|password' | awk '{print $NF}')
[ "$VERIFY" = "$PUB" ] || { echo "密钥自检失败"; exit 1; }
echo "    公钥 $PUB"

echo "==> [3/6] 写入 443 inbound"
python3 - "$CONF" "$PRIV" <<'PY'
import json, sys
path, priv = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)

# 取现有 WS inbound 的 UUID，保持同一个用户
uuid = None
for ib in cfg.get("inbounds", []):
    if ib.get("protocol") == "vless" and ib.get("streamSettings", {}).get("network") == "ws":
        uuid = ib["settings"]["clients"][0]["id"]
if not uuid:
    sys.exit("找不到现有的 WS inbound / UUID")

# 删掉旧的 443（幂等）
cfg["inbounds"] = [ib for ib in cfg.get("inbounds", []) if ib.get("port") != 443]

cfg["inbounds"].append({
    "tag": "vless-reality-443",
    "listen": "0.0.0.0",
    "port": 443,
    "protocol": "vless",
    "settings": {
        "clients": [{"id": uuid, "flow": "xtls-rprx-vision"}],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "show": False,
            "dest": "www.tesla.com:443",
            "xver": 0,
            "serverNames": ["www.tesla.com"],
            "privateKey": priv,
            "shortIds": []
        }
    },
    "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
})

with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print("    UUID:", uuid)
PY

# shortId 需要单独塞进去（上面的 python 里留空）
python3 - "$CONF" "$SID" <<'PY'
import json, sys
path, sid = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
for ib in cfg["inbounds"]:
    if ib.get("port") == 443:
        ib["streamSettings"]["realitySettings"]["shortIds"] = [sid]
with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
PY

echo "==> [4/6] 校验并重启"
if ! xray -test -config "$CONF" >/tmp/xray-test.log 2>&1; then
  echo "    配置校验失败，回滚："
  cat /tmp/xray-test.log
  cp "$BACKUP/config.json" "$CONF"
  systemctl restart xray || true
  exit 1
fi
echo "    Configuration OK."
systemctl restart xray
sleep 1

echo "==> [5/6] 生成双节点订阅"
SERVER_IP=$(curl -s4 --max-time 8 https://api.ipify.org || curl -s4 --max-time 8 https://ifconfig.me || true)
[ -n "$SERVER_IP" ] || { echo "取不到本机公网 IP，请手动在 /root/xray-443.txt 里核对"; SERVER_IP="$DOMAIN"; }
echo "    本机公网 IP: $SERVER_IP"
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
  - name: 直连-洛杉矶
    type: vless
    server: $SERVER_IP
    port: 443
    uuid: UUIDPLACEHOLDER
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: www.tesla.com
    client-fingerprint: chrome
    reality-opts:
      public-key: PUBPLACEHOLDER
      short-id: SIDPLACEHOLDER

  - name: CF-中转
    type: vless
    server: $DOMAIN
    port: 443
    uuid: UUIDPLACEHOLDER
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
      - 直连-洛杉矶
      - CF-中转
  - name: 自动选择
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies:
      - 直连-洛杉矶
      - CF-中转

rules:
  - DOMAIN-SUFFIX,cn,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,节点选择
EOF

# 用真实值替换占位符（避免 heredoc 里变量和 YAML 冲突）
UUID=$(python3 -c "import json;print([i for i in json.load(open('$CONF'))['inbounds'] if i.get('port')==443][0]['settings']['clients'][0]['id'])")
sed -i "s|UUIDPLACEHOLDER|$UUID|g; s|PUBPLACEHOLDER|$PUB|g; s|SIDPLACEHOLDER|$SID|g" "$SUBROOT/$TOKEN/sub.yaml"

echo "==> [6/6] 自检"
echo "--- 443 是否在监听 ---"
ss -tlnp | grep ':443 ' || echo "    !! 443 没有监听"
echo "--- 本地订阅 ---"
curl -s -o /dev/null -w '    sub HTTP %{http_code}\n' "http://127.0.0.1/sub/$TOKEN/sub.yaml"

cat > "$NODE443" <<EOF
IP           : $SERVER_IP
域名         : $DOMAIN
端口         : 443
UUID         : $UUID
PublicKey    : $PUB
PrivateKey   : $PRIV
ShortID      : $SID
SNI          : www.tesla.com
传输         : VLESS + TCP + REALITY (直连，客户端填 IP 不是域名)
链接         : vless://$UUID@$SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.tesla.com&fp=chrome&pbk=$PUB&sid=$SID&type=tcp#DIRECT-REALITY
订阅         : http://$DOMAIN/sub/$TOKEN/sub.yaml
EOF

echo ""
echo "============================================"
echo "  完成：订阅里现在有两个节点"
echo "============================================"
cat "$NODE443"
echo "============================================"
echo ""
echo "客户端里删掉旧订阅重新导入（或点「更新」）。"
echo "先试 直连-洛杉矶，不行就切 CF-中转。"
