#!/usr/bin/env bash
set -e

### ===== 基础 =====
[[ $EUID -ne 0 ]] && { echo "请使用 root 运行"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

WORKDIR=/opt/argox
XRAY_CONF=/usr/local/etc/xray/config.json
WG_CONF=/etc/wireguard/warp.conf
SUB_FILE=/root/subscription.txt

mkdir -p $WORKDIR

log(){ echo -e "\033[32m[INFO]\033[0m $1"; }
err(){ echo -e "\033[31m[ERR]\033[0m $1"; }

### ===== 区域识别 =====
detect_region() {
  COUNTRY=$(curl -s https://ipinfo.io/country || echo "")
  [[ "$COUNTRY" == "US" ]] && REGION=LA || REGION=HK
}

### ===== 安装依赖 =====
install_base() {
  apt update
  apt install -y curl jq uuid-runtime wireguard iptables
}

### ===== WARP（WireGuard 原生）=====
install_warp() {
  log "安装 WARP (WireGuard 原生，仅 Xray 使用)"

  wg genkey | tee /etc/wireguard/warp.key | wg pubkey > /etc/wireguard/warp.pub
  PRIV=$(cat /etc/wireguard/warp.key)

  WARP_JSON=$(curl -s https://api.cloudflareclient.com/v0a745/reg \
    -H 'Content-Type: application/json' \
    -H 'User-Agent: okhttp/3.12.1' \
    --data '{
      "key": "'$(echo "$PRIV" | base64 -w0)'",
      "warp_enabled": true,
      "tos": "'$(date -Is)'",
      "type": "Linux"
    }')

  cat > $WG_CONF <<EOF
[Interface]
PrivateKey = $PRIV
Address = 172.16.0.2/32
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = bmXOC+F1l6d1iQ==
AllowedIPs = 0.0.0.0/0
Endpoint = engage.cloudflareclient.com:2408
EOF

  wg-quick up warp
  systemctl enable wg-quick@warp
}

### ===== Xray + Reality =====
install_xray() {
  log "安装 Xray + Reality"

  bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

  UUID=$(uuidgen)
  PORT=443
  PRIVATE_KEY=$(xray x25519 | awk '/Private/{print $3}')
  PUBLIC_KEY=$(xray x25519 | awk '/Public/{print $3}')
  SHORT_ID=$(openssl rand -hex 8)

  cat > $XRAY_CONF <<EOF
{
  "inbounds":[{
    "port":$PORT,
    "protocol":"vless",
    "settings":{
      "clients":[{"id":"$UUID","flow":"xtls-rprx-vision"}],
      "decryption":"none"
    },
    "streamSettings":{
      "network":"tcp",
      "security":"reality",
      "realitySettings":{
        "dest":"www.cloudflare.com:443",
        "serverNames":["www.cloudflare.com"],
        "privateKey":"$PRIVATE_KEY",
        "shortIds":["$SHORT_ID"]
      }
    }
  }],
  "outbounds":[
    {"tag":"direct","protocol":"freedom"},
    {
      "tag":"warp",
      "protocol":"freedom",
      "streamSettings":{"sockopt":{"interface":"warp"}}
    }
  ],
  "routing":{
    "rules":[{
      "type":"field",
      "domain":["openai.com","netflix.com","google.com"],
      "outboundTag":"warp"
    }]
  }
}
EOF

  systemctl restart xray
}

### ===== Cloudflare Tunnel =====
install_tunnel() {
  log "安装 Cloudflare Tunnel"

  read -p "请输入 Cloudflare Tunnel Token: " CF_TOKEN

  curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /usr/bin/cloudflared
  chmod +x /usr/bin/cloudflared

  cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=cloudflared
After=network.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel run --token $CF_TOKEN
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now cloudflared
}

### ===== 订阅 =====
gen_sub() {
  detect_region
  DOMAIN="your-domain.com"

  LINK="vless://$UUID@$DOMAIN:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.cloudflare.com&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#$REGION-Reality"

  echo "$LINK" > $SUB_FILE
  log "订阅已生成：$SUB_FILE"
}

### ===== 卸载 =====
uninstall_all() {
  systemctl stop xray cloudflared wg-quick@warp || true
  apt purge -y xray cloudflared wireguard
  rm -rf /etc/wireguard /usr/local/etc/xray /etc/cloudflared
  log "已卸载完成"
}

### ===== 菜单 =====
menu() {
  echo "1) 安装全部"
  echo "2) 卸载"
  echo "3) 生成订阅"
  read -p "请选择: " c
  case $c in
    1) install_base; install_warp; install_xray; install_tunnel ;;
    2) uninstall_all ;;
    3) gen_sub ;;
  esac
}

### ===== 主入口 =====
if [[ -t 0 ]]; then
  menu
else
  install_base
  install_warp
  install_xray
fi
