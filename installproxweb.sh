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

# 更新包管理器并安装必要的工具（curl 和其他工具）
echo "检测到系统类型为 $OS，正在安装必要的工具..."

if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    sudo apt update
    sudo apt install -y curl apt-transport-https ca-certificates gnupg lsb-release
elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ]; then
    sudo yum install -y curl yum-utils
elif [ "$OS" = "fedora" ]; then
    sudo dnf install -y curl
else
    echo "不支持的操作系统，请手动安装 Docker 和 Docker Compose。"
    exit 1
fi

# 检查并安装 Docker
if ! [ -x "$(command -v docker)" ]; then
    echo "Docker 未安装，正在安装 Docker..."
    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt update
        sudo apt install -y docker-ce docker-ce-cli containerd.io
    elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ]; then
        sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo yum install -y docker-ce docker-ce-cli containerd.io
    elif [ "$OS" = "fedora" ]; then
        sudo dnf install -y dnf-plugins-core
        sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
        sudo dnf install -y docker-ce docker-ce-cli containerd.io
    fi
    sudo systemctl start docker
    sudo systemctl enable docker
else
    echo "Docker 已安装，跳过安装步骤。"
fi

# 检查并安装 Docker Compose
if ! [ -x "$(command -v docker-compose)" ]; then
    echo "Docker Compose 未安装，正在安装 Docker Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
else
    echo "Docker Compose 已安装，跳过安装步骤。"
fi

# 获取用户输入
read -p "请输入服务器解析的域名 (例如 example.com): " DOMAIN
read -p "请输入博客所使用的端口 (80 或 443): " PORT
read -p "请输入代理路径 (例如 /vless): " PROXY_PATH
read -p "请输入Cloudflare的注册邮箱: " CLOUDFLARE_EMAIL
read -p "请输入Cloudflare的Global API Key: " CLOUDFLARE_API_KEY

# 创建项目文件夹
mkdir -p wenruo/docker-wordpress/{nginx,certbot}
cd wenruo/docker-wordpress

# 创建 docker-compose.yml 文件，添加路径分流
cat <<EOL > docker-compose.yml
version: '3'

services:
  db:
    image: mysql:5.7
    volumes:
      - db_data:/wenruo/mysql
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: root_password
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wordpressuser
      MYSQL_PASSWORD: wordpresspass

  wordpress:
    depends_on:
      - db
    image: wordpress:latest
    volumes:
      - wordpress_data:/wenruo/wordpress
    restart: always
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_USER: wordpressuser
      WORDPRESS_DB_PASSWORD: wordpresspass
      WORDPRESS_DB_NAME: wordpress
    ports:
      - "$PORT:80"

  nginx:
    image: nginx:latest
    depends_on:
      - wordpress
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf
      - ./certs:/etc/letsencrypt/live/$DOMAIN
      - wordpress_data:/wenruo/wordpress
    ports:
      - "8082:80"
      - "8443:443"
    restart: always

  certbot:
    image: certbot/certbot:latest
    volumes:
      - ./certs:/etc/letsencrypt
      - ./certbot/conf:/etc/letsencrypt/conf
      - ./certbot/www:/var/www/certbot
    entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h; done;'"

volumes:
  db_data:
  wordpress_data:
EOL

# 创建 nginx.conf 文件，添加路径分流规则
cat <<EOL > nginx/nginx.conf
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        root /wenruo/wordpress;
        index index.php index.html index.htm;
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location $PROXY_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:3771; # 将 vless 代理请求转发到 V2Ray/Xray 监听的端口
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass wordpress:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        root /wenruo/wordpress;
        index index.php index.html index.htm;
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location $PROXY_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:3771;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass wordpress:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOL

# 创建 Cloudflare 凭据文件
cat <<EOL > certbot/cloudflare.ini
dns_cloudflare_email = "$CLOUDFLARE_EMAIL"
dns_cloudflare_api_key = "$CLOUDFLARE_API_KEY"
EOL

# 设置凭据文件权限
chmod 600 certbot/cloudflare.ini

# 启动 Docker Compose 并运行
docker-compose up -d

# 申请 SSL 证书
docker-compose run --rm certbot certonly --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/conf/cloudflare.ini -d $DOMAIN

# 重启 Nginx 以启用 SSL
docker-compose restart nginx

# 输出证书路径和代理路径以便在 x-ui 面板中使用
CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
PROXY_URL="https://$DOMAIN$PROXY_PATH"

echo "SSL证书已申请成功并配置！"
echo "证书路径: $CERT_PATH"
echo "私钥路径: $KEY_PATH"
echo "请将上述路径填写到 x-ui 面板中的证书和私钥字段。"
echo "伪装站点博客访问地址: https://$DOMAIN"
echo "代理流量路径为: $PROXY_URL"
