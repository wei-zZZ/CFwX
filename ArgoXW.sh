#!/usr/bin/env bash
set -e

WORKDIR="/opt/argo-xray"
XRAY_PORT=10000
REALITY_PORT=443

green(){ echo -e "\033[32m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }

check_root() {
  [ "$(id -u)" != "0" ] && red "请使用 root 运行" && exit 1
}

menu() {
  echo ""
  echo "====== Argo + Xray + Reality + WARP ======"
  echo "1) 安装（全部）"
  echo "2) 生成订阅"
  echo "3) 卸载 / 重置"
  echo "0) 退出"
  read -p "请选择: " num
  case "$num" in
    1) install_all ;;
    2) gen_sub ;;
    3) uninstall ;;
    0) exit ;;
    *) red "无效选择" ;;
  esac
}

install_deps() {
  apt update
  apt install -y curl wget unzip jq iptables
}

install_xray() {
  green "安装 Xray-core..."
  bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
}

install_warp_xray_only() {
  green "安装 WARP（仅 Xray）..."
  apt install -y wireguard resolvconf
  curl -fsSL https://pkg.cloudflareclient.com/install.sh | bash
  apt install -y cloudflare-warp
  warp-cli --accept-tos registration new
}

gen_xray_config() {
  read -p "请输入 UUID: " UUID
  read -p "请输入 REALITY 域名伪装（如 www.microsoft.com）: " DEST

  mkdir -p $WORKDIR/xray

cat > $WORKDIR/xray/config.json <<EOF
{
  "inbounds":[{
    "port": $REALITY_PORT,
    "protocol": "vless",
    "settings":{
      "clients":[{"id":"$UUID","flow":"xtls-rprx-vision"}],
      "decryption":"none"
    },
    "streamSettings":{
      "network":"tcp",
      "security":"reality",
      "realitySettings":{
        "dest":"$DEST:443",
        "xver":1,
        "serverNames":["$DEST"],
        "privateKey":"$(xray x25519 | awk '/Private/{print $3}')"
      }
    }
  }],
  "outbounds":[
    {"protocol":"freedom","tag":"direct"},
    {"protocol":"wireguard","tag":"warp","settings":{"secretKey":"$(wg genkey)","address":["172.16.0.2/32"]}}
  ]
}
EOF
}

install_cloudflared() {
  green "安装 Cloudflared..."
  wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  dpkg -i cloudflared-linux-amd64.deb
}

cf_auth() {
  read -p "Cloudflare Account ID: " CF_ACCOUNT
  read -p "Cloudflare Global API Key: " CF_KEY
}

create_tunnel() {
  cloudflared tunnel login
  cloudflared tunnel create argo-xray
}

gen_cf_config() {
  mkdir -p $WORKDIR/cloudflared
  TUNNEL_ID=$(cloudflared tunnel list | awk '/argo-xray/{print $1}')

cat > $WORKDIR/cloudflared/config.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: /root/.cloudflared/$TUNNEL_ID.json
ingress:
  - service: http://127.0.0.1:$XRAY_PORT
  - service: http_status:404
EOF

  cloudflared service install
}

gen_sub() {
  mkdir -p $WORKDIR/subscribe
  IP=$(curl -s https://api.ipify.org)
cat > $WORKDIR/subscribe/vless.txt <<EOF
vless://UUID@$IP:443?security=reality&type=tcp#ARGO-XRAY
EOF
  green "订阅生成完成：$WORKDIR/subscribe/vless.txt"
}

uninstall() {
  systemctl stop xray cloudflared || true
  apt remove -y xray cloudflared cloudflare-warp
  rm -rf $WORKDIR
  green "已完全卸载"
}

check_root
menu
