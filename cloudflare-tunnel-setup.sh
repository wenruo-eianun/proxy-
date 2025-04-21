#!/bin/bash

set -e

echo "🌀 Cloudflare Tunnel 一键部署工具"
echo "-------------------------------"

# 1. 获取输入参数
read -p "请输入 Tunnel 名称（例如：pve-tunnel）: " TUNNEL_NAME
read -p "请输入要映射的子域名（例如：pve.example.com）: " HOSTNAME
read -p "请输入本地服务端口（默认8006）: " PORT
PORT=${PORT:-8006}

echo "✅ 你输入的信息："
echo "  Tunnel 名称：$TUNNEL_NAME"
echo "  公网访问域名：$HOSTNAME"
echo "  本地服务端口：$PORT"

# 2. 安装 cloudflared（如未安装）
if ! command -v cloudflared &> /dev/null; then
  echo "📦 安装 cloudflared..."
  wget -O cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  dpkg -i cloudflared.deb || apt-get -f install -y
else
  echo "✅ cloudflared 已安装"
fi

# 3. 登录 Cloudflare 账号
echo "🌐 打开浏览器登录 Cloudflare（按提示操作）"
cloudflared tunnel login

# 4. 创建 Tunnel
cloudflared tunnel create "$TUNNEL_NAME"

# 5. 创建配置文件
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml <<EOF
tunnel: $TUNNEL_NAME
credentials-file: /root/.cloudflared/${TUNNEL_NAME}.json

ingress:
  - hostname: $HOSTNAME
    service: https://localhost:$PORT
  - service: http_status:404
EOF

# 6. 配置 DNS 记录
cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME"

# 7. 设置 systemd 服务自启
echo "🚀 设置 tunnel 为 systemd 服务"
cloudflared service install
systemctl enable cloudflared
systemctl restart cloudflared

echo "🎉 Cloudflare Tunnel 已部署成功！"
echo "现在你可以通过以下地址访问你的服务："
echo "👉 https://$HOSTNAME"
