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
    
    # ایجاد کانفیگ پایه انجینکس (بدون Location / پیش‌فرض تا تداخل ایجاد نشود)
    cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    
    # مسیر فایل‌های پروکسی
    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;
    
    # در صورتی که کاربری پروکسی روت نساخته باشد، این صفحه موقت نمایش داده می‌شود
    error_page 404 /custom_404.html;
    location = /custom_404.html {
        return 200 "Server is ready. Please add a proxy path.";
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

    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;
    
    error_page 404 /custom_404.html;
    location = /custom_404.html {
        return 200 "Secure Server is ready. Please add a proxy path.";
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
    echo -e "\e[33mTip: Type '/' to proxy the entire domain (Recommended for panels), or type a path like 'panel'\e[0m"
    read -p "Enter Path: " PPATH
    
    if [ ! -d "$NGINX_PROXY_DIR/$DOMAIN" ]; then
        echo -e "\e[31mDomain configuration not found. Please setup domain first (Option 1).\e[0m"
        return
    fi

    # پردازش هوشمند مسیر
    PPATH="${PPATH#/}" # حذف اسلش اول اگر بود
    PPATH="${PPATH%/}" # حذف اسلش آخر اگر بود
    
    if [ -z "$PPATH" ]; then
        # اگر کاربر فقط اسلش زد یا خالی گذاشت (پروکسی روی کل دامنه)
        LOC_BLOCK="/"
        FILE_NAME="root"
        PROXY_URL="http://127.0.0.1:$PORT" # برای روت اسلش آخر را برمیداریم
        SUCCESS_URL="https://$DOMAIN/"
    else
        # اگر کاربر مسیر وارد کرد (مثلاً panel)
        LOC_BLOCK="/$PPATH/"
        FILE_NAME="$PPATH"
        PROXY_URL="http://127.0.0.1:$PORT/" # اسلش آخر برای مسیر الزامی است
        SUCCESS_URL="https://$DOMAIN/$PPATH/"
    fi
    
    cat > "$NGINX_PROXY_DIR/$DOMAIN/$FILE_NAME.conf" <<EOF
location $LOC_BLOCK {
    proxy_pass $PROXY_URL;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}
EOF

    nginx -t && systemctl reload nginx
    if [ $? -eq 0 ]; then
        echo -e "\e[32mSuccess! Access your service at: $SUCCESS_URL\e[0m"
    else
        echo -e "\e[31mNginx config test failed. Removing invalid config...\e[0m"
        rm "$NGINX_PROXY_DIR/$DOMAIN/$FILE_NAME.conf"
    fi
}

# بقیه توابع (uninstall_all, remove_proxy, list_proxies و منو) دقیقاً مشابه کد خودتان است
function uninstall_all() {
    read -p "Are you sure you want to completely remove Nginx, Certbot, and Acme.sh? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo -e "\e[31mUninstalling everything...\e[0m"
        systemctl stop nginx
        apt purge nginx nginx-common nginx-core certbot python3-certbot-nginx -y
        apt autoremove -y
        rm -rf /etc/nginx /var/www/html /etc/letsencrypt ~/.acme.sh /root/.acme.sh
        echo -e "\e[32mAll services and configurations have been completely removed.\e[0m"
    else
        echo -e "\e[34mUninstallation cancelled.\e[0m"
    fi
}

function remove_proxy() {
    read -p "Enter Domain (e.g., example.com): " DOMAIN
    read -p "Enter Path to remove (Type 'root' if you want to remove the main domain proxy): " PPATH
    PPATH="${PPATH#/}"
    PPATH="${PPATH%/}"
    
    if [ -z "$PPATH" ]; then
        PPATH="root"
    fi
    
    FILE_PATH="$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf"
    
    if [ -f "$FILE_PATH" ]; then
        rm "$FILE_PATH"
        nginx -t && systemctl reload nginx
        echo -e "\e[32mPath successfully removed from reverse proxy.\e[0m"
    else
        echo -e "\e[31mPath configuration not found!\e[0m"
    fi
}

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
            shopt -s nullglob
            CONF_FILES=("$domain_path"/*.conf)
            shopt -u nullglob
            if [ ${#CONF_FILES[@]} -eq 0 ]; then
                echo "  No paths configured."
            else
                for conf_file in "${CONF_FILES[@]}"; do
                    PPATH=$(basename "$conf_file" .conf)
                    PORT=$(grep "proxy_pass" "$conf_file" | sed -E 's/.*:([0-9]+)\/?;/\1/')
                    if [ "$PPATH" == "root" ]; then
                        echo -e "  - Path: \e[36m/ (Root Domain)\e[0m  -->  Port: \e[35m$PORT\e[0m"
                    else
                        echo -e "  - Path: \e[36m/$PPATH\e[0m  -->  Port: \e[35m$PORT\e[0m"
                    fi
                done
            fi
        fi
    done
    echo "=========================="
}

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
