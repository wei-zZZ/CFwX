#!/usr/bin/env bash
set -e

### ===== 用户需要修改的变量 =====
DOMAIN_HK="hkin.9420ce.top"
LA_INTERNAL="la.internal"

UUID_HK="15e82e74-d472-4f24-827f-d61b434ebb4a"
UUID_LA="15e82e74-d472-4f24-827f-d61b434ebb4b"
### ===============================

ROLE=""
OS_CODENAME=""

log() {
  echo -e "\033[1;32m[INFO]\033[0m $1"
}

warn() {
  echo -e "\033[1;33m[WARN]\033[0m $1"
}

detect_role() {
  local country
  country=$(curl -s https://ipinfo.io/country || true)
  if [[ "$country" == "US" ]]; then
    ROLE="LA"
  else
    ROLE="HK"
  fi
  log "Detected role: $ROLE"
}

detect_os() {
  OS_CODENAME=$(lsb_release -cs 2>/dev/null || true)
  if [[ -z "$OS_CODENAME" ]]; then
    warn "Cannot detect OS codename, fallback to bookworm"
    OS_CODENAME="bookworm"
  fi
  log "OS codename: $OS_CODENAME"
}

install_base() {
  apt update
  apt install -y curl wget jq ca-certificates gnupg lsb-release
}

install_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    log "sing-box already installed"
    return
  fi
  log "Installing sing-box"
  bash <(curl -fsSL https://sing-box.app/install.sh)
}

install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    log "cloudflared already installed"
    return
  fi
  log "Installing cloudflared"
  wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  dpkg -i cloudflared-linux-amd64.deb || apt -f install -y
}

install_warp() {
  if command -v warp-cli >/dev/null 2>&1; then
    log "WARP already installed"
    return
  fi

  log "Trying WARP install via apt repo"

  if curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --dearmor \
    | tee /usr/share/keyrings/cloudflare-warp.gpg >/dev/null; then

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp.gpg] \
https://pkg.cloudflareclient.com/ ${OS_CODENAME} main" \
      > /etc/apt/sources.list.d/cloudflare-warp.list

    if apt update && apt install -y cloudflare-warp; then
      log "WARP installed via apt repo"
      return
    fi
  fi

  warn "Apt repo failed, trying direct deb package"

  local deb_url="https://pkg.cloudflareclient.com/pool/${OS_CODENAME}/main/c/cloudflare-warp/cloudflare-warp_latest_amd64.deb"

  if wget -O /tmp/cloudflare-warp.deb "$deb_url"; then
    if dpkg -i /tmp/cloudflare-warp.deb || apt -f install -y; then
      log "WARP installed via deb package"
      return
    fi
  fi

  warn "WARP installation failed, continue without WARP"
}

start_warp() {
  if ! command -v warp-cli >/dev/null 2>&1; then
    warn "warp-cli not found, skipping WARP startup"
    return
  fi

  log "Starting WARP (proxy mode)"
  warp-cli register || true
  warp-cli set-mode proxy || true
  warp-cli connect || true
}

setup_cloudflared() {
  mkdir -p /etc/cloudflared

  log "Cloudflare Tunnel login required"
  cloudflared tunnel login

  if [[ "$ROLE" == "HK" ]]; then
    cloudflared tunnel create hk-tunnel || true
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
    cloudflared tunnel create la-tunnel || true
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

  mkdir -p /etc/systemd/system/cloudflared.service.d
  cat > /etc/systemd/system/cloudflared.service.d/no-proxy.conf <<EOF
[Service]
Environment=NO_PROXY=127.0.0.1,localhost
EOF

  systemctl daemon-reexec
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
  rm -rf /etc/sing-box /etc/cloudflared \
         /etc/apt/sources.list.d/cloudflare-warp.list \
         /usr/share/keyrings/cloudflare-warp.gpg
  log "Uninstalled all components"
}

case "$1" in
  uninstall)
    uninstall_all
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
    log "$ROLE node deployment completed"
    ;;
esac
  
