#!/bin/bash
# Author: tqlloki - 123HOST

# Function to check OS
check_os() {
  OS=$(grep "^ID=" /etc/os-release | cut -d '=' -f 2 | tr -d '"')
  case "$OS" in
    ubuntu|almalinux)
      echo "Hệ điều hành được hỗ trợ: $OS"
      ;;
    *)
      echo "Hệ điều hành không được hỗ trợ. Vui lòng sử dụng Ubuntu hoặc AlmaLinux."
      exit 1
      ;;
  esac
}

# Function to get public IP
get_public_ip() {
  IP=$(curl -s ifconfig.me)
  echo "IPv4 Public của VPS/Server là: $IP"
}

# Function to check domain DNS
check_domain_dns() {
  while true; do
    echo "Kiểm tra xem tên miền $DOMAIN đã trỏ về IPv4 $IP chưa..."
    DOMAIN_IP=$(curl -s "https://cloudflare-dns.com/dns-query?name=$DOMAIN&type=A" -H "accept: application/dns-json" | sed -n 's/.*"data":"\([^"]*\)".*/\1/p')
    if [[ "$DOMAIN_IP" == "$IP" ]]; then
      echo "Tên miền $DOMAIN đã trỏ về IPv4 $IP. Tiếp tục..."
      break
    else
      echo "Tên miền $DOMAIN hiện chưa trỏ về IPv4 $IP."
      echo "Vui lòng cấu hình DNS trỏ tên miền về IPv4 $IP."
      echo "Chờ 5 phút để kiểm tra lại..."
      sleep 300
    fi
  done
}

# Function to install PostgreSQL
install_postgresql() {
  if command -v psql > /dev/null; then
    echo "PostgreSQL đã được cài đặt."
    return
  fi

  case "$OS" in
    ubuntu)
      sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
      sed -i -e 's/archive.ubuntu.com/mirror.viettelcloud.vn/g' /etc/apt/sources.list
      sudo DEBIAN_FRONTEND=noninteractive apt update
      sudo DEBIAN_FRONTEND=noninteractive apt -y install vim curl wget gpg gnupg2 software-properties-common apt-transport-https lsb-release ca-certificates
      curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
      sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
      sudo DEBIAN_FRONTEND=noninteractive apt update
      sudo DEBIAN_FRONTEND=noninteractive apt install postgresql-16 -y
      sudo -u postgres psql -c "SELECT version();"
      ;;
    almalinux)
      sudo curl -o /etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux
      sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm
      sudo dnf -qy module disable postgresql
      sudo dnf install -y postgresql16-server postgresql16-contrib
      sudo /usr/pgsql-16/bin/postgresql-16-setup initdb
      sudo systemctl start postgresql-16
      sudo systemctl enable postgresql-16
      ;;
  esac
}

# Function to configure PostgreSQL
configure_postgresql() {
  sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"
  sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"

  case "$OS" in
    ubuntu)
      sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/g" /etc/postgresql/16/main/postgresql.conf
      echo "host    all             all             172.16.0.0/12            md5" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf
      sudo systemctl reload postgresql
      ;;
    almalinux)
      sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/g" /var/lib/pgsql/16/data/postgresql.conf
      echo "host    all             all             172.16.0.0/12            md5" | sudo tee -a /var/lib/pgsql/16/data/pg_hba.conf
      sudo systemctl reload postgresql-16
      ;;
  esac
}

# Function to install Docker
install_docker() {
  if command -v docker > /dev/null; then
    echo "Docker đã được cài đặt."
    return
  fi

  case "$OS" in
    ubuntu)
      sudo DEBIAN_FRONTEND=noninteractive apt update
      sudo DEBIAN_FRONTEND=noninteractive apt-get install ca-certificates curl -y
      sudo install -m 0755 -d /etc/apt/keyrings
      sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      sudo chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
      sudo DEBIAN_FRONTEND=noninteractive apt update
      sudo DEBIAN_FRONTEND=noninteractive apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
      ;;
    almalinux)
      sudo yum install -y yum-utils device-mapper-persistent-data lvm2
      sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
      sudo systemctl start docker
      sudo systemctl enable docker
      ;;
  esac
  sudo systemctl enable docker
  sudo systemctl start docker
}

