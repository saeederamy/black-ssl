#!/bin/bash

# بررسی دسترسی Root
if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mPlease run this script as root.\e[0m"
  exit 1
fi

NGINX_PROXY_DIR="/etc/nginx/proxy.d"

# تابع نصب انجینکس و SSL
function install_nginx_ssl() {
    read -p "Enter Domain (e.g., example.com): " DOMAIN
    
    echo -e "\e[34mInstalling Nginx...\e[0m"
    apt update && apt install nginx curl ufw socat -y
    
    mkdir -p "$NGINX_PROXY_DIR/$DOMAIN"
    
    # حذف فایل پیش‌فرض برای جلوگیری از تداخل
    rm -f /etc/nginx/sites-enabled/default

    # ایجاد کانفیگ پایه انجینکس
    cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 0;
    
    # مسیر فایل‌های پروکسی
    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;
    
    location / {
        return 200 "Server is up and running for $DOMAIN. Add a path to see your service.";
        add_header Content-Type text/plain;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
    systemctl restart nginx

    echo "=============================="
    echo "Choose SSL Provider:"
    echo "1) Certbot (Let's Encrypt)"
    echo "2) Acme.sh (ZeroSSL - Recommended if Let's Encrypt is limited)"
    read -p "Choice (1 or 2): " ssl_choice

    if [ "$ssl_choice" == "1" ]; then
        apt install certbot python3-certbot-nginx -y
        certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email
    
    elif [ "$ssl_choice" == "2" ]; then
        curl https://get.acme.sh | sh
        ~/.acme.sh/acme.sh --register-account -m admin@$DOMAIN --server zerossl
        ~/.acme.sh/acme.sh --set-default-ca --server zerossl
        ~/.acme.sh/acme.sh --issue -d $DOMAIN --nginx
        
        mkdir -p /etc/nginx/ssl
        ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
            --key-file /etc/nginx/ssl/$DOMAIN.key \
            --fullchain-file /etc/nginx/ssl/$DOMAIN.cer \
            --reloadcmd "systemctl reload nginx"
            
        cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate /etc/nginx/ssl/$DOMAIN.cer;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;
    client_max_body_size 0;

    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;

    location / {
        return 200 "Secure Server is active for $DOMAIN";
        add_header Content-Type text/plain;
    }
}
EOF
    fi
    
    systemctl restart nginx
    echo -e "\e[32mNginx and SSL successfully configured!\e[0m"
}

# تابع اضافه کردن Reverse Proxy (اصلاح شده برای رفع صفحه سفید)
function add_proxy() {
    read -p "Enter Domain: " DOMAIN
    read -p "Enter Internal Port (e.g., 2053): " PORT
    read -p "Enter Path (e.g., ui): " PPATH
    
    PPATH="${PPATH#/}"
    PPATH="${PPATH%/}"
    
    if [ ! -d "$NGINX_PROXY_DIR/$DOMAIN" ]; then
        echo -e "\e[31mDomain configuration not found!\e[0m"
        return
    fi
    
    # ایجاد فایل کانفیگ مسیر اختصاصی با تنظیمات ضد صفحه سفید
    cat > "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf" <<EOF
location ^~ /$PPATH/ {
    proxy_pass http://127.0.0.1:$PORT/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    
    # تنظیمات پایداری برای پنل‌ها و فایل‌ها
    proxy_buffering off;
    proxy_redirect off;
    proxy_read_timeout 600s;
}

# ریدایرکت خودکار اگر کاربر اسلش آخر را نگذاشت
location = /$PPATH {
    return 301 \$scheme://\$host/\$PPATH/;
}
EOF
    
    nginx -t && systemctl reload nginx
    echo -e "\e[32mSuccess! Access: https://$DOMAIN/$PPATH/\e[0m"
    echo -e "\e[33mNote: If you see a blank page, set the 'Base Path' to /$PPATH/ in your panel settings!\e[0m"
}

# تابع حذف کامل
function uninstall_all() {
    read -p "Are you sure? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop nginx
        apt purge nginx certbot -y
        apt autoremove -y
        rm -rf /etc/nginx /etc/letsencrypt ~/.acme.sh
        echo -e "\e[32mUninstalled.\e[0m"
    fi
}

function list_proxies() {
    echo -e "\e[33m=== Configured Proxies ===\e[0m"
    for d in "$NGINX_PROXY_DIR"/*; do
        [ -d "$d" ] || continue
        echo -e "\e[32mDomain: $(basename "$d")\e[0m"
        for f in "$d"/*.conf; do
            P=$(basename "$f" .conf)
            PORT=$(grep "proxy_pass" "$f" | sed -E 's/.*:([0-9]+).*/\1/' | head -1)
            echo -e "  ➜ https://$(basename "$d")/$P/  -->  Port: $PORT"
        done
    done
}

# منو
while true; do
    echo -e "\n1) Install Nginx & SSL\n2) Add Proxy Path\n3) Uninstall All\n4) List Proxies\n5) Exit"
    read -p "Select: " choice
    case $choice in
        1) install_nginx_ssl ;;
        2) add_proxy ;;
        3) uninstall_all ;;
        4) list_proxies ;;
        5) exit 0 ;;
    esac
done
