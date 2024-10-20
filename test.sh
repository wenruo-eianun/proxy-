#!/bin/bash

# 设置错误处理：脚本遇到错误立即退出
set -e

# 检查系统发行版
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "无法确定系统类型，请手动安装 Docker 和 Docker Compose。"
    exit 1
fi

# 更新包管理器并安装必要的工具
echo "检测到系统类型为 $OS，正在安装必要的工具..."

if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    sudo apt update
    sudo apt install -y curl apt-transport-https ca-certificates gnupg lsb-release certbot python3-certbot-dns-cloudflare
elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ]; then
    sudo yum install -y curl yum-utils certbot python3-certbot-dns-cloudflare
elif [ "$OS" = "fedora" ]; then
    sudo dnf install -y curl certbot python3-certbot-dns-cloudflare
else
    echo "不支持的操作系统，请手动安装 Docker、Docker Compose 和 Certbot。"
    exit 1
fi

# 检查并安装 Docker
if ! [ -x "$(command -v docker)" ]; then
    echo "Docker 未安装，正在安装 Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo systemctl start docker
    sudo systemctl enable docker
else
    echo "Docker 已安装，跳过安装步骤。"
fi

# 检查并安装 Docker Compose
if ! [ -x "$(command -v docker-compose)" ]; then
    echo "Docker Compose 未安装，正在安装 Docker Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
else
    echo "Docker Compose 已安装，跳过安装步骤。"
fi

# 获取用户输入
read -p "请输入服务器解析的域名 (例如 example.com): " DOMAIN
read -p "请输入Docker Nginx HTTP端口 (例如 8080): " HTTP_PORT
read -p "请输入Docker Nginx HTTPS端口 (例如 8443): " HTTPS_PORT
read -p "请输入代理路径 (例如 /vless): " PROXY_PATH
read -p "请输入代理服务器的IP地址: " PROXY_IP
read -p "请输入代理服务器的端口: " PROXY_PORT
read -p "请输入Cloudflare的注册邮箱: " CLOUDFLARE_EMAIL
read -p "请输入Cloudflare的Global API Key: " CLOUDFLARE_API_KEY

# 获取服务器IP地址
SERVER_IP=$(curl -s ifconfig.me)

# 创建项目文件夹
mkdir -p wenruo/docker-wordpress/{nginx,wordpress,certbot}
cd wenruo/docker-wordpress

# 创建 docker-compose.yml 文件
cat <<EOL > docker-compose.yml
version: '3'

services:
  db:
    image: mysql:5.7
    volumes:
      - db_data:/var/lib/mysql
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: somewordpress
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wordpress
      MYSQL_PASSWORD: wordpress

  wordpress:
    depends_on:
      - db
    image: wordpress:latest
    volumes:
      - wordpress_data:/var/www/html
    restart: always
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_USER: wordpress
      WORDPRESS_DB_PASSWORD: wordpress
      WORDPRESS_DB_NAME: wordpress

  nginx:
    image: nginx:latest
    ports:
      - "${HTTP_PORT}:80"
      - "${HTTPS_PORT}:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot
      - wordpress_data:/var/www/html
    depends_on:
      - wordpress
    restart: always

  certbot:
    image: certbot/certbot
    volumes:
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot
    entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h & wait \$\${!}; done;'"

volumes:
  db_data:
  wordpress_data:
EOL

# 创建 nginx.conf 文件
cat <<EOL > nginx/nginx.conf
user  nginx;
worker_processes  auto;

error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    #tcp_nopush     on;

    keepalive_timeout  65;

    #gzip  on;

    server {
        listen 80;
        server_name $DOMAIN;
        
        location /.well-known/acme-challenge/ {
            root /var/www/certbot;
        }

        location / {
            return 301 https://\$host\$request_uri;
        }
    }

    server {
        listen 443 ssl;
        server_name $DOMAIN;

        ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

        root /var/www/html;
        index index.php;

        location / {
            try_files \$uri \$uri/ /index.php?\$args;
        }

        location ~ \.php$ {
            fastcgi_pass wordpress:9000;
            fastcgi_index index.php;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            fastcgi_param PATH_INFO \$fastcgi_path_info;
        }

        location $PROXY_PATH {
            proxy_pass http://${PROXY_IP}:${PROXY_PORT};
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
}
EOL

# 创建 Cloudflare API 凭据文件
mkdir -p ~/.secrets/certbot
cat <<EOL > ~/.secrets/certbot/cloudflare.ini
dns_cloudflare_email = "$CLOUDFLARE_EMAIL"
dns_cloudflare_api_key = "$CLOUDFLARE_API_KEY"
EOL

chmod 600 ~/.secrets/certbot/cloudflare.ini

# 申请 SSL 证书（使用 DNS-01 验证）
echo "申请 SSL 证书..."
sudo certbot certonly --dns-cloudflare --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini --email "$CLOUDFLARE_EMAIL" --agree-tos --no-eff-email --preferred-challenges dns -d "$DOMAIN"

# 复制证书到 certbot 目录
sudo mkdir -p ./certbot/conf/live/$DOMAIN
sudo cp /etc/letsencrypt/live/$DOMAIN/* ./certbot/conf/live/$DOMAIN/

# 设置自动续期
echo "正在设置 Certbot 自动续期..."
(crontab -l 2>/dev/null; echo "0 0 1 * * docker-compose run certbot renew --quiet --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini && docker-compose exec nginx nginx -s reload") | crontab -

# 启动 Docker Compose
sudo docker-compose up -d

echo "伪装网站已成功搭建！"
echo "请确保您的域名 $DOMAIN 已正确解析到服务器IP。"
echo "WordPress网站地址: https://$DOMAIN:$HTTPS_PORT"
echo "伪装的代理路径: https://$DOMAIN:$HTTPS_PORT$PROXY_PATH"
echo "服务器IP地址: $SERVER_IP"
echo "HTTP端口: $HTTP_PORT"
echo "HTTPS端口: $HTTPS_PORT"
