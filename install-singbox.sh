#!/usr/bin/env bash
set -e

### ===== 用户需要修改的变量 =====
DOMAIN_HK="hkkkin.9420ce.top"
LA_INTERNAL="laaaing"

UUID_HK="15e82e74-d472-4f24-827f-d61b434ebb4a"
UUID_LA="15e82e74-d472-4f24-827f-d61b434ebb4b"
### ===============================

ROLE=""
OS_CODENAME=""

log(){ echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $1"; }

detect_role() {
  [[ "$(curl -s https://ipinfo.io/country)" == "US" ]] && ROLE="LA" || ROLE="HK"
  log "Role: $ROLE"
}

detect_os() {
  OS_CODENAME=$(lsb_release -cs 2>/dev/null || echo bookworm)
}

install_base() {
  apt update
  apt install -y curl wget jq ca-certificates gnupg lsb-release python3
}

install_singbox() {
  command -v sing-box >/dev/null && return
  bash <(curl -fsSL https://sing-box.app/install.sh)
}

install_cloudflared() {
  command -v cloudflared >/dev/null && return
  wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  dpkg -i cloudflared-linux-amd64.deb || apt -f install -y
}

install_warp() {
  command -v warp-cli >/dev/null && return
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --dearmor \
    | tee /usr/share/keyrings/cloudflare-warp.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp.gpg] \
https://pkg.cloudflareclient.com/ ${OS_CODENAME} main" \
    > /etc/apt/sources.list.d/cloudflare-warp.list
  apt update && apt install -y cloudflare-warp || true
}

start_warp() {
  command -v warp-cli >/dev/null || return
  if warp-cli --help | grep -q registration; then
    warp-cli registration new || true
    warp-cli mode proxy || true
  else
    warp-cli register || true
    warp-cli set-mode proxy || true
  fi
  warp-cli connect || true
}

setup_cloudflared() {
  mkdir -p /etc/cloudflared
  cloudflared tunnel login

  if [[ "$ROLE" == "HK" ]]; then
    NAME="hk-tunnel"
    HOST="$DOMAIN_HK"
    PORT=10000
  else
    NAME="la-tunnel"
    HOST="la.internal"
    PORT=20000
  fi

  cloudflared tunnel list | grep -q "$NAME" || cloudflared tunnel create "$NAME" || true
  cloudflared tunnel route dns "$NAME" "$HOST" || warn "DNS exists, skipped"

  TOKEN_FILE="/etc/cloudflared/token.json"
  cloudflared tunnel token "$NAME" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"

  cat > /etc/cloudflared/config.yml <<EOF
tunnel: ${NAME}
credentials-file: ${TOKEN_FILE}

ingress:
  - hostname: ${HOST}
    service: http://127.0.0.1:${PORT}
  - service: http_status:404
EOF

  if ! systemctl list-unit-files | grep -q cloudflared.service; then
    cloudflared service install
  fi

  systemctl daemon-reload
  systemctl enable cloudflared --now
}

setup_singbox() {
  mkdir -p /etc/sing-box

  if [[ "$ROLE" == "HK" ]]; then
cat > /etc/sing-box/config.json <<EOF
{
  "inbounds":[{
    "type":"vless",
    "listen":"127.0.0.1",
    "listen_port":10000,
    "users":[{"uuid":"${UUID_HK}"}]
  }],
  "route":{"rules":[{"geoip":["us"],"outbound":"to-la"}]},
  "outbounds":[
    {"type":"direct","tag":"direct"},
    {
      "type":"vless",
      "tag":"to-la",
      "server":"la.internal",
      "server_port":443,
      "uuid":"${UUID_LA}"
    }
  ]
}
EOF
  else
cat > /etc/sing-box/config.json <<EOF
{
  "inbounds":[{
    "type":"vless",
    "listen":"127.0.0.1",
    "listen_port":20000,
    "users":[{"uuid":"${UUID_LA}"}]
  }],
  "outbounds":[{"type":"direct"}]
}
EOF
  fi

  systemctl enable sing-box --now
}

setup_subscription() {
  [[ "$ROLE" != "HK" ]] && return

  mkdir -p /var/www/sub
cat > /var/www/sub/config.json <<EOF
{
  "outbounds":[{
    "type":"vless",
    "server":"${DOMAIN_HK}",
    "server_port":443,
    "uuid":"${UUID_HK}",
    "tls":{"enabled":true},
    "transport":{"type":"ws","path":"/"}
  }]
}
EOF

cat > /var/www/sub/server.py <<EOF
from http.server import HTTPServer, SimpleHTTPRequestHandler
import os
os.chdir("/var/www/sub")
HTTPServer(("127.0.0.1", 8080), SimpleHTTPRequestHandler).serve_forever()
EOF

  nohup python3 /var/www/sub/server.py >/dev/null 2>&1 &
}

case "$1" in
  uninstall)
    systemctl stop sing-box cloudflared || true
    apt purge -y sing-box cloudflared cloudflare-warp || true
    rm -rf /etc/sing-box /etc/cloudflared /var/www/sub
    ;;
  *)
    detect_role
    detect_os
    install_base
    install_singbox
    install_cloudflared
    install_warp
    start_warp
    setup_cloudflared
    setup_singbox
    setup_subscription
    log "All done ($ROLE)"
    ;;
esac
