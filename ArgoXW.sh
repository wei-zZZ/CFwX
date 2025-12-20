#!/usr/bin/env bash
set -e

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

XRAY_DIR="/usr/local/etc/xray"
CF_DIR="/etc/cloudflared"
SUB_DIR="/root/subscription"

########################################
# 基础函数
########################################
msg() { echo -e "${GREEN}$1${RESET}"; }
warn() { echo -e "${YELLOW}$1${RESET}"; }
err() { echo -e "${RED}$1${RESET}"; }

need_root() {
  [[ $EUID -ne 0 ]] && err "请使用 root 运行" && exit 1
}

########################################
# 防 SSH：禁用 IPv6
########################################
disable_ipv6() {
  msg "禁用 IPv6（防 SSH 断连）"
  cat >/etc/sysctl.d/99-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
  sysctl --system >/dev/null
}

########################################
# 安装依赖
########################################
install_base() {
  apt update
  apt install -y curl wget unzip jq socat iproute2 ca-certificates
}

########################################
# 安装 Xray + Reality
########################################
install_xray() {
  msg "安装 Xray"
  bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

  mkdir -p $XRAY_DIR

  read -rp "请输入 Reality 域名（如 www.microsoft.com）: " REALITY_DOMAIN
  read -rp "请输入 VLESS UUID（回车自动生成）: " UUID
  UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}

  read -rp "请输入监听端口（默认 10000）: " XRAY_PORT
  XRAY_PORT=${XRAY_PORT:-10000}

  read -rp "请输入 Reality 公钥（回车自动生成）: " PUBKEY
  read -rp "请输入 Reality 私钥（回车自动生成）: " PRIVKEY

  if [[ -z "$PUBKEY" || -z "$PRIVKEY" ]]; then
    KEYS=$(xray x25519)
    PRIVKEY=$(echo "$KEYS" | grep Private | awk '{print $3}')
    PUBKEY=$(echo "$KEYS" | grep Public | awk '{print $3}')
  fi

  cat >$XRAY_DIR/config.json <<EOF
{
  "inbounds": [{
    "port": $XRAY_PORT,
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
        "dest": "$REALITY_DOMAIN:443",
        "serverNames": ["$REALITY_DOMAIN"],
        "privateKey": "$PRIVKEY",
        "shortIds": [""]
      }
    }
  }],
  "outbounds": [{
    "tag": "warp",
    "protocol": "socks",
    "settings": {
      "servers": [{
        "address": "127.0.0.1",
        "port": 40000
      }]
    }
  },{
    "protocol": "freedom",
    "tag": "direct"
  }],
  "routing": {
    "rules": [{
      "type": "field",
      "outboundTag": "warp",
      "domain": ["geosite:openai","geosite:netflix","geosite:google"]
    }]
  }
}
EOF

  systemctl restart xray
  msg "Xray 安装完成"
}

########################################
# 安装 WARP（仅 Proxy）
########################################
install_warp() {
  msg "安装 Cloudflare WARP（仅供 xray 使用）"

  curl -fsSL https://pkg.cloudflareclient.com/install.sh | bash
  apt install -y cloudflare-warp

  warp-cli disconnect || true

  if warp-cli --help | grep -q registration; then
    warp-cli registration new || true
  else
    warp-cli register || true
  fi

  warp-cli mode proxy
  warp-cli proxy port 40000
  warp-cli connect

  msg "WARP Proxy 启动成功（127.0.0.1:40000）"
}

########################################
# 安装 Cloudflare Tunnel
########################################
install_tunnel() {
  msg "安装 Cloudflare Tunnel"

  apt install -y cloudflared
  mkdir -p $CF_DIR

  read -rp "是否需要 Tunnel？(y/n): " NEED_CF
  [[ "$NEED_CF" != "y" ]] && return

  read -rp "请输入 Tunnel Token: " CF_TOKEN

  cat >/etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=cloudflared
After=network.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel run --token $CF_TOKEN
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable cloudflared
  systemctl restart cloudflared

  msg "Cloudflare Tunnel 启动完成"
}

########################################
# 生成订阅
########################################
gen_sub() {
  mkdir -p $SUB_DIR
  IP=$(curl -s ipv4.ip.sb)

  CONF=$(jq -r '.inbounds[0]' $XRAY_DIR/config.json)

  UUID=$(echo "$CONF" | jq -r '.settings.clients[0].id')
  PORT=$(echo "$CONF" | jq -r '.port')
  SNI=$(echo "$CONF" | jq -r '.streamSettings.realitySettings.serverNames[0]')
  PUBKEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' $XRAY_DIR/config.json)

  cat >$SUB_DIR/vless.txt <<EOF
vless://$UUID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBKEY&type=tcp#Reality-WARP
EOF

  msg "订阅生成完成：$SUB_DIR/vless.txt"
}

########################################
# 卸载
########################################
uninstall_all() {
  systemctl stop xray cloudflared warp-svc || true
  apt purge -y cloudflare-warp cloudflared xray || true
  rm -rf $XRAY_DIR $CF_DIR
  msg "卸载完成"
}

########################################
# 菜单
########################################
menu() {
  echo
  echo "1) 安装（Xray + Reality + WARP + Tunnel）"
  echo "2) 生成订阅"
  echo "3) 卸载 / 重置"
  echo "0) 退出"
  read -rp "请选择: " CHOICE

  case $CHOICE in
    1)
      disable_ipv6
      install_base
      install_warp
      install_xray
      install_tunnel
      ;;
    2) gen_sub ;;
    3) uninstall_all ;;
    0) exit ;;
    *) warn "无效选项" ;;
  esac
}

need_root
menu
