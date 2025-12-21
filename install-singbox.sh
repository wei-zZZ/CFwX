#!/usr/bin/env bash
set -e

ROLE=""
DOMAIN_HK="hk.your-domain.com"
LA_INTERNAL="la.internal"

UUID_HK="15e82e74-d472-4f24-827f-d61b434ebb4a"
UUID_LA="15e82e74-d472-4f24-827f-d61b434ebb4b"

detect_role() {
  country=$(curl -s https://ipinfo.io/country || true)
  if [[ "$country" == "US" ]]; then
    ROLE="LA"
  else
    ROLE="HK"
  fi
  echo "[*] Role: $ROLE"
}

install_base() {
  apt update
  apt install -y curl wget jq unzip ca-certificates
}

install_singbox() {
  bash <(curl -fsSL https://sing-box.app/install.sh)
}

install_warp() {
  curl -fsSL https://pkg.cloudflareclient.com/install.sh | bash
  apt install -y cloudflare-warp
  warp-cli register || true
  warp-cli set-mode proxy
  warp-cli connect || true
}

install_cloudflared() {
  wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  dpkg -i cloudflared-linux-amd64.deb
}

setup_tunnel() {
  mkdir -p /etc/cloudflared
  echo ">>> Cloudflare Tunnel 登录 <<<"
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

setup_singbox() {
  mkdir -p /etc/sing-box

  if [[ "$ROLE" == "LA" ]]; then
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info" },
  "inbounds": [{
    "type": "vless",
    "listen": "127.0.0.1",
    "listen_port": 20000,
    "users": [{ "uuid": "${UUID_LA}" }]
  }],
  "outbounds": [{
    "type": "socks",
    "server": "127.0.0.1",
    "server_port": 40000
  }]
}
EOF
  else
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info" },
  "inbounds": [{
    "type": "vless",
    "listen": "127.0.0.1",
    "listen_port": 10000,
    "users": [{ "uuid": "${UUID_HK}" }]
  }],
  "route": {
    "rules": [{
      "geoip": ["us"],
      "outbound": "to-la"
    }]
  },
  "outbounds": [
    {
      "type": "socks",
      "tag": "direct",
      "server": "127.0.0.1",
      "server_port": 40000
    },
    {
      "type": "vless",
      "tag": "to-la",
      "server": "${LA_INTERNAL}",
      "server_port": 443,
      "uuid": "${UUID_LA}"
    }
  ]
}
EOF
  fi

  systemctl enable sing-box --now
}

uninstall_all() {
  systemctl stop sing-box cloudflared || true
  apt purge -y sing-box cloudflared cloudflare-warp || true
  rm -rf /etc/sing-box /etc/cloudflared
  echo "[*] Uninstalled."
}

case "$1" in
  uninstall)
    uninstall_all
    ;;
  *)
    detect_role
    install_base
    install_singbox
    install_warp
    install_cloudflared
    setup_tunnel
    setup_singbox
    echo "✅ $ROLE 节点 sing-box 部署完成"
    ;;
esac
