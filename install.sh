#!/bin/bash

# بررسی دسترسی Root
if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mPlease run this script as root.\e[0m"
  exit 1
fi

NGINX_PROXY_DIR="/etc/nginx/proxy.d"
SCRIPT_PATH=$(realpath "$0")

# تابع برای تبدیل اسکریپت به یک دستور سیستمی
function setup_global_command() {
    if [ ! -f "/usr/local/bin/auto-ssl" ]; then
        ln -sf "$SCRIPT_PATH" /usr/local/bin/auto-ssl
        chmod +x /usr/local/bin/auto-ssl
        echo -e "\e[32mCommand 'auto-ssl' installed. You can now run this script from anywhere.\e[0m"
    fi
}

# فراخوان نصب دستور در هر بار اجرا
setup_global_command

# تابع نصب انجینکس و SSL
function install_nginx_ssl() {
    read -p "Enter Domain (e.g., example.com): " DOMAIN
    echo -e "\e[34mInstalling Nginx...\e[0m"
    apt update && apt install nginx curl ufw -y
    
    mkdir -p "$NGINX_PROXY_DIR/$DOMAIN"
    
    cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;
    location / {
        return 200 "Server is up.";
        add_header Content-Type text/plain;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
    systemctl restart nginx

    echo "Choose SSL Provider: 1) Certbot 2) Acme.sh"
    read -p "Choice: " ssl_choice

    if [ "$ssl_choice" == "1" ]; then
        apt install certbot python3-certbot-nginx -y
        certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email
    elif [ "$ssl_choice" == "2" ]; then
        curl https://get.acme.sh | sh
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --issue -d $DOMAIN --nginx
        mkdir -p /etc/nginx/ssl
        ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
            --key-file /etc/nginx/ssl/$DOMAIN.key \
            --fullchain-file /etc/nginx/ssl/$DOMAIN.cer \
            --reloadcmd "systemctl reload nginx"
        
        # آپدیت کانفیگ به HTTPS برای Acme
        cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server { listen 80; server_name $DOMAIN; return 301 https://\$host\$request_uri; }
server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate /etc/nginx/ssl/$DOMAIN.cer;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;
    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;
    location / { return 200 "Secure Server up."; add_header Content-Type text/plain; }
}
EOF
    fi
    systemctl reload nginx
}

# تابع مدیریت فایروال
function manage_firewall() {
    echo -e "\n\e[33m--- Firewall (UFW) Management ---\e[0m"
    echo "1) Open HTTP/HTTPS (80, 443) & SSH (22)"
    echo "2) Block a specific port (Internal Port)"
    echo "3) Open a specific port"
    echo "4) Disable Firewall"
    read -p "Select [1-4]: " fw_choice

    case $fw_choice in
        1)
            ufw allow 22/tcp
            ufw allow 80/tcp
            ufw allow 443/tcp
            ufw --force enable
            echo -e "\e[32mStandard ports (22, 80, 443) opened and Firewall enabled.\e[0m"
            ;;
        2)
            read -p "Enter port to BLOCK: " bport
            ufw deny "$bport"
            echo -e "\e[31mPort $bport blocked.\e[0m"
            ;;
        3)
            read -p "Enter port to OPEN: " oport
            ufw allow "$oport"
            echo -e "\e[32mPort $oport opened.\e[0m"
            ;;
        4)
            ufw disable
            echo -e "\e[31mFirewall disabled.\e[0m"
            ;;
    esac
}

# تابع لیست کردن پورت‌ها، مسیرها و آدرس کلیدهای SSL
function list_proxies() {
    echo -e "\n\e[33m=== Configured Proxies & SSL Info ===\e[0m"
    if [ ! -d "$NGINX_PROXY_DIR" ]; then echo "No config found."; return; fi
    
    for domain_path in "$NGINX_PROXY_DIR"/*; do
        if [ -d "$domain_path" ]; then
            DOMAIN=$(basename "$domain_path")
            echo -e "\e[32mDomain: $DOMAIN\e[0m"
            
            # نمایش مسیرهای SSL
            if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
                echo -e "  \e[90mSSL (Certbot):\e[0m"
                echo -e "    - Pub: /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
                echo -e "    - Priv: /etc/letsencrypt/live/$DOMAIN/privkey.pem"
            elif [ -f "/etc/nginx/ssl/$DOMAIN.cer" ]; then
                echo -e "  \e[90mSSL (Acme):\e[0m"
                echo -e "    - Pub: /etc/nginx/ssl/$DOMAIN.cer"
                echo -e "    - Priv: /etc/nginx/ssl/$DOMAIN.key"
            fi

            # نمایش مسیرهای پروکسی
            shopt -s nullglob
            for conf_file in "$domain_path"/*.conf; do
                PPATH=$(basename "$conf_file" .conf)
                PORT=$(grep "proxy_pass" "$conf_file" | sed -E 's/.*:([0-9]+)\/.*/\1/')
                echo -e "  - Path: \e[36m/$PPATH\e[0m  -->  Internal Port: \e[35m$PORT\e[0m"
            done
            shopt -u nullglob
        fi
    done
}

# بقیه توابع (Add/Remove/Uninstall) مشابه نسخه قبل...
function add_proxy() {
    read -p "Enter Domain: " DOMAIN
    read -p "Internal Port: " PORT
    read -p "Path (e.g., panel): " PPATH
    PPATH="${PPATH#/}"
    if [ ! -d "$NGINX_PROXY_DIR/$DOMAIN" ]; then echo "Setup domain first."; return; fi
    cat > "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf" <<EOF
location /$PPATH/ {
    proxy_pass http://127.0.0.1:$PORT/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
}
EOF
    nginx -t && systemctl reload nginx && echo -e "\e[32mDone: https://$DOMAIN/$PPATH/\e[0m"
}

function remove_proxy() {
    read -p "Domain: " DOMAIN
    read -p "Path: " PPATH
    rm -f "$NGINX_PROXY_DIR/$DOMAIN/${PPATH#/}.conf"
    systemctl reload nginx && echo "Removed."
}

function uninstall_all() {
    read -p "Delete everything? (y/n): " confirm
    if [ "$confirm" == "y" ]; then
        apt purge nginx certbot -y && rm -rf /etc/nginx /etc/letsencrypt ~/.acme.sh /usr/local/bin/auto-ssl
        echo "Cleaned up."
    fi
}

while true; do
    echo -e "\n\e[36mAuto Nginx & SSL Manager\e[0m"
    echo "1) Setup Nginx & SSL"
    echo "2) Add Proxy Path"
    echo "3) List Proxies & SSL Keys Path"
    echo "4) Firewall Management (UFW)"
    echo "5) Remove a Path"
    echo "6) Uninstall All"
    echo "7) Exit"
    read -p "Option: " choice
    case $choice in
        1) install_nginx_ssl ;;
        2) add_proxy ;;
        3) list_proxies ;;
        4) manage_firewall ;;
        5) remove_proxy ;;
        6) uninstall_all ;;
        7) exit 0 ;;
    esac
done
