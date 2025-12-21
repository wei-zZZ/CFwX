#!/usr/bin/env bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR ]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "请用 root 运行" && exit 1

echo "1) 安装 Argo + Xray (WS)"
echo "2) 卸载（彻底清理）"
read -rp "选择: " ACTION

### ================= 卸载 =================
if [[ "$ACTION" == "2" ]]; then
  info "停止服务"
  systemctl stop xray cloudflared 2>/dev/null || true
  systemctl disable xray cloudflared 2>/dev/null || true

  info "删除文件"
  rm -rf \
    /usr/local/bin/cloudflared \
    /usr/local/bin/xray \
    /etc/cloudflared \
    /etc/xray \
    /etc/systemd/system/cloudflared.service \
    /etc/systemd/system/xray.service \
    /root/.cloudflared

  systemctl daemon-reload
  info "卸载完成"
  exit 0
fi

### ================= 输入域名 =================
read -rp "请输入你的域名（如 hk.example.com）: " DOMAIN
[[ -z "$DOMAIN" ]] && err "域名不能为空" && exit 1

UUID=$(cat /proc/sys/kernel/random/uuid)
WS_PATH="/ws-$(openssl rand -hex 4)"

info "UUID: $UUID"
info "WS Path: $WS_PATH"

### ================= 依赖 =================
info "安装基础依赖"
apt update -y
apt install -y curl unzip jq ca-certificates

### ================= 安装 Xray =================
if ! command -v xray >/dev/null; then
  info "安装 Xray"
  curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o /tmp/xray.zip
  unzip -qo /tmp/xray.zip -d /tmp/xray
  install -m 755 /tmp/xray/xray /usr/local/bin/xray
fi

### ================= 配置 Xray =================
info "配置 Xray"
mkdir -p /etc/xray

cat > /etc/xray/config.json <<EOF
{
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10000,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "$WS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray -config /etc/xray/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now xray

### ================= 安装 cloudflared（二进制） =================
if ! command -v cloudflared >/dev/null; then
  info "安装 cloudflared"
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi

### ================= Cloudflare 登录 =================
if [[ ! -f /root/.cloudflared/cert.pem ]]; then
  warn "请进行 Cloudflare 登录（浏览器打开）"
  cloudflared tunnel login
fi

### ================= 创建 Tunnel（修正版） =================
TUNNEL_NAME="argo-xray"
CRED_FILE="/etc/cloudflared/${TUNNEL_NAME}.json"
mkdir -p /etc/cloudflared

if ! cloudflared tunnel list | grep -q "$TUNNEL_NAME"; then
  info "创建 Tunnel（指定 credentials-file）"
  cloudflared tunnel create "$TUNNEL_NAME" \
    --credentials-file "$CRED_FILE"
else
  info "Tunnel 已存在"
fi

TUNNEL_ID=$(cloudflared tunnel list | awk "/$TUNNEL_NAME/ {print \$1}")
info "Tunnel ID: $TUNNEL_ID"

### ================= cloudflared 配置 =================
cat > /etc/cloudflared/config.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CRED_FILE

ingress:
  - hostname: $DOMAIN
    service: http://127.0.0.1:10000
  - service: http_status:404
EOF

cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN" || true

cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel run
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloudflared

### ================= 输出节点 =================
echo
echo "================= 节点信息 ================="
echo "协议: VLESS"
echo "地址: $DOMAIN"
echo "端口: 443"
echo "UUID: $UUID"
echo "加密: none"
echo "传输: WS"
echo "WS 路径: $WS_PATH"
echo "SNI / Host: $DOMAIN"
echo "TLS: 开"
echo
echo "VLESS 链接："
echo "vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$WS_PATH#Argo-WS"
echo "==========================================="
