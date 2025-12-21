#!/usr/bin/env bash
set -e

export DEBIAN_FRONTEND=noninteractive

### ===== 工具函数 =====
green(){ echo -e "\033[32m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }
red(){ echo -e "\033[31m$*\033[0m"; }

### ===== 菜单 =====
echo "================================="
echo "1) HK 节点部署"
echo "2) LA 节点部署"
echo "3) 完全卸载"
echo "================================="
read -p "请选择: " ROLE

### ===== 卸载 =====
if [[ "$ROLE" == "3" ]]; then
  yellow "开始完全卸载..."

  systemctl stop sing-box cloudflared nginx 2>/dev/null || true
  systemctl disable sing-box cloudflared nginx 2>/dev/null || true

  dpkg -l | grep -q sing-box && apt purge -y sing-box
  dpkg -l | grep -q cloudflared && apt purge -y cloudflared
  dpkg -l | grep -q cloudflare-warp && apt purge -y cloudflare-warp
  dpkg -l | grep -q nginx && apt purge -y nginx

  rm -rf /etc/sing-box \
         /etc/cloudflared \
         /root/.cloudflared \
         /etc/nginx \
         /var/log/nginx

  green "卸载完成（含 cert.pem）"
  exit 0
fi

### ===== 修复 APT 源 =====
green "[STEP] 修复 Debian 源"
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

### ===== 基础依赖（关键：gnupg）=====
green "[STEP] 安装基础依赖"
apt install -y curl wget ca-certificates gnupg lsb-release nginx apache2-utils

### ===== 安装 sing-box =====
if ! command -v sing-box >/dev/null; then
  green "[STEP] 安装 sing-box"
  curl -fsSL https://sing-box.app/install.sh | bash
else
  yellow "sing-box 已存在"
fi

### ===== 安装 WARP =====
green "[STEP] 安装 WARP"
if command -v warp-cli >/dev/null; then
  warp-cli registration delete || true
  warp-cli disconnect || true
fi

curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
  | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp.gpg

echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp.gpg] \
https://pkg.cloudflareclient.com $(lsb_release -cs) main" \
>/etc/apt/sources.list.d/cloudflare-warp.list

apt update
apt install -y cloudflare-warp

warp-cli register
warp-cli set-mode proxy
warp-cli connect

### ===== 安装 cloudflared =====
green "[STEP] 安装 cloudflared"
if ! command -v cloudflared >/dev/null; then
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloudflare.gpg

  echo "deb [signed-by=/usr/share/keyrings/cloudflare.gpg] \
https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
>/etc/apt/sources.list.d/cloudflared.list

  apt update
  apt install -y cloudflared
fi

### ===== Cloudflare 登录 =====
if [[ ! -f /root/.cloudflared/cert.pem ]]; then
  yellow "[ACTION] 请完成 Cloudflare Tunnel 登录"
  cloudflared tunnel login
  read -p "网页登录完成后按 Enter 继续"
fi

### ===== sing-box 配置 =====
green "[STEP] 配置 sing-box"
mkdir -p /etc/sing-box

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

### ===== Nginx 订阅 =====
SUB_PATH=$(tr -dc a-z0-9 </dev/urandom | head -c 8)
USER=sub
PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

htpasswd -bc /etc/nginx/.htpasswd $USER $PASS

cat >/etc/nginx/sites-available/sub <<EOF
server {
  listen 80;
  location /$SUB_PATH/sub/ {
    auth_basic "Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd;
    proxy_pass http://127.0.0.1:3000/;
  }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/sub /etc/nginx/sites-enabled/sub
systemctl restart nginx

### ===== Cloudflare Tunnel =====
green "[STEP] 创建 Tunnel"
TNAME=proxy-tunnel

cloudflared tunnel list | grep -q $TNAME || cloudflared tunnel create $TNAME
TID=$(cloudflared tunnel list | awk "/$TNAME/ {print \$1}")

mkdir -p /etc/cloudflared
cp /root/.cloudflared/$TID.json /etc/cloudflared/

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

### ===== 完成 =====
green "================================="
green "部署完成"
green "订阅地址：https://你的域名/$SUB_PATH/sub/"
green "Basic Auth 用户名：$USER"
green "Basic Auth 密码：$PASS"
green "================================="
