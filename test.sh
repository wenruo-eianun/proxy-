#!/bin/bash
set -e

# 检测系统并安装必要的软件
if [ -f /etc/debian_version ]; then
    apt update
    apt install -y curl wget sudo socat
elif [ -f /etc/redhat-release ]; then
    yum update -y
    yum install -y curl wget sudo socat
else
    echo "不支持的操作系统"
    exit 1
fi

# 安装 Docker
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi

# 安装 Docker Compose
if ! command -v docker-compose &> /dev/null; then
    curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# 安装 snapd（如果尚未安装）
if ! command -v snap &> /dev/null; then
    if [ -f /etc/debian_version ]; then
        apt update
        apt install -y snapd
    elif [ -f /etc/redhat-release ]; then
        yum install -y epel-release
        yum install -y snapd
        systemctl enable --now snapd.socket
    fi
fi

# 安装 Certbot 和 Cloudflare 插件
snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot
snap set certbot trust-plugin-with-root=ok
snap install certbot-dns-cloudflare

# 获取用户输入
read -p "请输入服务器解析的域名 (例如 example.com): " DOMAIN
read -p "请输入博客和代理服务使用的端口 (通常为 443): " PORT
read -p "请输入Cloudflare的注册邮箱: " CLOUDFLARE_EMAIL
read -p "请输入Cloudflare的Global API Key: " CLOUDFLARE_API_KEY

# 创建 Cloudflare 配置文件
mkdir -p ~/.secrets/certbot
cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_email = $CLOUDFLARE_EMAIL
dns_cloudflare_api_key = $CLOUDFLARE_API_KEY
EOL
chmod 600 ~/.secrets/certbot/cloudflare.ini

# 创建 Docker Compose 配置文件
mkdir -p wordpress
cat > wordpress/docker-compose.yml <<EOL
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

  nginx:
    image: nginx:latest
    ports:
      - "80:80"
      - "$PORT:$PORT"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf
      - ./error_pages:/etc/nginx/error_pages
      - /etc/letsencrypt:/etc/letsencrypt
      - wordpress_data:/wenruo/wordpress
    restart: always
    depends_on:
      - wordpress

volumes:
  db_data:
  wordpress_data:
EOL

# 创建自定义错误页面
mkdir -p wordpress/error_pages
cat > wordpress/error_pages/error.html <<EOL
<!DOCTYPE html>
<html>
<head>
    <title>资源暂时不可用</title>
</head>
<body>
    <h1>抱歉，请求的资源暂时不可用</h1>
    <p>请稍后再试。如果问题持续存在，请联系网站管理员。</p>
</body>
</html>
EOL

# 创建 Nginx 配置文件
cat > wordpress/nginx.conf <<EOL
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen $PORT ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    root /wenruo/wordpress;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        fastcgi_pass wordpress:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    # 代理服务配置
    location /resources {
        if (\$http_upgrade != "websocket") {
            return 301 /;
        }
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        error_page 502 = /error.html;
    }

    location = /error.html {
        root /etc/nginx/error_pages;
        internal;
    }
}
EOL

# 申请 SSL 证书
certbot certonly --dns-cloudflare --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini --email "$CLOUDFLARE_EMAIL" --agree-tos --no-eff-email --preferred-challenges dns -d "$DOMAIN"

# 启动 Docker Compose
cd wordpress
docker-compose up -d

# 设置 Certbot 自动续期
(crontab -l 2>/dev/null; echo "0 0 1 * * certbot renew --quiet --deploy-hook 'docker exec wordpress_nginx_1 nginx -s reload'") | crontab -

# 输出证书路径和代理信息
CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
PROXY_URL="https://$DOMAIN/resources"

echo "安装完成！"
echo "SSL证书路径: $CERT_PATH"
echo "SSL私钥路径: $KEY_PATH"
echo "请将上述路径填写到 x-ui 面板中的证书和私钥字段。"
echo "WordPress 博客访问地址: https://$DOMAIN"
echo "代理服务访问地址: $PROXY_URL"
echo "请确保您的代理服务正在监听 127.0.0.1:$PORT"
