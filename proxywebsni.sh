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
    if [ "$OS" = "ubuntu" ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt update
        sudo apt install -y docker-ce docker-ce-cli containerd.io
    elif [ "$OS" = "debian" ]; then
        curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
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

# 确保安装 certbot 和 dns-cloudflare 插件
if ! [ -x "$(command -v certbot)" ]; then
    echo "Certbot 未安装，正在安装 Certbot..."
    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        sudo apt install -y certbot python3-certbot-dns-cloudflare
    elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ]; then
        sudo yum install -y certbot python3-certbot-dns-cloudflare
    elif [ "$OS" = "fedora" ]; then
        sudo dnf install -y certbot python3-certbot-dns-cloudflare
    else
        echo "不支持的操作系统，请手动安装 Certbot 和 dns-cloudflare 插件。"
        exit 1
    fi
else
    echo "Certbot 已安装，跳过安装步骤。"
fi

# 获取用户输入
read -p "请输入服务器解析的域名 (例如 example.com): " DOMAIN
read -p "请输入博客所使用的端口 (80 或 443): " PORT
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

volumes:
  db_data:
  wordpress_data:
EOL

# 创建 nginx.conf 文件，添加 SNI 分流规则
cat <<EOL > nginx/nginx.conf
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        root /wenruo/wordpress;
        index index.php index.html index.htm;
        try_files \$uri \$uri/ /index.php?\$args;
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

    # SNI 分流: 当 SNI 与域名相同时转发到代理服务
    location / {
        if (\$ssl_server_name = "$DOMAIN") {
            # 转发到 VLESS 代理服务
            proxy_pass http://127.0.0.1:3771;  # 将 VLESS 代理请求转发到 V2Ray/Xray 监听的端口
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            break;  # 跳出当前 location
        }

        # 默认返回博客页面
        root /wenruo/wordpress;
        index index.php index.html index.htm;
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass wordpress:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOL


# 安装 acme.sh
if ! [ -x "$(command -v acme.sh)" ]; then
    echo "acme.sh 未安装，正在安装..."
    curl https://get.acme.sh | sh
    source ~/.bashrc
else
    echo "acme.sh 已安装，跳过安装步骤。"
fi

# 设置 Cloudflare 凭据
cat <<EOL > ~/.acme.sh/cloudflare.ini
dns_cloudflare_email = "$CLOUDFLARE_EMAIL"
dns_cloudflare_api_key = "$CLOUDFLARE_API_KEY"
EOL

chmod 600 ~/.acme.sh/cloudflare.ini

# 申请 SSL 证书
echo "申请 SSL 证书..."
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256 --agree-tos --email "$CLOUDFLARE_EMAIL"

# 安装证书
echo "安装 SSL 证书..."
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/letsencrypt/live/$DOMAIN/privkey.pem \
    --fullchain-file /etc/letsencrypt/live/$DOMAIN/fullchain.pem

# 启动 Docker Compose 服务
echo "启动 Docker Compose 服务..."
docker-compose up -d

# 输出证书路径和代理路径以便在 x-ui 面板中使用
CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
PROXY_URL="https://$DOMAIN$PROXY_PATH"

echo "SSL证书已申请成功并配置！"
echo "证书路径: $CERT_PATH"
echo "私钥路径: $KEY_PATH"
echo "请将上述路径填写到 x-ui 面板中的证书和私钥字段。"
echo "伪装站点博客访问地址: https://$DOMAIN"

# 添加 acme.sh 自动续期
echo "正在设置 acme.sh 自动续期..."
(crontab -l 2>/dev/null; echo "0 0 * * * /root/.acme.sh/acme.sh --renew -d $DOMAIN --key-file /etc/letsencrypt/live/$DOMAIN/privkey.pem --fullchain-file /etc/letsencrypt/live/$DOMAIN/fullchain.pem > /var/log/acme_renew.log 2>&1") | crontab -

echo "acme.sh 自动续期已设置成功！"
