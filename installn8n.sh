#!/bin/bash
# Author: tqlloki - 123HOST

# Kiểm tra hệ điều hành
OS=$(cat /etc/os-release | grep "^ID=" | cut -d '=' -f 2 | tr -d '"')
if [[ "$OS" != "ubuntu" && "$OS" != "almalinux" ]]; then
  echo "Hệ điều hành không được hỗ trợ. Vui lòng sử dụng Ubuntu hoặc AlmaLinux."
  exit 1
fi

# Lấy địa chỉ IPv4 public của VPS.
IP=$(curl -s ifconfig.me)
echo "IPv4 Public của VPS/Server là: $IP"

# Nhập tên miền
read -p "Nhập tên miền để chạy n8n, đảm bảo đã trỏ tên miền về IP VPS/Server là $IP: " DOMAIN

while true; do
    echo "Kiểm tra xem tên miền $DOMAIN đã trỏ về IPv4 $IP chưa..."

    # Kiểm tra IP từ DNS của tên miền
    DOMAIN_IP=$(curl "https://cloudflare-dns.com/dns-query?name=$DOMAIN&type=A" -H "accept: application/dns-json" | sed -n 's/.*"data":"\([^"]*\)".*/\1/p')

    # So sánh IP của tên miền với IP public
    if [[ "$DOMAIN_IP" == "$IP" ]]; then
        echo "Tên miền $DOMAIN đã trỏ về IPv4 $IP. Tiếp tục..."
        break
    else
        echo "Tên miền $DOMAIN hiện chưa trỏ về IPv4 $IP."
        echo "Vui lòng cấu hình DNS trỏ tên miền về IPv4 $IP."
        echo "Chờ 5 phút để kiểm tra lại..."
        sleep 300 # Chờ 5 phút
    fi
done

read -p "Nhập email dùng cho cài SSL free: " EMAIL

# Hỏi người dùng có muốn sử dụng SMTP không
echo "Bạn có muốn sử dụng SMTP để gửi email khi dùng n8n không? (y/n)"
echo "Nếu hiện tại chưa có nhu cầu hoặc chưa có SMTP thì chọn n để bỏ qua, sau này cập nhật sau."
echo "Nếu có thì chọn y và nhập đầy đủ các thông tin cần cho SMTP, gồm: "
echo "SMTP Host: ví dụ smtp.gmail.com"
echo "SMTP User: ví dụ abc@gmail.com"
echo "SMTP Password: với gmail thì dùng mật khẩu ứng dụng, còn các dịch vụ email khác thì dùng password bình thường"
echo "SMTP Sender Email: địa chỉ email gửi đi mà bạn muốn bên nhận email thấy, ví dụ admin@$DOMAIN"
read -p "Chọn? (y/n): " USE_SMTP
if [[ "$USE_SMTP" == "y" || "$USE_SMTP" == "Y" ]]; then
  read -p "SMTP Host: " SMTP_HOST
  read -p "SMTP User: " SMTP_USER
  read -sp "SMTP Password: " SMTP_PASS
  read -p "SMTP Sender Email: " SMTP_SENDER
else
  SMTP_HOST=""
  SMTP_USER=""
  SMTP_PASS=""
  SMTP_SENDER=""
  SMTP_PORT=""
  SMTP_SSL="false"
fi

# Cài đặt PostgreSQL 16
if [[ "$OS" == "ubuntu" ]]; then
	sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
	sed -i -e 's/archive.ubuntu.com/mirror.viettelcloud.vn/g' /etc/apt/sources.list
       #sudo DEBIAN_FRONTEND=noninteractive apt update && DEBIAN_FRONTEND=noninteractive apt -o Dpkg::Options::="--force-confold" -y full-upgrade
       sudo DEBIAN_FRONTEND=noninteractive apt -y install vim curl wget gpg gnupg2 software-properties-common apt-transport-https lsb-release ca-certificates
       apt policy postgresql
       curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc|sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
       sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
       sudo DEBIAN_FRONTEND=noninteractive apt update
       sudo DEBIAN_FRONTEND=noninteractive apt install postgresql-16 -y
       sudo -u postgres psql -c "SELECT version();"
elif [[ "$OS" == "almalinux" ]]; then
		sudo curl -o /etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux
		sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm
        sudo dnf -qy module disable postgresql
        sudo dnf install -y postgresql16-server postgresql16-contrib
        sudo /usr/pgsql-16/bin/postgresql-16-setup initdb
        sudo systemctl start postgresql-16
        sudo systemctl enable postgresql-16
fi

# Tạo database, user và mật khẩu
DB_USER="user_$(openssl rand -hex 4)"
DB_PASSWORD=$(openssl rand -base64 12)
DB_NAME="db_$(openssl rand -hex 4)"
sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"

if [[ "$OS" == "ubuntu" ]]; then
        sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/g" /etc/postgresql/16/main/postgresql.conf
        echo "host    all             all             172.18.0.0/16            md5" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf
        sudo systemctl restart postgresql
elif [[ "$OS" == "almalinux" ]]; then
        sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/g" /var/lib/pgsql/16/data/postgresql.conf
        echo "host    all             all             172.18.0.0/16            md5" | sudo tee -a /var/lib/pgsql/16/data/pg_hba.conf
        sudo systemctl restart postgresql-16
