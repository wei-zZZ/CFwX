#!/bin/bash
set -e

BASE_DIR="/opt/xray-stack"
SUB_DIR="/var/www/sub"

mkdir -p $BASE_DIR $SUB_DIR

################################
# 工具函数
################################
pause() {
  read -rp "按 Enter 继续..."
}

is_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 运行"
    exit 1
  fi
}

detect_region() {
  if curl -s ipinfo.io | grep -qi "Hong Kong"; then
    REGION="HK"
  else
    REGION="LA"
  fi
}

################################
# 安装 xray + Reality
################################
install_xray() {
  echo "▶ 安装 xray + Reality"

  bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

  read -rp "请输入监听端口（默认 443）: " PORT
  PORT=${PORT:-443}

  read -rp "请输入 UUID: " UUID

  KEY=$(xray x25519)
  PRIVATE_KEY=$(echo "$KEY" | awk '/PrivateKey/ {print $2}')
  PUBLIC_KEY=$(echo "$KEY" | awk '/PublicKey/ {print $2}')

  read -rp "请输入 Reality SNI（如 www.cloudflare.com）: " SNI
  read -rp "请输入 shortId（默认 abcd）: " SID
  SID=${SID:-abcd}

  cat > /usr/local/etc/xray/config.json <<EOF
{
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SID}"]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF

  systemctl restart xray

  echo
  echo "✅ xray 安装完成"
  echo "PublicKey: ${PUBLIC_KEY}"
  echo "UUID:      ${UUID}"

  echo "${PORT}|${UUID}|${PUBLIC_KEY}|${SNI}|${SID}" > $BASE_DIR/xray.info
  pause
}

################################
# 安装 WARP（仅 xray 使用）
################################
install_warp() {
  echo "▶ 安装 Cloudflare WARP"

  apt update
  apt install -y curl gnupg lsb-release

  curl https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor > /usr/share/keyrings/cloudflare-warp.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/cloudflare-client.list

  apt update
  apt install -y cloudflare-warp

if warp-cli --help | grep -q "registration"; then
  warp-cli registration new
else
  warp-cli register
fi

warp-cli connect



  echo "✅ WARP 已连接（仅用于 xray）"
  pause
}

################################
# 安装 Cloudflare Tunnel
################################
install_tunnel() {
  echo "▶ 安装 Cloudflare Tunnel"

  curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /usr/bin/cloudflared
  chmod +x /usr/bin/cloudflared

  read -rp "请输入 Cloudflare Account ID: " CF_ACCOUNT
  read -rp "请输入 Global API Key: " CF_API
  read -rp "请输入 Tunnel 名称: " TUNNEL_NAME

  export CF_API_KEY="$CF_API"
  export CF_ACCOUNT_ID="$CF_ACCOUNT"

  cloudflared tunnel create "$TUNNEL_NAME"

  TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')

  mkdir -p /etc/cloudflared

  cat > /etc/cloudflared/config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/${TUNNEL_ID}.json

ingress:
  - service: http://127.0.0.1:10000
EOF

  cloudflared service install
  systemctl enable cloudflared
  systemctl restart cloudflared

  echo "✅ Tunnel 已启动"
  pause
}

################################
# 生成订阅
################################
gen_sub() {
  echo "▶ 生成客户端订阅"

  detect_region

  IFS="|" read PORT UUID PUBKEY SNI SID < $BASE_DIR/xray.info

  read -rp "请输入服务器地址（域名或 IP）: " SERVER

  VLESS="vless://${UUID}@${SERVER}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBKEY}&sid=${SID}#${REGION}"

  echo "$VLESS" | base64 -w0 > $SUB_DIR/vless.txt
  echo "$VLESS" > $SUB_DIR/info.txt

  python3 -m http.server 8080 --directory $SUB_DIR >/dev/null 2>&1 &

  echo
  echo "✅ 订阅生成完成"
  echo "订阅地址: http://${SERVER}:8080/vless.txt"
  pause
}

################################
# 卸载 / 重置
################################
uninstall_all() {
  echo "⚠️ 即将完全卸载"
  read -rp "确认继续？[y/N]: " OK
  [ "$OK" != "y" ] && return

  systemctl stop xray cloudflared || true
  systemctl disable xray cloudflared || true

  rm -rf /usr/local/etc/xray
  rm -f /usr/local/bin/xray
  rm -f /etc/systemd/system/xray.service

  rm -rf /etc/cloudflared /root/.cloudflared
  rm -f /usr/bin/cloudflared
  rm -f /etc/systemd/system/cloudflared.service

warp-cli disconnect || true

if warp-cli --help | grep -q "registration"; then
  warp-cli registration delete || true
else
  warp-cli deregister || true
fi
  apt purge -y cloudflare-warp || true

  rm -rf $BASE_DIR $SUB_DIR

  systemctl daemon-reload

  echo "✅ 已完全卸载，建议 reboot"
  pause
}

################################
# 菜单
################################
is_root

while true; do
  clear
  echo "=============================="
  echo " HK / LA + Tunnel + WARP + Xray"
  echo "=============================="
  echo "1) 安装 Xray + Reality"
  echo "2) 安装 WARP（仅 xray）"
  echo "3) 安装 Cloudflare Tunnel"
  echo "4) 生成客户端订阅"
  echo "5) 卸载 / 重置"
  echo "0) 退出"
  echo
  read -rp "请选择: " CHOICE

  case $CHOICE in
    1) install_xray ;;
    2) install_warp ;;
    3) install_tunnel ;;
    4) gen_sub ;;
    5) uninstall_all ;;
    0) exit 0 ;;
    *) echo "无效选择"; pause ;;
  esac
done
