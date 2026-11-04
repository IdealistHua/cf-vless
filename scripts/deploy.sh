#!/usr/bin/env bash
# ============================================================
#  VLESS + WebSocket + Cloudflare CDN 一键部署脚本
#  适用：Ubuntu 20.04+ / Debian 11+，VPS 的 80 端口可用
#  用法：bash deploy.sh vpn.example.com
# ============================================================
set -euo pipefail

DOMAIN="${1:-}"
WS_PATH="/ws"
SUB_ROOT="/var/www/sub"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m%s\033[0m\n' "$*"; }
die()   { red "错误: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 root 运行（sudo bash deploy.sh 你的域名）"
[[ -n "$DOMAIN" ]] || die "缺少域名参数。用法: bash deploy.sh vpn.example.com"
[[ "$DOMAIN" == *.* ]] || die "域名格式不正确: $DOMAIN"

# ------------------------------------------------------------
info "[1/7] 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates openssl nginx >/dev/null
green "依赖就绪"

# ------------------------------------------------------------
info "[2/7] 开启 BBR"
cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl --system >/dev/null 2>&1 || true
green "拥塞控制算法: $(sysctl -n net.ipv4.tcp_congestion_control)"

# ------------------------------------------------------------
info "[3/7] 安装 Xray"
if command -v xray >/dev/null 2>&1; then
    green "Xray 已存在: $(xray version 2>/dev/null | head -1 || echo unknown)"
else
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    green "Xray 安装完成"
fi

# ------------------------------------------------------------
info "[4/7] 生成配置（VLESS + WebSocket，仅监听本地）"
UUID=$(xray uuid)
TOKEN=$(openssl rand -hex 16)
mkdir -p "$SUB_ROOT/$TOKEN"

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 8080,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID", "level": 0 } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$WS_PATH" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

xray -test -config /usr/local/etc/xray/config.json
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
green "Xray 状态: $(systemctl is-active xray)"

# ------------------------------------------------------------
info "[5/7] 配置 nginx（80 端口反代 + 订阅托管）"
rm -f /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf

cat > /etc/nginx/conf.d/vpn.conf <<'EOF'
server {
    listen 80 default_server;
    server_name _;

    # WebSocket 入口，反代给本机 Xray
    location /ws {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # 订阅文件
    location /sub/ {
        alias /var/www/sub/;
        autoindex off;
    }

    location / {
        return 404;
    }
}
EOF

nginx -t
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx
green "nginx 状态: $(systemctl is-active nginx)"

# ------------------------------------------------------------
info "[6/7] 生成 Clash 订阅"
cat > "$SUB_ROOT/$TOKEN/sub.yaml" <<YAML
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false
dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
  fallback:
    - 1.1.1.1
    - 8.8.8.8
proxies:
  - name: CF-VLESS
    type: vless
    server: $DOMAIN
    port: 443
    uuid: $UUID
    udp: true
    network: ws
    tls: true
    servername: $DOMAIN
    client-fingerprint: chrome
    ws-opts:
      path: $WS_PATH
      headers:
        Host: $DOMAIN
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - CF-VLESS
      - DIRECT
rules:
  - DOMAIN-SUFFIX,cn,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
YAML

cp "$SUB_ROOT/$TOKEN/sub.yaml" /root/clash.yaml

VLESS="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&sni=$DOMAIN&fp=chrome&type=ws&host=$DOMAIN&path=%2Fws#CF-VLESS"

cat > /root/xray-node.txt <<NODE
域名        : $DOMAIN
端口        : 443 (Cloudflare)
UUID        : $UUID
传输        : VLESS + WebSocket + TLS (CDN)
WS 路径     : $WS_PATH
Host 头     : $DOMAIN
订阅         : http://$DOMAIN/sub/$TOKEN/sub.yaml
VLESS 链接   : $VLESS
NODE

# ------------------------------------------------------------
info "[7/7] 自检"
echo "--- 端口监听（nginx: 0.0.0.0:80 / xray: 127.0.0.1:8080）---"
ss -tlnp | grep -E ':80 |:8080 ' || red "端口异常"
echo "--- 本地订阅 ---"
curl -s -o /dev/null -w '  local  HTTP %{http_code}\n' "http://127.0.0.1/sub/$TOKEN/sub.yaml"
echo "--- 走 CDN 取订阅（需要 Cloudflare 已生效）---"
curl -s -o /dev/null -w '  via CF HTTP %{http_code}\n' "http://$DOMAIN/sub/$TOKEN/sub.yaml" || true
echo "--- 域名解析（应为 104.x / 172.67.x）---"
dig +short "$DOMAIN" 2>/dev/null || true

echo
green "================ 部署完成 ================"
cat /root/xray-node.txt
echo
echo "下一步："
echo "  1. 确认 Cloudflare 的 SSL/TLS 模式是 Flexible"
echo "  2. 把下面的订阅地址填进 Clash Verge Rev / FlClash"
echo "  3. 客户端打开系统代理，模式选『规则』"
