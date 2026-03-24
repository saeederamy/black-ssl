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
    apt update && apt install nginx curl -y
    
    mkdir -p "$NGINX_PROXY_DIR/$DOMAIN"
    
    # ایجاد کانفیگ پایه انجینکس
    cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    
    # مسیر فایل‌های پروکسی
    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;
    
    location / {
        return 200 "Server is up and running.";
        add_header Content-Type text/plain;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
    systemctl restart nginx

    echo "=============================="
    echo "Choose SSL Provider:"
    echo "1) Certbot (Recommended - Auto configures Nginx)"
    echo "2) Acme.sh"
    read -p "Choice (1 or 2): " ssl_choice

    if [ "$ssl_choice" == "1" ]; then
        echo -e "\e[34mInstalling Certbot...\e[0m"
        apt install certbot python3-certbot-nginx -y
        certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email
    
    elif [ "$ssl_choice" == "2" ]; then
        echo -e "\e[34mInstalling Acme.sh...\e[0m"
        curl https://get.acme.sh | sh
        source ~/.bashrc
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --issue -d $DOMAIN --nginx
        
        # نصب سرتیفیکیت‌ها و تنظیم کانفیگ انجینکس برای Acme
        mkdir -p /etc/nginx/ssl
        ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
            --key-file /etc/nginx/ssl/$DOMAIN.key \
            --fullchain-file /etc/nginx/ssl/$DOMAIN.cer \
            --reloadcmd "systemctl reload nginx"
            
        # ارتقا کانفیگ پایه به HTTPS
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

    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;

    location / {
        return 200 "Secure Server is up and running.";
        add_header Content-Type text/plain;
    }
}
EOF
    else
        echo -e "\e[31mInvalid choice. Skipping SSL.\e[0m"
    fi
    
    systemctl reload nginx
    echo -e "\e[32mNginx and SSL successfully configured for $DOMAIN!\e[0m"
}

# تابع اضافه کردن Reverse Proxy
function add_proxy() {
    read -p "Enter Domain (e.g., example.com): " DOMAIN
    read -p "Enter Internal Port (e.g., 8080): " PORT
    read -p "Enter Path (e.g., panel): " PPATH
    
    # حذف اسلش اضافه در صورت تایپ اشتباه کاربر
    PPATH="${PPATH#/}"
    
    if [ ! -d "$NGINX_PROXY_DIR/$DOMAIN" ]; then
        echo -e "\e[31mDomain configuration not found. Please setup domain first (Option 1).\e[0m"
        return
    fi
    
    # ایجاد فایل کانفیگ مسیر اختصاصی
    cat > "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf" <<EOF
location /$PPATH/ {
    proxy_pass http://127.0.0.1:$PORT/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
}
EOF
    # تست و ریستارت انجینکس
    nginx -t && systemctl reload nginx
    if [ $? -eq 0 ]; then
        echo -e "\e[32mSuccess! Access your service at: https://$DOMAIN/$PPATH/\e[0m"
    else
        echo -e "\e[31mNginx config test failed. Removing invalid config...\e[0m"
        rm "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf"
    fi
}

# تابع حذف کامل سرویس‌ها
function uninstall_all() {
    read -p "Are you sure you want to completely remove Nginx, Certbot, and Acme.sh? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo -e "\e[31mUninstalling everything...\e[0m"
        systemctl stop nginx
        apt purge nginx nginx-common nginx-core certbot python3-certbot-nginx -y
        apt autoremove -y
        
        # پاکسازی دایرکتوری‌ها
        rm -rf /etc/nginx /var/www/html /etc/letsencrypt ~/.acme.sh /root/.acme.sh
        
        echo -e "\e[32mAll services and configurations have been completely removed.\e[0m"
    else
        echo -e "\e[34mUninstallation cancelled.\e[0m"
    fi
}

# تابع حذف یک مسیر خاص
function remove_proxy() {
    read -p "Enter Domain (e.g., example.com): " DOMAIN
    read -p "Enter Path to remove (e.g., panel): " PPATH
    PPATH="${PPATH#/}"
    
    FILE_PATH="$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf"
    
    if [ -f "$FILE_PATH" ]; then
        rm "$FILE_PATH"
        nginx -t && systemctl reload nginx
        echo -e "\e[32mPath /$PPATH successfully removed from reverse proxy.\e[0m"
    else
        echo -e "\e[31mPath configuration not found!\e[0m"
    fi
}

# تابع نمایش پورت‌ها و مسیرهای تنظیم شده
function list_proxies() {
    echo -e "\e[33m=== Configured Proxies ===\e[0m"
    if [ ! -d "$NGINX_PROXY_DIR" ]; then
        echo -e "\e[31mNo proxy configurations found.\e[0m"
        return
    fi
    
    for domain_path in "$NGINX_PROXY_DIR"/*; do
        if [ -d "$domain_path" ]; then
            DOMAIN=$(basename "$domain_path")
            echo -e "\e[32mDomain: $DOMAIN\e[0m"
            
            # پیدا کردن فایل‌های کانفیگ
            shopt -s nullglob
            CONF_FILES=("$domain_path"/*.conf)
            shopt -u nullglob
            
            if [ ${#CONF_FILES[@]} -eq 0 ]; then
                echo "  No paths configured."
            else
                for conf_file in "${CONF_FILES[@]}"; do
                    # استخراج نام مسیر از اسم فایل
                    PPATH=$(basename "$conf_file" .conf)
                    
                    # استخراج پورت از خط proxy_pass
                    PORT=$(grep "proxy_pass" "$conf_file" | sed -E 's/.*:([0-9]+)\/.*/\1/')
                    
                    echo -e "  - Path: \e[36m/$PPATH\e[0m  -->  Port: \e[35m$PORT\e[0m"
                done
            fi
        fi
    done
    echo "=========================="
}

# حلقه اصلی منو
while true; do
    echo ""
    echo -e "\e[36m=========================================\e[0m"
    echo "  Auto Nginx & SSL Reverse Proxy Manager   "
    echo -e "\e[36m=========================================\e[0m"
    echo "1) Install Nginx & Get SSL (Certbot/Acme)"
    echo "2) Add Reverse Proxy (Port -> Path)"
    echo "3) Remove All (Nginx, SSL, Configs)"
    echo "4) Remove a Specific Proxy Path"
    echo "5) List Configured Ports and Paths"
    echo "6) Exit"
    echo "========================================="
    read -p "Select an option [1-6]: " choice

    case $choice in
        1) install_nginx_ssl ;;
        2) add_proxy ;;
        3) uninstall_all ;;
        4) remove_proxy ;;
        5) list_proxies ;;
        6) echo "Exiting..."; exit 0 ;;
        *) echo -e "\e[31mInvalid option. Please try again.\e[0m" ;;
    esac
done