fi
# Cài đặt Docker và Docker Compose
if [[ "$OS" == "ubuntu" ]]; then
        sudo DEBIAN_FRONTEND=noninteractive apt update
        sudo DEBIAN_FRONTEND=noninteractive apt-get install ca-certificates curl -y
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
                $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
                sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo DEBIAN_FRONTEND=noninteractive apt update
        sudo DEBIAN_FRONTEND=noninteractive apt  install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
elif [[ "$OS" == "almalinux" ]]; then
        yum install -y yum-utils device-mapper-persistent-data lvm2
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        systemctl start docker
        systemctl enable docker
fi
sudo systemctl enable docker
sudo systemctl start docker

# Tạo thư mục và file .env
INSTALL_DIR="/root/$DOMAIN"
mkdir -p "$INSTALL_DIR/.n8n_storage"
chmod 777 "$INSTALL_DIR/.n8n_storage"
cd "$INSTALL_DIR"

N8N_BASIC_AUTH_USER="admin_$(openssl rand -hex 3)"
N8N_BASIC_AUTH_PASSWORD=$(openssl rand -base64 12)
N8N_ENCRYPTION_KEY=$(openssl rand -base64 32)

cat <<EOF >.env
POSTGRES_USER=$DB_USER
POSTGRES_PASSWORD=$DB_PASSWORD
POSTGRES_DB=$DB_NAME

# The top level domain to serve from
DOMAIN_NAME=$DOMAIN

# SMTP
SMTP_HOST=$SMTP_HOST
SMTP_PORT=587
SMTP_USER=$SMTP_USER
SMTP_PASS=$SMTP_PASS
SMTP_SENDER=$SMTP_SENDER
SMTP_SSL=false

N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD
GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
N8N_ENCRYPTION_KEY="$N8N_ENCRYPTION_KEY"
EOF

cat <<EOF >docker-compose.yml
version: '3.8'

services:
  n8n:
    image: docker.n8n.io/n8nio/n8n
    restart: always
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=$IP
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB}
      - DB_POSTGRESDB_USER=\${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER
      - N8N_BASIC_AUTH_PASSWORD
      - N8N_HOST=\${DOMAIN_NAME}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://\${DOMAIN_NAME}/
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_RUNNERS_ENABLED=true
      - N8N_EMAIL_MODE=smtp
      - N8N_SMTP_HOST=\${SMTP_HOST}
      - N8N_SMTP_PORT=\${SMTP_PORT}
      - N8N_SMTP_USER=\${SMTP_USER}
      - N8N_SMTP_PASS=\${SMTP_PASS}
      - N8N_SMTP_SENDER=\${SMTP_SENDER}
      - N8N_SMTP_SSL=\${SMTP_SSL}
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - EXECUTIONS_DATA_SAVE_ON_ERROR=all
      - EXECUTIONS_DATA_SAVE_ON_SUCCESS=all
      - EXECUTIONS_DATA_SAVE_ON_PROGRESS=true
      - EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS=true
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=168
      - EXECUTIONS_DATA_PRUNE_MAX_COUNT=30000
      - N8N_RUNNERS_ENABLED=true
    ports:
      - 5678:5678
    volumes:
      - ./.n8n_storage:/home/node/.n8n
EOF

docker compose up -d

# Kiểm tra trạng thái
if [ "$(docker ps | grep n8n)" ]; then
  echo "N8N đã được khởi động thành công!"
else
  echo "Có lỗi khi khởi động N8N. Vui lòng kiểm tra lại."
  exit 1
fi

# Cài đặt nginx và certbot
if [[ "$OS" == "ubuntu" ]]; then
  sudo DEBIAN_FRONTEND=noninteractive apt install -y nginx certbot python3-certbot-nginx cron
elif [[ "$OS" == "almalinux" ]]; then
	dnf install -y epel-release
  sudo dnf install -y nginx certbot python3-certbot-nginx
fi

# Tạo nginx vhost
NGINX_CONF="/etc/nginx/conf.d/$DOMAIN.conf"
cat <<EOF >$NGINX_CONF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

upstream n8nsocket {
    server 127.0.0.1:5678;
}

server {
    server_name $DOMAIN;

    location / {
        proxy_pass http://n8nsocket;
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
    }

    listen 80;
}
EOF

# Khởi động lại nginx và yêu cầu SSL
sudo systemctl restart nginx
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email $EMAIL


# Tạo cronjob tự động gia hạn SSL
(crontab -l 2>/dev/null; echo "0 0 * * * certbot renew --quiet && systemctl reload nginx") | crontab -

echo "Hoàn tất cài đặt n8n với tên miền $DOMAIN. SSL đã được thiết lập và cronjob gia hạn tự động đã được thêm."
echo "Source n8n được đặt trong $INSTALL_DIR. Với n8n chạy docker-compose, còn postgresql được cài đặt riêng trên VPS/Server"
echo "Hiện tại bạn đã có thể truy cập n8n với link: https://$DOMAIN để thiết lập tài khoản và sử dụng n8n."
