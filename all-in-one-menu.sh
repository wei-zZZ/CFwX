#!/usr/bin/env bash
set -e

### ===== 基础 =====
CFD_BIN=/usr/local/bin/cloudflared
CFD_DIR=/etc/cloudflared
SB_DIR=/etc/sing-box
SUB_DIR=/var/www/html/sub
ARCH=$(uname -m)

info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
err()  { echo -e "\033[31m[ERR]\033[0m $1"; exit 1; }

[[ $EUID -ne 0 ]] && err "请用 root 运行"

### ===== 选择 =====
echo "1) 安装 HK 节点"
echo "2) 安装 LA 节点"
echo "3) 卸载"
read -rp "请选择: " ACTION

### ===== 参数输入 =====
if [[ "$ACTION" == "1" || "$ACTION" == "2" ]]; then
  read -rp "请输入域名 (如 hk.example.com): " DOMAIN
  read -rp "请输入 sing-box 端口 [3000]: " SB_PORT
  SB_PORT=${SB_PORT:-3000}
fi

### ===== 卸载 =====
if [[ "$ACTION" == "3" ]]; then
  info "停止服务"
  systemctl stop cloudflared sing-box 2>/dev/null || true
  systemctl disable cloudflared sing-box 2>/dev/null || true

  info "删除文件"
  rm -rf /etc/cloudflared /etc/sing-box /usr/local/bin/cloudflared
  rm -rf /root/.cloudflared
  rm -rf /var/www/html/sub

  info "卸载完成"
  exit 0
fi

### ===== 安装依赖 =====
info "安装基础依赖"
apt update
apt install -y curl wget tar nginx

### ===== 安装 cloudflared（二进制，避免 apt 坑）=====
if [[ ! -x $CFD_BIN ]]; then
  info "安装 cloudflared"
  case "$ARCH" in
    x86_64) CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    aarch64) CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
    *) err "不支持的架构 $ARCH" ;;
  esac
  curl -L "$CFD_URL" -o $CFD_BIN
  chmod +x $CFD_BIN
fi

### ===== Cloudflare 登录 =====
if [[ ! -f /root/.cloudflared/cert.pem ]]; then
  info "请在浏览器完成 Cloudflare 登录"
  cloudflared tunnel login
fi

### ===== 创建 Tunnel =====
TUNNEL_NAME=$([[ "$ACTION" == "1" ]] && echo "hk-tunnel" || echo "la-tunnel")

if ! cloudflared tunnel list | grep -q "$TUNNEL_NAME"; then
  cloudflared tunnel create "$TUNNEL_NAME"
fi

TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
CRED_FILE="$CFD_DIR/$TUNNEL_ID.json"

mkdir -p $CFD_DIR
cp /root/.cloudflared/$TUNNEL_ID.json $CRED_FILE

cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN" || warn "DNS 已存在，跳过"

### ===== cloudflared 配置 =====
cat > $CFD_DIR/config.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CRED_FILE

ingress:
  - hostname: $DOMAIN
    service: http://127.0.0.1:$SB_PORT
  - service: http_status:404
EOF

### ===== systemd =====
cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflared Tunnel
After=network.target

[Service]
ExecStart=$CFD_BIN --no-autoupdate --config $CFD_DIR/config.yml tunnel run
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable cloudflared
systemctl restart cloudflared

### ===== 安装 sing-box =====
if [[ ! -x /usr/bin/sing-box ]]; then
  info "安装 sing-box"
  curl -fsSL https://sing-box.app/install.sh | bash
fi

mkdir -p $SB_DIR

### ===== sing-box 配置（VLESS WS，示例）=====
UUID=$(cat /proc/sys/kernel/random/uuid)

cat > $SB_DIR/config.json <<EOF
{
  "inbounds": [{
    "type": "vless",
    "listen": "127.0.0.1",
    "listen_port": $SB_PORT,
    "users": [{ "uuid": "$UUID" }]
  }],
  "outbounds": [{ "type": "direct" }]
}
EOF

systemctl enable sing-box
systemctl restart sing-box

### ===== 订阅生成 =====
mkdir -p $SUB_DIR

cat > $SUB_DIR/sing-box.json <<EOF
{
  "outbounds": [{
    "type": "vless",
    "server": "$DOMAIN",
    "server_port": 443,
    "uuid": "$UUID",
    "tls": { "enabled": true }
  }]
}
EOF

cat > $SUB_DIR/clash.yaml <<EOF
proxies:
- name: CF-$TUNNEL_NAME
  type: vless
  server: $DOMAIN
  port: 443
  uuid: $UUID
  tls: true
EOF

info "=============================="
info "部署完成"
info "节点: $TUNNEL_NAME"
info "域名: https://$DOMAIN"
info "订阅:"
info "sing-box  http://$DOMAIN/sub/sing-box.json"
info "Clash     http://$DOMAIN/sub/clash.yaml"
info "=============================="
