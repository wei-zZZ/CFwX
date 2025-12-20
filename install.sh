#!/usr/bin/env bash
set -e

ROLE=""
UUID_HK="11111111-1111-1111-1111-111111111111"
UUID_LA="22222222-2222-2222-2222-222222222222"
DOMAIN_HK="hk.your-domain.com"
LA_INTERNAL="la.internal"

function detect_role() {
  country=$(curl -s https://ipinfo.io/country || true)
  if [[ "$country" == "US" ]]; then
    ROLE="LA"
  else
    ROLE="HK"
  fi
  echo "[*] Detected role: $ROLE"
}

function install_base() {
  apt update
  apt install -y curl wget unzip socat jq ca-certificates
}

function install_xray() {
  bash <(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
}

function install_warp() {
  curl -fsSL https://pkg.cloudflareclient.com/install.sh | bash
  apt install -y cloudflare-warp
  warp-cli register || true
  warp-cli set-mode proxy
  warp-cli connect || true
}

function install_cloudflared() {
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
  dpkg -i cloudflared.deb
}

function setup_tunnel() {
  mkdir -p /etc/cloudflared
  echo
  echo ">>> 请在浏览器中完成 Cloudflare 登录 <<<"
  cloudflared tunnel login

  if [[ "$ROLE" == "HK" ]]; then
    cloudflared tunnel create hk-tunnel
    cat > /etc/cloudflared/config.yml <<EOF
tunnel: hk-tunnel
credentials-file: /etc/cloudflared/hk-tunnel.json
ingress:
  - hostname: ${DOMAIN_HK}
    service: http://127.0.0.1:10000
  - service: http_status:404
EOF
    cloudflared tunnel route dns hk-tunnel ${DOMAIN_HK}
  else
    cloudflared tunnel create la-tunnel
    cat > /etc/cloudflared/config.yml <<EOF
tunnel: la-tunnel
credentials-file: /etc/cloudflared/la-tunnel.json
ingress:
  - hostname: ${LA_INTERNAL}
    service: http://127.0.0.1:20000
  - service: http_status:404
EOF
    cloudflared tunnel route dns la-tunnel ${LA_INTERNAL}
  fi

  systemctl enable cloudflared --now
}

function setup_xray() {
  mkdir -p /usr/local/etc/xray

  if [[ "$ROLE" == "LA" ]]; then
cat > /usr/local/etc/xray/config.json <<EOF
{
  "inbounds": [{
    "port": 20000,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${UUID_LA}" }],
      "decryption": "none"
    }
  }],
  "outbounds": [{
    "protocol": "socks",
    "settings": {
      "servers": [{
        "address": "127.0.0.1",
        "port": 40000
      }]
    }
  }]
}
EOF
  else
cat > /usr/local/etc/xray/config.json <<EOF
{
  "inbounds": [{
    "port": 10000,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${UUID_HK}" }],
      "decryption": "none"
    }
  }],
  "routing": {
    "rules": [{
      "type": "field",
      "geoip": ["us"],
      "outboundTag": "to-la"
    }]
  },
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "socks",
      "settings": {
        "servers": [{
          "address": "127.0.0.1",
          "port": 40000
        }]
      }
    },
    {
      "tag": "to-la",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "${LA_INTERNAL}",
          "port": 443,
          "users": [{ "id": "${UUID_LA}" }]
        }]
      }
    }
  ]
}
EOF
  fi

  systemctl restart xray
}

function uninstall_all() {
  systemctl stop xray cloudflared || true
  apt purge -y xray cloudflared cloudflare-warp || true
  rm -rf /etc/cloudflared /usr/local/etc/xray
  echo "[*] Uninstalled."
}

case "$1" in
  uninstall)
    uninstall_all
    ;;
  *)
    detect_role
    install_base
    install_xray
    install_warp
    install_cloudflared
    setup_tunnel
    setup_xray
    echo
    echo "✅ $ROLE 节点部署完成"
    ;;
esac
