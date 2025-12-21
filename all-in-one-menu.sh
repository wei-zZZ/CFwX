#!/usr/bin/env bash
set -e

### ========= 基础 =========
export DEBIAN_FRONTEND=noninteractive
WORKDIR=/opt/proxy-stack
SUBDIR=$(tr -dc a-z0-9 </dev/urandom | head -c 8)
AUTH_USER=sub
AUTH_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

mkdir -p $WORKDIR

info(){ echo -e "\033[32m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[33m[WARN]\033[0m $*"; }
err(){ echo -e "\033[31m[ERR]\033[0m $*"; exit 1; }

### ========= 修复 APT 源 =========
fix_apt() {
  info "修复 Debian APT 源"
  . /etc/os-release

  if [[ "$VERSION_CODENAME" == "bullseye" ]]; then
cat >/etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian bullseye main contrib non-free
deb http://deb.debian.org/debian bullseye-updates main contrib non-free
deb http://security.debian.org/debian-security bullseye-security main contrib non-free
EOF
  else
cat >/etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian bookworm main contrib non-free
deb http://deb.debian.org/debian bookworm-updates main contrib non-free
deb http://security.debian.org/debian-security bookworm-security main contrib non-free
EOF
  fi

  apt clean
  apt update
}

### ========= 安装基础依赖 =========
install_base() {
  apt install -y curl wget unzip nginx apache2-utils
}

### ========= 安装 sing-box =========
install_singbox() {
  if command -v sing-box >/dev/null; then
    info "sing-box 已存在"
    return
  fi
  info "安装 sing-box"
  curl -fsSL https://sing-box.app/install.sh | bash
}

### ========= 安装 WARP =========
install_warp() {
  if command -v warp-cli >/dev/null; then
    info "WARP 已存在"
    warp-cli registration delete || true
  fi

  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp.gpg

  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp.gpg] \
https://pkg.cloudflareclient.com bookworm main" \
    >/etc/apt/sources.list.d/cloudflare-warp.list

  apt update
  apt install -y cloudflare-warp

  warp-cli register
  warp-cli set-mode proxy
  warp-cli connect
}

### ========= 安装 cloudflared =========
install_cloudflared() {
  if command -v cloudflared >/dev/null; then
    info "cloudflared 已存在"
    return
  fi

  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloudflare.gpg

  echo "deb [signed-by=/usr/share/keyrings/cloudflare.gpg] \
https://pkg.cloudflare.com/cloudflared bookworm main" \
    >/etc/apt/sources.list.d/cloudflared.list

  apt update
  apt install -y cloudflared
}

### ========= Cloudflare 登录 =========
cf_login() {
  if [[ ! -f /root/.cloudflared/cert.pem ]]; then
    warn "请完成 Cloudflare 登录"
    cloudflared tunnel login
    read -p "完成网页登录后按 Enter 继续"
  fi
}

### ========= 配置 sing-box =========
config_singbox() {
cat >/etc/sing-box/config.json <<EOF
{
  "log": { "level": "info" },
  "inbounds": [{
    "type": "mixed",
    "listen": "127.0.0.1",
    "listen_port": 3000
  }],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    {
      "type": "socks",
      "tag": "warp",
      "server": "127.0.0.1",
      "server_port": 40000
    }
  ],
  "route": {
    "rules": [
      { "geoip": "us", "outbound": "warp" },
      { "geoip": ["jp","sg","hk","tw"], "outbound": "direct" }
    ]
  }
}
EOF

  systemctl enable sing-box --now
}

### ========= Nginx 订阅 =========
config_nginx() {
  htpasswd -bc /etc/nginx/.htpasswd $AUTH_USER $AUTH_PASS

cat >/etc/nginx/sites-available/sub <<EOF
server {
  listen 80;
  location /$SUBDIR/sub/ {
    auth_basic "Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd;
    proxy_pass http://127.0.0.1:3000/;
  }
}
EOF

  ln -sf /etc/nginx/sites-available/sub /etc/nginx/sites-enabled/sub
  rm -f /etc/nginx/sites-enabled/default
  systemctl restart nginx
}

### ========= Cloudflare Tunnel =========
config_tunnel() {
  TUNNEL_NAME=proxy-tunnel
  cloudflared tunnel list | grep -q $TUNNEL_NAME || cloudflared tunnel create $TUNNEL_NAME

  TID=$(cloudflared tunnel list | awk "/$TUNNEL_NAME/ {print \$1}")

cat >/etc/cloudflared/config.yml <<EOF
tunnel: $TID
credentials-file: /etc/cloudflared/$TID.json

ingress:
  - service: http://127.0.0.1:80
  - service: http_status:404
EOF

  cloudflared service uninstall || true
  cloudflared service install
  systemctl restart cloudflared
}

### ========= 卸载 =========
uninstall_all() {
  systemctl stop sing-box cloudflared nginx || true
  apt purge -y sing-box cloudflared cloudflare-warp nginx
  rm -rf /etc/cloudflared /root/.cloudflared /etc/sing-box
  info "已完全卸载"
  exit 0
}

### ========= 菜单 =========
echo "1) HK 部署"
echo "2) LA 部署"
echo "3) 卸载"
read -p "选择: " CHOICE

[[ "$CHOICE" == "3" ]] && uninstall_all

fix_apt
install_base
install_singbox
install_warp
install_cloudflared
cf_login
config_singbox
config_nginx
config_tunnel

echo "=============================="
echo "部署完成"
echo "订阅路径: https://你的域名/$SUBDIR/sub/"
echo "账号: $AUTH_USER"
echo "密码: $AUTH_PASS"
echo "=============================="
