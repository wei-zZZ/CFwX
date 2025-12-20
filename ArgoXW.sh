#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

### ========= 基础 =========
WORKDIR="/opt/argoxw"
XRAY_DIR="/usr/local/xray"
CF_DIR="/etc/cloudflared"
SUB_DIR="/opt/sub"
IP=$(curl -s4 ip.sb || curl -s4 ifconfig.me)

GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
NC="\033[0m"

log(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
err(){ echo -e "${RED}[ERR ]${NC} $*" >&2; }

is_tty(){ [[ -t 0 && -t 1 ]]; }

mkdir -p $WORKDIR $SUB_DIR

### ========= 系统识别 =========
detect_region() {
  if curl -s https://ipinfo.io/country | grep -qi "US"; then
    REGION="LA"
  else
    REGION="HK"
  fi
  log "识别区域：$REGION"
}

### ========= 安装依赖 =========
install_base() {
  apt update -y
  apt install -y curl wget unzip jq socat uuid-runtime iproute2
}

### ========= Xray =========
install_xray() {
  log "安装 Xray"
  bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

  UUID=$(uuidgen)
  REALITY_KEY=$(xray x25519 | awk '/Private key/ {print $3}')
  REALITY_PUB=$(xray x25519 | awk '/Public key/ {print $3}')
  PORT=443
  SNI="www.cloudflare.com"

  cat > /usr/local/etc/xray/config.json <<EOF
{
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "$UUID",
        "flow": "xtls-rprx-vision"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$SNI:443",
        "xver": 0,
        "serverNames": ["$SNI"],
        "privateKey": "$REALITY_KEY",
        "shortIds": [""]
      }
    }
  }],
  "outbounds": [
    { "protocol": "socks", "settings": { "servers": [{ "address": "127.0.0.1", "port": 40000 }] }, "tag": "warp" },
    { "protocol": "freedom", "tag": "direct" }
  ],
  "routing": {
    "rules": [{
      "type": "field",
      "outboundTag": "warp",
      "domain": ["openai.com","chatgpt.com","netflix.com","google.com","steamcommunity.com"]
    }]
  }
}
EOF

  systemctl enable xray --now
}

### ========= WARP（仅 Xray） =========
install_warp() {
  log "安装 WARP（仅 Xray 使用）"

  apt install -y lsb-release gnupg

  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
  | gpg --dearmor \
  | tee /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg >/dev/null

  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
  | tee /etc/apt/sources.list.d/cloudflare-client.list

  apt update
  apt install -y cloudflare-warp

  # 初始化 WARP（不接管系统流量）
  warp-cli registration new || true
  warp-cli mode proxy
  warp-cli connect

  log "WARP 已启用（代理模式，仅供 Xray 使用）"
}
 {
  log "安装 WARP"
  curl -fsSL https://pkg.cloudflareclient.com/install.sh | bash
  apt install -y cloudflare-warp

  warp-cli registration new || true
  warp-cli mode proxy
  warp-cli connect
}

### ========= Cloudflare Tunnel =========
install_cloudflared() {
  log "安装 Cloudflare Tunnel"
  wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /usr/bin/cloudflared
  chmod +x /usr/bin/cloudflared

  read -rp "请输入 Cloudflare Account ID: " CF_ACCOUNT
  read -rp "请输入 Global API Key: " CF_APIKEY
  read -rp "请输入 Cloudflare Email: " CF_EMAIL

  if [[ "$REGION" == "HK" ]]; then
    read -rp "请输入 Zone ID（HK 域名用）: " CF_ZONE
    read -rp "请输入 HK 使用的域名: " CF_DOMAIN
  fi

  TUNNEL_NAME="${REGION,,}-tunnel"
  TUNNEL_ID=$(cloudflared tunnel create $TUNNEL_NAME | grep -oE '[0-9a-f-]{36}')

  mkdir -p $CF_DIR
  cat > $CF_DIR/config.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CF_DIR/$TUNNEL_ID.json

ingress:
  - service: http://127.0.0.1:10000
EOF

  cloudflared service install
}

### ========= 订阅 =========
gen_sub() {
  SUB_FILE="$SUB_DIR/vless.txt"
  echo "vless://$UUID@$IP:443?encryption=none&security=reality&sni=www.cloudflare.com&fp=chrome&type=tcp&flow=xtls-rprx-vision&pbk=$REALITY_PUB#${REGION}-Reality" > $SUB_FILE
  log "订阅生成完成：$SUB_FILE"
}

### ========= 卸载 =========
uninstall_all() {
  systemctl stop xray cloudflared || true
  apt purge -y cloudflare-warp xray cloudflared || true
  rm -rf /usr/local/etc/xray /etc/cloudflared $WORKDIR
  log "已彻底卸载"
}

### ========= 自动安装 =========
auto_install() {
  detect_region
  install_base
  install_xray
  install_warp
  install_cloudflared
  gen_sub
  log "🎉 安装完成"
}

### ========= 菜单 =========
menu() {
  echo
  echo "1) 安装（全部）"
  echo "2) 卸载 / 重置"
  echo "3) 生成订阅"
  echo "0) 退出"
  read -rp "选择: " c
  case $c in
    1) auto_install ;;
    2) uninstall_all ;;
    3) gen_sub ;;
    0) exit 0 ;;
  esac
}

### ========= 入口 =========
if is_tty; then
  menu
else
  auto_install
fi
