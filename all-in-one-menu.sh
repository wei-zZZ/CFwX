#!/usr/bin/env bash
set -e

### ---------- 工具函数 ----------
info(){ echo -e "\033[32m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[33m[WARN]\033[0m $*"; }
err(){  echo -e "\033[31m[ERR ]\033[0m $*"; }
pause(){ read -rp "按回车继续..." ; }

[ "$(id -u)" -eq 0 ] || { err "请使用 root 运行"; exit 1; }

### ---------- 菜单 ----------
echo
echo "请选择操作："
echo "1) 安装 HK 节点"
echo "2) 安装 LA 节点"
echo "3) 完整卸载（cloudflared + sing-box + WARP）"
echo
read -rp "请输入选项 [1-3]: " MODE

case "$MODE" in
  1) ROLE="HK" ;;
  2) ROLE="LA" ;;
  3) ROLE="UNINSTALL" ;;
  *) err "无效选项"; exit 1 ;;
esac

### ---------- 卸载逻辑 ----------
if [ "$ROLE" = "UNINSTALL" ]; then
  info "开始完整卸载"

  systemctl stop cloudflared sing-box warp-svc 2>/dev/null || true
  systemctl disable cloudflared sing-box warp-svc 2>/dev/null || true

  cloudflared service uninstall 2>/dev/null || true

  rm -rf /etc/cloudflared
  rm -rf /root/.cloudflared        # ← 包含 cert.pem
  rm -rf /etc/sing-box
  rm -rf /var/www/sub

  apt purge -y cloudflared sing-box cloudflare-warp nginx 2>/dev/null || true
  apt autoremove -y

  info "卸载完成，系统已恢复干净状态"
  exit 0
fi

### ---------- 参数输入 ----------
echo
read -rp "Tunnel 名称 [hk-tunnel]: " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-hk-tunnel}

read -rp "HK 入口域名 (如 hk.example.com): " DOMAIN_HK
[ -z "$DOMAIN_HK" ] && { err "域名不能为空"; exit 1; }

read -rp "LA 内网域名 (如 la.internal.example.com): " DOMAIN_LA
[ -z "$DOMAIN_LA" ] && { err "LA 域名不能为空"; exit 1; }

read -rp "sing-box 本地监听端口 [10000]: " LISTEN_PORT
LISTEN_PORT=${LISTEN_PORT:-10000}

read -rp "是否安装 WARP 出口？[Y/n]: " INSTALL_WARP
INSTALL_WARP=${INSTALL_WARP:-Y}

read -rp "是否生成订阅并用 nginx 提供？[Y/n]: " INSTALL_SUB
INSTALL_SUB=${INSTALL_SUB:-Y}

### ---------- 依赖 ----------
info "安装基础依赖"
apt update
apt install -y curl unzip nginx

### ---------- cloudflared ----------
if ! command -v cloudflared >/dev/null; then
  info "install_cloudflared"
install_cloudflared() {
  if command -v cloudflared >/dev/null; then
    info "cloudflared already installed"
    return
  fi

  info "Installing cloudflared (static binary)"

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  BIN_ARCH="amd64" ;;
    aarch64) BIN_ARCH="arm64" ;;
    *) err "Unsupported arch: $ARCH"; exit 1 ;;
  esac

  TMP_DIR=$(mktemp -d)
  cd "$TMP_DIR"

  curl -fL \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${BIN_ARCH}" \
    -o cloudflared

  chmod +x cloudflared
  mv cloudflared /usr/bin/cloudflared

  cd /
  rm -rf "$TMP_DIR"

  info "cloudflared installed: $(cloudflared --version)"
}

fi

### ---------- Cloudflare 登录 ----------
if [ ! -f /root/.cloudflared/cert.pem ]; then
  info "需要 Cloudflare 登录"
  cloudflared tunnel login
fi

### ---------- Tunnel ----------
if ! cloudflared tunnel list | grep -q "$TUNNEL_NAME"; then
  info "创建 Tunnel: $TUNNEL_NAME"
  cloudflared tunnel create "$TUNNEL_NAME"
else
  info "Tunnel 已存在"
fi

TUNNEL_ID=$(cloudflared tunnel list | awk "/$TUNNEL_NAME/ {print \$1}")
CFG_DIR="/etc/cloudflared"
CREDS="$CFG_DIR/$TUNNEL_ID.json"
mkdir -p "$CFG_DIR"

if [ ! -f "$CREDS" ]; then
  info "生成 tunnel credentials"
  cloudflared tunnel run "$TUNNEL_NAME" --credentials-file "$CREDS" &
  sleep 3
  pkill cloudflared || true
fi

### ---------- DNS ----------
cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN_HK" || true
cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN_LA" || true

### ---------- cloudflared config ----------
cat > $CFG_DIR/config.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CREDS

ingress:
  - hostname: $DOMAIN_HK
    service: http://127.0.0.1:$LISTEN_PORT
  - hostname: $DOMAIN_LA
    service: http://127.0.0.1:$LISTEN_PORT
  - service: http_status:404
EOF

cloudflared service install
systemctl restart cloudflared

### ---------- sing-box ----------
if ! command -v sing-box >/dev/null; then
  info "安装 sing-box"
  curl -fsSL https://sing-box.app/install.sh | bash
fi

mkdir -p /etc/sing-box

### ---------- WARP ----------
if [[ "$INSTALL_WARP" =~ ^[Yy]$ ]]; then
  if ! command -v warp-cli >/dev/null; then
    curl -fsSL https://pkg.cloudflareclient.com/install.sh | bash
    apt install -y cloudflare-warp || true
  fi
  warp-cli registration new || true
  warp-cli mode proxy || true
  warp-cli connect || true
  WARP_OUT='"warp"'
else
  WARP_OUT='"direct"'
fi

### ---------- sing-box config ----------
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info" },
  "inbounds": [{
    "type": "http",
    "listen": "127.0.0.1",
    "listen_port": $LISTEN_PORT
  }],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    {
      "type": "socks",
      "tag": "warp",
      "server": "127.0.0.1",
      "server_port": 40000
    }
  ],
  "route": {
    "rules": [
      { "domain_suffix": ["google.com","openai.com"], "outbound": $WARP_OUT }
    ],
    "final": "direct"
  }
}
EOF

systemctl enable sing-box
systemctl restart sing-box

### ---------- 订阅 ----------
if [[ "$INSTALL_SUB" =~ ^[Yy]$ ]]; then
  mkdir -p /var/www/sub
  cat > /var/www/sub/sing-box.json <<EOF
{
  "type": "http",
  "server": "$DOMAIN_HK",
  "port": 443
}
EOF

  cat > /etc/nginx/conf.d/sub.conf <<EOF
server {
  listen 80;
  root /var/www/sub;
  location / { autoindex on; }
}
EOF

  systemctl restart nginx
  info "订阅地址: http://$DOMAIN_HK/sing-box.json"
fi

info "🎉 安装完成：$ROLE 节点"
