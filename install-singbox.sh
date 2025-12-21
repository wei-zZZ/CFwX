#!/usr/bin/env bash
set -e

### ===== 用户需要修改的变量 =====
DOMAIN_HK="hking.9420ce.top"
LA_INTERNAL="la.internal"

UUID_HK="15e82e74-d472-4f24-827f-d61b434ebb4a"
UUID_LA="15e82e74-d472-4f24-827f-d61b434ebb4b"
### ===============================

ROLE=""
OS_CODENAME=""

log() { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

detect_role() {
  local c
  c=$(curl -s https://ipinfo.io/country || true)
  [[ "$c" == "US" ]] && ROLE="LA" || ROLE="HK"
  log "Role: $ROLE"
}

detect_os() {
  OS_CODENAME=$(lsb_release -cs 2>/dev/null || echo "bookworm")
  log "OS: $OS_CODENAME"
}

install_base() {
  apt update
  apt install -y curl wget jq ca-certificates gnupg lsb-release
}

install_singbox() {
  command -v sing-box >/dev/null && return
  log "Installing sing-box"
  bash <(curl -fsSL https://sing-box.app/install.sh)
}

install_cloudflared() {
  command -v cloudflared >/dev/null && return
  log "Installing cloudflared"
  wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  dpkg -i cloudflared-linux-amd64.deb || apt -f install -y
}

install_warp() {
  command -v warp-cli >/dev/null && return

  log "Installing WARP (auto fallback)"

  if curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --dearmor \
    | tee /usr/share/keyrings/cloudflare-warp.gpg >/dev/null; then

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp.gpg] \
https://pkg.cloudflareclient.com/ ${OS_CODENAME} main" \
      > /etc/apt/sources.list.d/cloudflare-warp.list

    if apt update && apt install -y cloudflare-warp; then
      log "WARP installed via apt"
      return
    fi
  fi

  warn "Apt failed, trying direct deb"
  if wget -O /tmp/warp.deb \
    "https://pkg.cloudflareclient.com/pool/${OS_CODENAME}/main/c/cloudflare-warp/cloudflare-warp_latest_amd64.deb"; then
    dpkg -i /tmp/warp.deb || apt -f install -y
  fi
}

start_warp() {
  command -v warp-cli >/dev/null || { warn "warp-cli not found"; return; }

  log "Initializing WARP"

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

  log "Cloudflare Tunnel login"
  cloudflared tunnel login

  if [[ "$ROLE" == "HK" ]]; then
    cloudflared tunnel list | grep -q hk-tunnel || cloudflared tunnel create hk-tunnel || true
    cloudflared tunnel route dns hk-tunnel ${DOMAIN_HK} || warn "DNS record exists, skipped"

    cat > /etc/cloudflared/config.yml <<EOF
tunnel: hk-tunnel
credentials-file: /etc/cloudflared/hk-tunnel.json
ingress:
  - hostname: ${DOMAIN_HK}
    service: http://127.0.0.1:10000
  - service: http_status:404
EOF
  else
    cloudflared tunnel create la-tunnel || true
    cloudflared tunnel route dns la-tunnel ${LA_INTERNAL} || warn "DNS record exists, skipped"

    cat > /etc/cloudflared/config.yml <<EOF
tunnel: la-tunnel
credentials-file: /etc/cloudflared/la-tunnel.json
ingress:
  - hostname: ${LA_INTERNAL}
    service: http://127.0.0.1:20000
  - service: http_status:404
EOF
  fi

  mkdir -p /etc/systemd/system/cloudflared.service.d
  cat > /etc/systemd/system/cloudflared.service.d/no-proxy.conf <<EOF
[Service]
Environment=NO_PROXY=127.0.0.1,localhost
EOF

  systemctl daemon-reexec
  if ! systemctl list-unit-files | grep -q cloudflared.service; then
  cloudflared service install
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
  rm -rf /etc/sing-box /etc/cloudflared \
         /etc/apt/sources.list.d/cloudflare-warp.list \
         /usr/share/keyrings/cloudflare-warp.gpg
  log "All components removed"
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
    log "$ROLE deployment completed successfully"
    ;;
esac
