#!/usr/bin/env bash
set -e

### ===== 基础变量（可修改） =====
DOMAIN="example.com"
HK_SUB="hk.${DOMAIN}"
LA_SUB="la.${DOMAIN}"

HK_TUNNEL_NAME="hk-tunnel"
LA_TUNNEL_NAME="la-tunnel"

SB_PORT_SOCKS=1080
SB_PORT_HTTP=2080

SUB_DIR="/var/www/sub"
SUB_PORT=8088

### ===== 颜色 =====
green(){ echo -e "\033[32m$*\033[0m"; }
red(){ echo -e "\033[31m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }

### ===== 菜单 =====
echo
echo "1) HK 安装"
echo "2) LA 安装"
echo "3) 卸载全部"
read -p "请选择: " MODE

### ===== 卸载 =====
if [[ "$MODE" == "3" ]]; then
  systemctl stop cloudflared sing-box || true
  systemctl disable cloudflared sing-box || true

  rm -rf /etc/cloudflared /root/.cloudflared
  rm -rf /etc/sing-box /usr/local/bin/sing-box
  rm -rf "$SUB_DIR"

  apt purge -y cloudflared || true
  green "已彻底卸载"
  exit 0
fi

### ===== 输入参数 =====
read -p "请输入域名（默认 ${DOMAIN}）: " INPUT_DOMAIN
DOMAIN=${INPUT_DOMAIN:-$DOMAIN}

### ===== 安装依赖 =====
apt update
apt install -y curl wget unzip nginx python3

### ===== sing-box =====
if ! command -v sing-box >/dev/null; then
  curl -fsSL https://sing-box.app/install.sh | bash
fi

mkdir -p /etc/sing-box

### ===== WARP =====
if ! command -v warp-cli >/dev/null; then
  curl -fsSL https://pkg.cloudflareclient.com/install.sh | bash
  apt install -y cloudflare-warp || true
fi

warp-cli registration new || true
warp-cli mode proxy || true
warp-cli connect || true

### ===== cloudflared =====
if ! command -v cloudflared >/dev/null; then
  install_cloudflared() {
  if command -v cloudflared >/dev/null; then
    echo "[INFO] cloudflared already installed"
    return
  fi

  echo "[INFO] Installing cloudflared"

  mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | tee /etc/apt/keyrings/cloudflare.gpg >/dev/null

  echo "deb [signed-by=/etc/apt/keyrings/cloudflare.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
    | tee /etc/apt/sources.list.d/cloudflared.list

  apt update
  apt install -y cloudflared
}

fi

if [ ! -f /root/.cloudflared/cert.pem ]; then
  yellow "请完成 Cloudflare 登录"
  cloudflared tunnel login
fi

### ===== 角色判断 =====
if [[ "$MODE" == "1" ]]; then
  ROLE="HK"
  TUNNEL_NAME="$HK_TUNNEL_NAME"
  HOSTNAME="$HK_SUB"
else
  ROLE="LA"
  TUNNEL_NAME="$LA_TUNNEL_NAME"
  HOSTNAME="$LA_SUB"
fi

### ===== Tunnel =====
if ! cloudflared tunnel list | grep -qw "$TUNNEL_NAME"; then
  cloudflared tunnel create "$TUNNEL_NAME"
fi

TUNNEL_ID=$(cloudflared tunnel list | awk "/$TUNNEL_NAME/{print \$1}")

mkdir -p /etc/cloudflared
cp "/root/.cloudflared/${TUNNEL_ID}.json" /etc/cloudflared/

cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME" || true

cat >/etc/cloudflared/config.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: /etc/cloudflared/${TUNNEL_ID}.json

ingress:
  - hostname: $HOSTNAME
    service: http://127.0.0.1:${SB_PORT_HTTP}
  - service: http_status:404
EOF

cloudflared service install
systemctl restart cloudflared

### ===== sing-box 配置 =====
cat >/etc/sing-box/config.json <<EOF
{
  "inbounds": [
    { "type": "socks", "listen": "127.0.0.1", "listen_port": $SB_PORT_SOCKS },
    { "type": "http",  "listen": "127.0.0.1", "listen_port": $SB_PORT_HTTP }
  ],
  "outbounds": [
    {
      "type": "wireguard",
      "tag": "warp",
      "server": "engage.cloudflareclient.com",
      "server_port": 2408,
      "local_address": [
        "172.16.0.2/32",
        "2606:4700:110:8a36:df92:102a:9602:fa18/128"
      ],
      "private_key": "PLACEHOLDER",
      "peer_public_key": "bmXOC+F1Tq7l...",
      "reserved": [0,0,0],
      "mtu": 1280
    }
  ],
  "route": {
    "final": "warp"
  }
}
EOF

systemctl enable sing-box
systemctl restart sing-box

### ===== 订阅 =====
mkdir -p "$SUB_DIR"
cat >"$SUB_DIR/singbox.json" <<EOF
{
  "server": "$HOSTNAME",
  "type": "http"
}
EOF

cat >"$SUB_DIR/clash.yaml" <<EOF
proxies:
  - name: $ROLE
    type: http
    server: $HOSTNAME
    port: 443
EOF

cat >"$SUB_DIR/sr.conf" <<EOF
$ROLE = http, $HOSTNAME, 443
EOF

python3 -m http.server "$SUB_PORT" --directory "$SUB_DIR" &

green "================================"
green "$ROLE 节点部署完成"
green "订阅地址："
green "http://$HOSTNAME:$SUB_PORT/singbox.json"
green "http://$HOSTNAME:$SUB_PORT/clash.yaml"
green "http://$HOSTNAME:$SUB_PORT/sr.conf"
green "================================"
