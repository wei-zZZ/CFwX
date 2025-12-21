#!/usr/bin/env bash
set -e

export DEBIAN_FRONTEND=noninteractive

info(){ echo -e "\033[32m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[33m[WARN]\033[0m $*"; }

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

### ========= 基础依赖 =========
install_base() {
  info "安装基础依赖"
  apt install -y curl wget ca-certificates gnupg lsb-release nginx apache2-utils
}

### ========= sing-box =========
install_singbox() {
  if command -v sing-box >/dev/null; then
    info "sing-box 已存在"
    return
  fi
  info "安装 sing-box"
  curl -fsSL https://sing-box.app/install.sh | bash
}

### ========= WARP =========
install_warp() {
  if command -v warp-cli >/dev/null; then
    info "重置 WARP"
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
}

### ========= cloudflared =========
install_cloudflared() {
  if command -v cloudflared >/dev/null; then
    info "cloudflared 已存在"
    return
  fi

  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloudflare.gpg

  echo "deb [signed-by=/usr/share/keyrings/cloudflare.gpg] \
https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
    >/etc/apt/sources.list.d/cloudflared.list

  apt update
  apt install -y cloudflared
}

### ========= Cloudflare 登录 =========
cf_login() {
  if [[ ! -f /root/.cloudflared/cert.pem ]]; then
    warn "请在浏览器完成 Cloudflare 登录"
    cloudflared tunnel login
    read -p "完成后按 Enter 继续"
  fi
}

### ========= 卸载 =========
uninstall_all() {
  info "开始卸载"

  systemctl stop sing-box cloudflared nginx 2>/dev/null || true

  dpkg -l | grep -q sing-box && apt purge -y sing-box
  dpkg -l | grep -q cloudflared && apt purge -y cloudflared
  dpkg -l | grep -q cloudflare-warp && apt purge -y cloudflare-warp

  rm -rf /etc/cloudflared /root/.cloudflared /etc/sing-box \
         /etc/nginx/sites-enabled/sub /etc/nginx/sites-available/sub \
         /etc/nginx/.htpasswd

  info "卸载完成"
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

info "基础环境部署完成（后续配置可继续加）"
