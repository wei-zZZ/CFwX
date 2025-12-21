#!/usr/bin/env bash
set -e

### ========== 基础函数 ==========
info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
err()  { echo -e "\033[31m[ERR]\033[0m $1"; }

### ========== 菜单 ==========
echo "=============================="
echo "1) HK 部署（Argo + Xray + WARP）"
echo "2) LA 部署（Argo + Xray + WARP）"
echo "3) 卸载（完全清理）"
echo "=============================="
read -rp "选择: " MODE

### ========== 卸载 ==========
if [[ "$MODE" == "3" ]]; then
  info "开始卸载"

  systemctl disable --now cloudflared || true
  systemctl disable --now xray || true

  rm -rf /etc/cloudflared
  rm -rf /etc/xray
  rm -rf /root/.cloudflared

  rm -f /usr/local/bin/cloudflared
  rm -f /usr/bin/xray

  apt purge -y cloudflare-warp || true
  apt autoremove -y

  info "卸载完成（包含 cert.pem）"
  exit 0
fi

### ========== 角色 ==========
if [[ "$MODE" == "1" ]]; then
  ROLE="HK"
  TUNNEL_NAME="hk-tunnel"
elif [[ "$MODE" == "2" ]]; then
  ROLE="LA"
  TUNNEL_NAME="la-tunnel"
else
  err "无效选择"
  exit 1
fi

read -rp "请输入 Argo 域名（如 hk.example.com）: " DOMAIN

UUID=$(cat /proc/sys/kernel/random/uuid)

### ========== 基础依赖 ==========
info "安装基础依赖"
apt update
apt install -y curl wget ca-certificates gnupg lsb-release

### ========== 安装 cloudflared ==========
if ! command -v cloudflared >/dev/null; then
  info "安装 cloudflared（二进制方式）"
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi

### ========== Cloudflare 登录 ==========
if [ ! -f /root/.cloudflared/cert.pem ]; then
  info "请在浏览器中完成 Cloudflare 登录"
  cloudflared tunnel login
fi

### ========== 创建 Tunnel ==========
if ! cloudflared tunnel list | grep -q "$TUNNEL_NAME"; then
  cloudflared tunnel create "$TUNNEL_NAME"
fi

cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN" || true

TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')

### ========== cloudflared 配置 ==========
mkdir -p /etc/cloudflared
cat >/etc/cloudflared/config.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: /root/.cloudflared/${TUNNEL_ID}.json

ingress:
  - hostname: $DOMAIN
    service: http://127.0.0.1:10000
  - service: http_status:404
EOF

### ========== 安装 cloudflared 服务 ==========
cloudflared service install || true
systemctl restart cloudflared
systemctl enable cloudflared

### ========== 安装 Xray ==========
if ! command -v xray >/dev/null; then
  info "安装 Xray"
  bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
fi

### ========== 安装 WARP ==========
if ! command -v warp-cli >/dev/null; then
  info "安装 WARP"
  curl -fsSL https://pkg.cloudflareclient.com/install.sh | bash
  apt install -y cloudflare-warp
fi

info "启动 WARP（只 connect，不切模式）"
warp-cli connect || true

### ========== Xray 配置 ==========
mkdir -p /etc/xray
cat >/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "warp",
      "protocol": "socks",
      "settings": {
        "servers": [{
          "address": "127.0.0.1",
          "port": 40000
        }]
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "geoip": ["us"],
        "outboundTag": "warp"
      },
      {
        "type": "field",
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

systemctl restart xray
systemctl enable xray

### ========== 输出节点 ==========
echo
echo "=============================="
echo "$ROLE 节点部署完成"
echo
echo "VLESS 节点链接："
echo "vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=tcp#Argo-$ROLE"
echo
echo "=============================="
