#!/usr/bin/env bash
set -e

### ===== 用户配置 =====
DOMAIN_HK="hkin.9420ce.top"
UUID_HK="2828f347-d9f8-4342-85af-3ef06270793a"
UUID_LA="c9360249-7aa9-4cf0-8edc-4c0362e84b0f"
LA_INTERNAL="la.internal"
### ====================

ROLE=""
OS_CODENAME=""

msg() { echo -e "\033[1;32m[+] $1\033[0m"; }
err() { echo -e "\033[1;31m[!] $1\033[0m"; }

detect_role() {
  local c
  c=$(curl -fsSL https://ipinfo.io/country || true)
  [[ "$c" == "US" ]] && ROLE="LA" || ROLE="HK"
  msg "Detected role: $ROLE"
}

detect_os() {
  . /etc/os-release
  OS_CODENAME=$VERSION_CODENAME
  msg "OS: $PRETTY_NAME ($OS_CODENAME)"
}

install_base() {
  apt update
  apt install -y curl wget jq unzip socat ca-certificates gnupg lsb-release
}

install_xray() {
  msg "Installing Xray"
  bash <(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
}

install_cloudflared() {
  msg "Installing cloudflared"
  wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  dpkg -i cloudflared-linux-amd64.deb
}

install_warp() {
  msg "Installing Cloudflare WARP (stable method)"

  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --dearmor \
    | tee /usr/share/keyrings/cloudflare-warp.gpg >/dev/null

  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp.gpg] \
https://pkg.cloudflareclient.com/ ${OS_CODENAME} main" \
    > /etc/apt/sources.list.d/cloudflare-client.list

  apt update
  apt install -y cloudflare-warp

setup_warp() {
  echo "[*] Configuring WARP"

  # 判断 warp-cli 是新版本还是旧版本
  if warp-cli --help 2>&1 | grep -q "registration"; then
    # 新版 warp-cli
    warp-cli registration new || true
    warp-cli mode proxy || true
  else
    # 旧版 warp-cli
    warp-cli register || true
    warp-cli set-mode proxy || true
  fi

  warp-cli connect || true
}


}

setup_tunnel() {
  msg "Cloudflare Tunnel login required"
  cloudflared tunnel login

  mkdir -p /etc/cloudflared

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

  systemctl edit cloudflared <<EOF
[Service]
Environment=NO_PROXY=127.0.0.1,localhost
EOF
}

setup_xray() {
  msg "Configuring Xray"
  mkdir -p /usr/local/etc/xray

  if [[ "$ROLE" == "LA" ]]; then
cat > /usr/local/etc/xray/config.json <<EOF
{
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": 20000,
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
    "listen": "127.0.0.1",
    "port": 10000,
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

uninstall_all() {
  err "Uninstalling everything"
  systemctl stop xray cloudflared || true
  apt purge -y cloudflare-warp cloudflared || true
  rm -rf /etc/cloudflared /usr/local/etc/xray
  err "Done"
}

### ===== main =====
case "$1" in
  uninstall)
    uninstall_all
    ;;
  *)
    detect_role
    detect_os
    install_base
    install_xray
    install_cloudflared
    install_warp
    setup_warp
    setup_tunnel
    setup_xray
    msg "$ROLE node deployment finished"
    ;;
esac
