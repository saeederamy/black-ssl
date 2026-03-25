#!/bin/bash

# --- بررسی دسترسی Root ---
if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mPlease run this script as root.\e[0m"
  exit 1
fi

# --- نصب خودکار به عنوان دستور سیستمی ---
SCRIPT_PATH=$(realpath "$0")
COMMAND_PATH="/usr/local/bin/auto-ssl"

if [[ "$SCRIPT_PATH" != "$COMMAND_PATH" ]]; then
    echo -e "\e[34mInstalling 'auto-ssl' as a global command...\e[0m"
    cp "$SCRIPT_PATH" "$COMMAND_PATH"
    chmod +x "$COMMAND_PATH"
    ln -sf "$COMMAND_PATH" "/usr/bin/auto-ssl"
    echo -e "\e[32m✔ Done! From now on, just type 'auto-ssl' anywhere in your terminal.\e[0m"
    sleep 2
    # اجرای نسخه نصب شده و خروج از فایل فعلی
    exec "$COMMAND_PATH" "$@"
fi

NGINX_PROXY_DIR="/etc/nginx/proxy.d"

# --- تابع نصب انجینکس و SSL ---
function install_nginx_ssl() {
    read -p "Enter Domain (e.g., example.com): " DOMAIN
    
    echo -e "\e[34mInstalling Nginx...\e[0m"
    apt update && apt install nginx curl -y
    mkdir -p "$NGINX_PROXY_DIR/$DOMAIN"
    
    cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;
    
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
    echo "1) Certbot (Recommended)"
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
server { listen 80; server_name $DOMAIN; return 301 https://\$host\$request_uri; }
server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate /etc/nginx/ssl/$DOMAIN.cer;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;
    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;
    
    error_page 404 /custom_404.html;
    location = /custom_404.html { return 200 "Secure Server is ready."; add_header Content-Type text/plain; }
}
EOF
    fi
    systemctl reload nginx
    echo -e "\e[32mNginx and SSL successfully configured for $DOMAIN!\e[0m"
    sleep 2
}

# --- تابع اضافه کردن Reverse Proxy با پشتیبانی Sub-Filter ---
function add_proxy() {
    read -p "Enter Domain (e.g., example.com): " DOMAIN
    read -p "Enter Internal Port (e.g., 8080): " PORT
    echo -e "\e[33mTip: Type '/' for Root domain, or type a path like 'panel'\e[0m"
    read -p "Enter Path: " PPATH
    
    if [ ! -d "$NGINX_PROXY_DIR/$DOMAIN" ]; then
        echo -e "\e[31mDomain configuration not found. Setup domain first.\e[0m"
        sleep 2; return
    fi

    PPATH="${PPATH#/}" 
    PPATH="${PPATH%/}" 
    
    if [ -z "$PPATH" ]; then
        # پروکسی ریشه اصلی (بدون نیاز به Sub_Filter)
        cat > "$NGINX_PROXY_DIR/$DOMAIN/root.conf" <<EOF
location / {
    proxy_pass http://127.0.0.1:$PORT;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
}
EOF
        SUCCESS_URL="https://$DOMAIN/"
    else
        # پروکسی مسیر فرعی + اصلاح هوشمند آدرس‌ها برای پنل پایتون
        cat > "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf" <<EOF
location /$PPATH/ {
    proxy_pass http://127.0.0.1:$PORT/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # Rewrite URL for custom apps (Python, etc.)
    proxy_set_header Accept-Encoding "";
    sub_filter 'src="/' 'src="/$PPATH/';
    sub_filter 'href="/' 'href="/$PPATH/';
    sub_filter 'action="/' 'action="/$PPATH/';
    sub_filter 'url("/' 'url("/$PPATH/';
    sub_filter_once off;
    sub_filter_types text/html text/css text/javascript application/javascript application/json;
}
EOF
        SUCCESS_URL="https://$DOMAIN/$PPATH/"
    fi
    
    nginx -t && systemctl reload nginx
    if [ $? -eq 0 ]; then
        echo -e "\e[32mSuccess! Access your service at: $SUCCESS_URL\e[0m"
    else
        echo -e "\e[31mConfig test failed. Removing invalid config...\e[0m"
        rm "$NGINX_PROXY_DIR/$DOMAIN/${PPATH:-root}.conf"
    fi
    sleep 2
}

# --- توابع حذف و لیست کردن ---
function uninstall_all() {
    read -p "Are you sure you want to completely remove Nginx and this script? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop nginx
        apt purge nginx certbot python3-certbot-nginx -y
        apt autoremove -y
        rm -rf /etc/nginx /var/www/html /etc/letsencrypt ~/.acme.sh /root/.acme.sh
        rm -f "/usr/local/bin/auto-ssl" "/usr/bin/auto-ssl"
        echo -e "\e[32mAll services, configurations, and the auto-ssl command have been removed.\e[0m"
        exit 0
    fi
}

function remove_proxy() {
    read -p "Enter Domain (e.g., example.com): " DOMAIN
    read -p "Enter Path to remove (Type 'root' for main domain proxy): " PPATH
    PPATH="${PPATH#/}"; PPATH="${PPATH%/}"
    [ -z "$PPATH" ] && PPATH="root"
    
    if [ -f "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf" ]; then
        rm "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf"
        nginx -t && systemctl reload nginx
        echo -e "\e[32mPath successfully removed.\e[0m"
    else
        echo -e "\e[31mPath configuration not found!\e[0m"
    fi
    sleep 2
}

function list_proxies() {
    echo -e "\e[33m=== Configured Proxies ===\e[0m"
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
    read -p "Press Enter to continue..."
}

# --- حلقه اصلی منو ---
while true; do
    clear
    echo -e "\e[36m=========================================\e[0m"
    echo "  Auto Nginx & SSL Reverse Proxy Manager   "
    echo -e "\e[36m=========================================\e[0m"
    echo "1) Install Nginx & Get SSL"
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
        6) clear; exit 0 ;;
        *) echo -e "\e[31mInvalid option.\e[0m"; sleep 1 ;;
    esac
done
