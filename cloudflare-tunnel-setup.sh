#!/bin/bash

set -e

# 定义颜色常量
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_RED="\033[31m"
COLOR_RESET="\033[0m"

echo -e "${COLOR_GREEN}🌀 Cloudflare Tunnel 一键部署工具${COLOR_RESET}"
echo "-----------------------------------------------"

# 获取输入信息
read -p "请输入 Tunnel 名称（例如：pve-tunnel）： " TUNNEL_NAME
read -p "请输入要映射的主域名（例如：example.com）: " DOMAIN
read -p "请输入本地服务端口（例如 PVE 的默认端口：8006）: " PORT
PORT=${PORT:-8006}

echo -e "\n${COLOR_YELLOW}✅ 你输入的信息：${COLOR_RESET}"
echo "  Tunnel 名称：$TUNNEL_NAME"
echo "  映射域名：$DOMAIN"
echo "  本地服务端口：$PORT"
echo

# 安装 cloudflared：判断是否能访问 GitHub
echo -e "${COLOR_YELLOW}🌐 检查 cloudflared 安装环境...${COLOR_RESET}"

if ! command -v cloudflared &> /dev/null; then
    if wget --spider -q https://github.com; then
        echo -e "${COLOR_GREEN}✅ GitHub 可访问，使用官方 release 安装${COLOR_RESET}"
        wget -O cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
        dpkg -i cloudflared.deb || apt-get -f install -y
    else
        echo -e "${COLOR_RED}⚠️ GitHub 无法访问，改用 Cloudflare 官方 apt 镜像源安装${COLOR_RESET}"
        apt update && apt install -y curl gnupg lsb-release
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
            > /etc/apt/sources.list.d/cloudflared.list
        apt update && apt install -y cloudflared
    fi
else
    echo -e "${COLOR_GREEN}✅ cloudflared 已安装${COLOR_RESET}"
fi

# 授权登录
echo -e "\n${COLOR_YELLOW}🧩 正在生成 Cloudflare 授权链接，请复制下方网址到浏览器打开：${COLOR_RESET}"
cloudflared tunnel login
echo -e "\n⏳ 等你完成 Cloudflare 网页授权后再继续（确保看到登录成功提示）"
read -p "🔁 授权完成后按回车继续..."

# 创建 Tunnel
echo -e "\n🌐 创建 Tunnel：$TUNNEL_NAME"
cloudflared tunnel create "$TUNNEL_NAME"

# 创建配置文件
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml <<EOF
tunnel: $TUNNEL_NAME
credentials-file: /root/.cloudflared/${TUNNEL_NAME}.json

ingress:
  - hostname: $DOMAIN
    service: https://localhost:$PORT
  - service: http_status:404
EOF

# 配置 DNS 路由
echo -e "\n🧩 配置 Cloudflare DNS 路由..."
cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN"

# 设置为 systemd 服务
echo -e "\n🚀 设置 cloudflared 为开机自启服务..."
cloudflared service install
systemctl enable cloudflared
systemctl restart cloudflared

# 完成提示
echo -e "\n🎉 Cloudflare Tunnel 部署成功！"
echo -e "👉 现在你可以通过以下地址访问你的服务："
echo -e "   ${COLOR_GREEN}https://$DOMAIN${COLOR_RESET}"
echo -e "${COLOR_YELLOW}（如遇自签名证书提示，浏览器选择“继续前往”即可）${COLOR_RESET}"

# 添加后续操作选项
echo -e "\n${COLOR_YELLOW}🔧 后续操作：${COLOR_RESET}"
echo "1. 添加新服务映射"
echo "2. 查看和管理现有 Tunnel 配置"
echo "3. 退出"

read -p "请选择操作（输入数字）： " OPERATION

case $OPERATION in
    1)
        # 添加新服务映射
        read -p "请输入新的服务子域名（例如：new.example.com）： " NEW_HOSTNAME
        read -p "请输入新的本地服务端口（例如：8080）： " NEW_PORT
        NEW_PORT=${NEW_PORT:-8080}
        echo -e "\n${COLOR_YELLOW}正在添加新的服务映射...${COLOR_RESET}"

        # 更新配置文件
        echo "
  - hostname: $NEW_HOSTNAME
    service: https://localhost:$NEW_PORT
" >> /etc/cloudflared/config.yml

        # 重新加载配置
        systemctl restart cloudflared
        echo -e "${COLOR_GREEN}✅ 新服务映射已添加并启动！${COLOR_RESET}"
        ;;
    2)
        # 查看配置
        echo -e "\n${COLOR_YELLOW}当前 Tunnel 配置：${COLOR_RESET}"
        cat /etc/cloudflared/config.yml
        ;;
    3)
        echo -e "${COLOR_GREEN}👋 脚本退出！${COLOR_RESET}"
        exit 0
        ;;
    *)
        echo -e "${COLOR_RED}无效的操作选项，退出脚本...${COLOR_RESET}"
        exit 1
        ;;
esac
