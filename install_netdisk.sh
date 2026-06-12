#!/usr/bin/env bash
#
# 一键搭建简易网盘 / 下载站
#   - Filebrowser 当管理后台（你登录后上传/整理文件）
#   - nginx 直接对外发文件（用户走公开链接下载，无需登录）+ HTTPS
#
# 用法（参数传入，无需改文件）：
#   bash install_netdisk.sh <域名> <admin密码> <证书邮箱>
#
# 一行联网安装：
#   curl -fsSL <raw直链> | sudo bash -s -- example.com 强密码 you@example.com
#
# 适用：Debian 11+ / Ubuntu 20.04+ / CentOS 7+，需 root 或 sudo。
# 前置：域名已备案，且 DNS 已解析到这台服务器的公网 IP；安全组放行 80、443。

set -euo pipefail

# ===== 参数：命令行 > 环境变量 =====
DOMAIN="${1:-${DOMAIN:-}}"        # 备案域名
ADMIN_PASS="${2:-${ADMIN_PASS:-}}"# Filebrowser 后台 admin 密码
EMAIL="${3:-${EMAIL:-}}"          # 申请 HTTPS 证书用（续期通知）
# ==================================

FILES_DIR="/srv/files"          # 公开下载目录
FB_DIR="/opt/filebrowser"       # Filebrowser 数据目录

if [[ $EUID -ne 0 ]]; then echo "请用 root 或 sudo 运行"; exit 1; fi
if [[ -z "$DOMAIN" || -z "$ADMIN_PASS" ]]; then
  echo "用法: bash install_netdisk.sh <域名> <admin密码> <证书邮箱>"
  echo "例:   bash install_netdisk.sh example.com 'MyStr0ngPass' you@example.com"
  exit 1
fi
EMAIL="${EMAIL:-admin@$DOMAIN}"   # 邮箱没填就用默认

echo ">>> [1/5] 安装依赖（nginx、certbot）..."
if command -v apt >/dev/null 2>&1; then
  apt update -y
  apt install -y curl nginx certbot python3-certbot-nginx
elif command -v yum >/dev/null 2>&1; then
  yum install -y epel-release || true
  yum install -y curl nginx certbot python3-certbot-nginx
else
  echo "未识别的系统（既无 apt 也无 yum），请手动装 nginx/certbot"; exit 1
fi

echo ">>> [2/5] 安装 Filebrowser..."
if ! command -v filebrowser >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/filebrowser/filebrowser/master/scripts/get.sh | bash
fi

echo ">>> [3/5] 初始化目录与账号..."
mkdir -p "$FILES_DIR" "$FB_DIR"
cd "$FB_DIR"
if [[ ! -f "$FB_DIR/fb.db" ]]; then
  filebrowser config init -d "$FB_DIR/fb.db"
  filebrowser config set -d "$FB_DIR/fb.db" --address 127.0.0.1 --port 8080 --root "$FILES_DIR"
  filebrowser users add admin "$ADMIN_PASS" --perm.admin -d "$FB_DIR/fb.db"
else
  echo "    fb.db 已存在，跳过初始化（如需重置删除 $FB_DIR/fb.db 重跑）"
fi

echo ">>> [4/5] 配置 systemd 常驻..."
cat > /etc/systemd/system/filebrowser.service <<EOF
[Unit]
Description=File Browser
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$(command -v filebrowser) -d $FB_DIR/fb.db
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now filebrowser

echo ">>> [5/5] 配置 nginx + HTTPS..."
cat > /etc/nginx/conf.d/files.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    # 用户公开下载：https://$DOMAIN/d/文件名 —— 无需登录，nginx 直接发
    location /d/ {
        alias $FILES_DIR/;
        autoindex on;
        add_header Content-Disposition "attachment";
    }

    # 你的管理后台（Filebrowser，要登录）
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        client_max_body_size 0;
    }
}
EOF
nginx -t
systemctl enable nginx
systemctl restart nginx

# 自动申请并配置 HTTPS（DNS 没解析好这步会失败，不影响 HTTP 已可用）
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect || \
  echo "!! HTTPS 自动配置失败：检查域名是否已解析到本机、80 端口是否放行，再手动跑：certbot --nginx -d $DOMAIN"

echo
echo "============================================"
echo "完成！"
echo "  管理后台： https://$DOMAIN        （admin / 你设的密码，进去改密码 + 传文件）"
echo "  公开下载： https://$DOMAIN/d/文件名"
echo "  文件目录： $FILES_DIR"
echo "============================================"
