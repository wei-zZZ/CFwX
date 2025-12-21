#!/usr/bin/env bash
set -e

### ===== 参数 =====
ROLE=""
DOMAIN=""
TUNNEL_NAME=""
UUID=$(cat /proc/sys/kernel/random/uuid)
PORT=3000

### ===== 选择 =====
echo "1) HK"
echo "2) LA"
read -rp "选择节点类型: " C

if [[ "$C" == "1" ]]; then
  ROLE="HK"
  TUNNEL_NAME="hk-tunnel"
elif [[ "$C" == "2" ]]; then
  ROLE="LA"
  TUNNEL_NAME="la-tunnel"
else
  exit 1
fi

read -rp "输入 Tunnel 域名（如 hk.xxx.com）: " DOMAIN

### ===== 依赖 =====
apt update
apt install -y curl wget ca-certificates

### ===== sing-box =====
if ! command -v sing-box >/dev/null; then
  curl -fsSL https://sing-box.app/install.sh | bash
fi

### ===== WARP =====
if ! command -v warp-cli >/dev/null; then
  curl -fsSL https://pkg.cloudflareclient.com/install.sh | bash
  apt install -y cloudflare-warp
fi
warp-cli connect || true

### ===== cloudflared =====
if ! command -v cloudflared >/dev/null; then
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi

### ===== 登录 =====
if [ ! -f ~/.cloudflared/cert.pem ]; then
  echo ">>> 请登录 Cloudflare"
  cloudflared tunnel login
fi

### ===== Tunnel =====
cloudflared tunnel list | grep -q "$TUNNEL_NAME" || cloudflared tunnel create "$TUNNEL_NAME"
cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN"

TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')

### ===== sing-box 配置 =====
mkdir -p /etc/sing-box
cat >/etc/sing-box/config.json <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": $PORT,
      "users": [
        { "uuid": "$UUID", "flow": "" }
      ]
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "server": "127.0.0.1",
      "server_port": 40000
    }
  ]
}
EOF

systemctl restart sing-box
systemctl enable sing-box

### ===== cloudflared 前台运行提示 =====
echo
echo "=============================="
echo "节点部署完成（$ROLE）"
echo
echo "VLESS 节点："
echo "vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws#CF-$ROLE"
echo
echo "请使用以下命令运行 Tunnel："
echo "cloudflared tunnel run $TUNNEL_NAME"
echo "=============================="
