#!/usr/bin/env bash
set -e

############################
# 基础可修改参数
############################
DEFAULT_DOMAIN="example.com"
HK_TUNNEL_NAME="hk-tunnel"
LA_TUNNEL_NAME="la-tunnel"

SB_SOCKS_PORT=1080
SB_HTTP_PORT=2080

############################
# 工具函数
############################
green(){ echo -e "\033[32m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }
red(){ echo -e "\033[31m$*\033[0m"; }

require_root() {
  if [ "$EUID" -ne 0 ]; then
    red "请使用 root 运行"
    exit 1
  fi
}

############################
# cloudflared 安装（兜底）
############################
install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    green "[INFO] cloudflared 已存在"
    return
  fi

  green "[INFO] 安装 cloudflared"

  CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)

  mkdir -p /etc/apt/keyrings || true

  if curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      -o /etc/apt/keyrings/cloudflare.gpg; then

    echo "deb [signed-by=/etc/apt/keyrings/cloudflare.gpg] https://pkg.cloudflare.com/cloudflared ${CODENAME} main" \
      > /etc/apt/sources.list.d/cloudflared.list

    apt update
    if apt install -y cloudflared; then
      return
    fi
  fi

  yellow "[WARN] apt 安装失败，回退二进制方式"

  curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared

  cat >/etc/systemd/system/cloudflared.service <<'EOF'
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel run
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

############################
# Cloudflare 登录（只提示）
############################
ensure_cf_login() {
  if [ ! -f /root/.cloudflared/cert.pem ]; then
    yellow "需要 Cloudflare 登录"
    yellow "请在新窗口执行： cloudflared tunnel login"
    read -p "完成网页登录后按 Enter 继续..."
  fi
}

############################
# sing-box
############################
install_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    green "[INFO] sing-box 已存在"
    return
  fi
  curl -fsSL https://sing-box.app/install.sh | bash
}

############################
# WARP
############################
install_warp() {
  if ! command -v warp-cli >/dev/null 2>&1; then
    curl -fsSL https://pkg.cloudflareclient.com/install.sh | bash
    apt install -y cloudflare-warp
  fi

  warp-cli registration new || true
  warp-cli mode proxy || true
  warp-cli connect || true
}

############################
# Tunnel 创建
############################
setup_tunnel() {
  local NAME=$1
  local HOST=$2

  if ! cloudflared tunnel list | grep -qw "$NAME"; then
    cloudflared tunnel create "$NAME"
  fi

  TUNNEL_ID=$(cloudflared tunnel list | awk "/$NAME/{print \$1}")

  mkdir -p /etc/cloudflared
  cp "/root/.cloudflared/${TUNNEL_ID}.json" /etc/cloudflared/

  cloudflared tunnel route dns "$NAME" "$HOST" || true

  cat >/etc/cloudflared/config.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: /etc/cloudflared/${TUNNEL_ID}.json

ingress:
  - hostname: $HOST
    service: http://127.0.0.1:${SB_HTTP_PORT}
  - service: http_status:404
EOF

  cloudflared service install || true
  systemctl restart cloudflared
}

############################
# sing-box 配置
############################
configure_singbox() {
  mkdir -p /etc/sing-box

  cat >/etc/sing-box/config.json <<EOF
{
  "inbounds": [
    { "type": "socks", "listen": "127.0.0.1", "listen_port": $SB_SOCKS_PORT },
    { "type": "http", "listen": "127.0.0.1", "listen_port": $SB_HTTP_PORT }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": { "final": "direct" }
}
EOF

  systemctl enable sing-box || true
  systemctl restart sing-box
}

############################
# 卸载
############################
uninstall_all() {
  systemctl stop cloudflared sing-box || true
  systemctl disable cloudflared sing-box || true

  rm -rf /etc/cloudflared /root/.cloudflared
  rm -rf /etc/sing-box /usr/local/bin/sing-box

  apt purge -y cloudflared cloudflare-warp || true

  green "已彻底卸载"
  exit 0
}

############################
# 主流程
############################
require_root

echo
echo "1) HK 安装"
echo "2) LA 安装"
echo "3) 卸载"
read -p "请选择: " MODE

if [[ "$MODE" == "3" ]]; then
  uninstall_all
fi

read -p "请输入域名 (默认 $DEFAULT_DOMAIN): " DOMAIN
DOMAIN=${DOMAIN:-$DEFAULT_DOMAIN}

if [[ "$MODE" == "1" ]]; then
  ROLE="HK"
  TUNNEL_NAME=$HK_TUNNEL_NAME
  HOST="hk.${DOMAIN}"
else
  ROLE="LA"
  TUNNEL_NAME=$LA_TUNNEL_NAME
  HOST="la.${DOMAIN}"
fi

green "[STEP] 安装 cloudflared"
install_cloudflared

green "[STEP] Cloudflare 登录检测"
ensure_cf_login

green "[STEP] 安装 sing-box"
install_singbox

green "[STEP] 安装 WARP"
install_warp

green "[STEP] 配置 sing-box"
configure_singbox

green "[STEP] 创建 Tunnel"
setup_tunnel "$TUNNEL_NAME" "$HOST"

green "=============================="
green "$ROLE 节点部署完成"
green "访问域名: https://$HOST"
green "=============================="