# Function to create .env and docker-compose.yml
create_env_and_docker_compose() {
  INSTALL_DIR="/root/$DOMAIN"
  mkdir -p "$INSTALL_DIR/n8n_storage"
  chmod 777 "$INSTALL_DIR/n8n_storage"
  cd "$INSTALL_DIR"

  N8N_BASIC_AUTH_USER="admin_$(openssl rand -hex 3)"
  N8N_BASIC_AUTH_PASSWORD=$(openssl rand -base64 12)
  N8N_ENCRYPTION_KEY=$(openssl rand -base64 32)

  if [ "$USE_DOCKER_POSTGRES" = true ]; then
    mkdir -p "$INSTALL_DIR/postgres_data"

    PG_USER="admin_$(openssl rand -hex 4)"
    PG_PASSSWORD=$(openssl rand -base64 12)


    cat <<EOF >init-data.sh
#!/bin/bash
set -e;


if [ -n "\${POSTGRES_NON_ROOT_USER:-}" ] && [ -n "\${POSTGRES_NON_ROOT_PASSWORD:-}" ]; then
	psql -v ON_ERROR_STOP=1 --username "\$POSTGRES_USER" --dbname "\$POSTGRES_DB" <<-EOSQL
		CREATE USER \${POSTGRES_NON_ROOT_USER} WITH PASSWORD '\${POSTGRES_NON_ROOT_PASSWORD}';
		GRANT ALL PRIVILEGES ON DATABASE \${POSTGRES_DB} TO \${POSTGRES_NON_ROOT_USER};
		GRANT CREATE ON SCHEMA public TO \${POSTGRES_NON_ROOT_USER};
	EOSQL
else
	echo "SETUP INFO: No Environment variables given!"
fi
EOF
    chmod +x init-data.sh

    cat <<EOF >.env
POSTGRES_NON_ROOT_USER=$DB_USER
POSTGRES_NON_ROOT_PASSWORD=$DB_PASSWORD
POSTGRES_DB=$DB_NAME

POSTGRES_USER=$PG_USER
POSTGRES_PASSWORD=$PG_PASSSWORD

DOMAIN_NAME=$DOMAIN

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
  postgres:
    image: postgres:16
    restart: always
    environment:
      - POSTGRES_USER
      - POSTGRES_PASSWORD
      - POSTGRES_DB
      - POSTGRES_NON_ROOT_USER
      - POSTGRES_NON_ROOT_PASSWORD
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
      - ./init-data.sh:/docker-entrypoint-initdb.d/init-data.sh
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -h localhost -U ${POSTGRES_USER} -d ${POSTGRES_DB}']
      interval: 10s
      timeout: 5s
      retries: 20

  n8n:
    image: docker.n8n.io/n8nio/n8n
    restart: always
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB}
      - DB_POSTGRESDB_USER=\${POSTGRES_NON_ROOT_USER}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_NON_ROOT_PASSWORD}
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=\${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=\${N8N_BASIC_AUTH_PASSWORD}
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
      - ./n8n_storage:/home/node/.n8n
EOF
  else

    cat <<EOF >.env
POSTGRES_NON_ROOT_USER=$DB_USER
POSTGRES_NON_ROOT_PASSWORD=$DB_PASSWORD
POSTGRES_DB=$DB_NAME

DOMAIN_NAME=$DOMAIN

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
      - DB_POSTGRESDB_USER=\${POSTGRES_NON_ROOT_USER}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_NON_ROOT_PASSWORD}
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=\${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=\${N8N_BASIC_AUTH_PASSWORD}
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
      - ./n8n_storage:/home/node/.n8n
EOF
  fi

  docker compose up -d

  if [ "$(docker ps | grep n8n)" ]; then
    echo "N8N đã được khởi động thành công!"
  else
    echo "Có lỗi khi khởi động N8N. Vui lòng kiểm tra lại."
    exit 1
  fi
}

# Function to install nginx and certbot
install_nginx_and_certbot() {
  if command -v nginx > /dev/null; then
    echo "Nginx đã được cài đặt."
    if ! command -v certbot > /dev/null; then
      echo "Cài đặt Certbot..."
      case "$OS" in
        ubuntu)
          sudo DEBIAN_FRONTEND=noninteractive apt install -y certbot python3-certbot-nginx
          ;;
        almalinux)
          sudo dnf install -y epel-release
          sudo dnf install -y certbot python3-certbot-nginx
          ;;
      esac
    fi
  else
    echo "Cài đặt Nginx và Certbot..."
    case "$OS" in
      ubuntu)
        sudo DEBIAN_FRONTEND=noninteractive apt install -y nginx certbot python3-certbot-nginx cron
        ;;
      almalinux)
        sudo dnf install -y epel-release
        sudo dnf install -y nginx certbot python3-certbot-nginx
        ;;
    esac
  fi

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

  sudo systemctl restart nginx
  sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email $EMAIL

  (crontab -l 2>/dev/null; echo "0 0 * * * certbot renew --quiet && systemctl reload nginx") | crontab -
}

# Main script execution
check_os
get_public_ip

read -p "Nhập tên miền để chạy n8n, đảm bảo đã trỏ tên miền về IP VPS/Server là $IP: " DOMAIN
check_domain_dns

read -p "Nhập email dùng cho cài SSL free: " EMAIL

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

# Hỏi người dùng về cách cài đặt PostgreSQL
echo "Bạn có muốn cài đặt PostgreSQL trong Docker Compose cùng với n8n không? hay thích cài Docker Compose n8n thôi, còn postgresql cài riêng trên VPS/Server? (y/n)"
read -p "Chọn? (y/n): " USE_DOCKER_POSTGRES
if [[ "$USE_DOCKER_POSTGRES" == "y" || "$USE_DOCKER_POSTGRES" == "Y" ]]; then
  USE_DOCKER_POSTGRES=true
else
  USE_DOCKER_POSTGRES=false
fi

DB_USER="user_$(openssl rand -hex 4)"
DB_PASSWORD=$(openssl rand -base64 12)
DB_NAME="db_$(openssl rand -hex 4)"

if [ "$USE_DOCKER_POSTGRES" = true ]; then
  echo "PostgreSQL sẽ được cài đặt trong Docker Compose cùng với n8n."
else
  echo "PostgreSQL sẽ được cài đặt riêng trên VPS/Server."
  install_postgresql
  configure_postgresql
fi

install_docker
create_env_and_docker_compose
install_nginx_and_certbot

echo "Hoàn tất cài đặt n8n với tên miền $DOMAIN. SSL đã được thiết lập và cronjob gia hạn tự động đã được thêm."
echo "Source n8n được đặt trong $INSTALL_DIR. Với n8n chạy docker-compose, còn postgresql được cài đặt riêng trên VPS/Server"
echo "Hiện tại bạn đã có thể truy cập n8n với link: https://$DOMAIN để thiết lập tài khoản và sử dụng n8n."
