#!/bin/bash

# --- Fix Backspace ^H Issue ---
stty erase ^H

# Check Root Access
if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mError: Please run this script as root (sudo).\e[0m"
  exit 1
fi

# Directories
NGINX_CONF_DIR="/etc/nginx/sites-available"
DATA_DIR="/etc/nginx/proxy_manager"
mkdir -p "$DATA_DIR"

header() {
    clear
    echo -e "\e[36m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\e[0m"
    echo -e "\e[36m┃\e[0m \e[1;37m        NGINX PROXY MANAGER - FINAL FIX              \e[0m \e[36m┃\e[0m"
    echo -e "\e[36m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\e[0m"
}

# تابع بازسازی کانفیگ (بسیار دقیق)
rebuild_config() {
    local DOMAIN=$1
    local CONF_FILE="$NGINX_CONF_DIR/$DOMAIN"
    local PATHS_FILE="$DATA_DIR/$DOMAIN.paths"
    local SSL_TYPE_FILE="$DATA_DIR/$DOMAIN.ssl"
    
    # شروع ساخت فایل از صفر
    cat > "$CONF_FILE" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 0;
EOF

    # اضافه کردن پث‌ها به پورت 80
    if [ -f "$PATHS_FILE" ]; then
        while read -r line; do
            [ -z "$line" ] && continue
            ppath=$(echo $line | cut -d',' -f1)
            pport=$(echo $line | cut -d',' -f2)
            cat >> "$CONF_FILE" <<EOF
    location ^~ /$ppath/ {
        proxy_pass http://127.0.0.1:$pport;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    location = /$ppath { return 301 \$scheme://\$host/\$ppath/; }
EOF
        done < "$PATHS_FILE"
    fi

    cat >> "$CONF_FILE" <<EOF
    location / { add_header Content-Type text/plain; return 200 "Nginx active for $DOMAIN"; }
}
EOF

    # اگر SSL فعال است، بلاک 443 را با دقت بساز
    if [ -f "$SSL_TYPE_FILE" ]; then
        SSL_TYPE=$(cat "$SSL_TYPE_FILE")
        cat >> "$CONF_FILE" <<EOF
server {
    listen 443 ssl;
    server_name $DOMAIN;
    client_max_body_size 0;
EOF
        if [ "$SSL_TYPE" == "certbot" ]; then
            cat >> "$CONF_FILE" <<EOF
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
EOF
        else
            cat >> "$CONF_FILE" <<EOF
    ssl_certificate /etc/nginx/ssl/$DOMAIN.cer;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;
EOF
        fi

        # اضافه کردن پث‌ها به پورت 443
        if [ -f "$PATHS_FILE" ]; then
            while read -r line; do
                [ -z "$line" ] && continue
                ppath=$(echo $line | cut -d',' -f1)
                pport=$(echo $line | cut -d',' -f2)
                cat >> "$CONF_FILE" <<EOF
    location ^~ /$ppath/ {
        proxy_pass http://127.0.0.1:$pport;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
    }
    location = /$ppath { return 301 \$scheme://\$host/\$ppath/; }
EOF
            done < "$PATHS_FILE"
        fi
        cat >> "$CONF_FILE" <<EOF
    location / { add_header Content-Type text/plain; return 200 "Secure SSL Active for $DOMAIN"; }
}
EOF
    fi

    # فعال‌سازی و ریستارت قطعی
    ln -sf "$CONF_FILE" "/etc/nginx/sites-enabled/"
    nginx -t && systemctl restart nginx
}

# --- 1) Setup Domain & SSL ---
install_nginx_ssl() {
    header
    read -e -p "Enter Domain: " DOMAIN
    
    # پاکسازی تمام کانفیگ‌های قبلی این دامنه
    rm -f /etc/nginx/sites-enabled/default
    rm -f "/etc/nginx/sites-enabled/$DOMAIN"
    
    apt update && apt install nginx curl certbot python3-certbot-nginx -y
    
    rebuild_config "$DOMAIN"
    
    echo -e "\nChoose SSL Provider: 1) Certbot 2) Acme.sh"
    read -p "Selection: " ssl_choice
    if [ "$ssl_choice" == "1" ]; then
        certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email --force-renewal
        echo "certbot" > "$DATA_DIR/$DOMAIN.ssl"
    else
        curl https://get.acme.sh | sh
        ~/.acme.sh/acme.sh --issue -d $DOMAIN --nginx
        mkdir -p /etc/nginx/ssl
        ~/.acme.sh/acme.sh --install-cert -d $DOMAIN --key-file /etc/nginx/ssl/$DOMAIN.key --fullchain-file /etc/nginx/ssl/$DOMAIN.cer
        echo "acme" > "$DATA_DIR/$DOMAIN.ssl"
    fi
    
    rebuild_config "$DOMAIN"
    echo -e "\e[32m✔ SSL Setup Complete.\e[0m"
    read -p "Press Enter..."
}

# --- 2) Add Proxy Path ---
add_proxy() {
    header
    read -e -p "Enter Domain: " DOMAIN
    if [ ! -f "$NGINX_CONF_DIR/$DOMAIN" ]; then echo "Setup Domain first!"; sleep 2; return; fi
    
    read -e -p "Enter Internal Port (e.g., 2053): " PORT
    read -e -p "Enter Path (e.g., ui): " PPATH
    PPATH="${PPATH#/}"
    PPATH="${PPATH%/}"

    # ذخیره مسیر
    echo "$PPATH,$PORT" >> "$DATA_DIR/$DOMAIN.paths"
    
    # بازسازی
    rebuild_config "$DOMAIN"
    
    echo -e "\e[32m✔ Success: https://$DOMAIN/$PPATH/\e[0m"
    read -p "Press Enter..."
}

# --- 3) Show Config (برای عیب‌یابی) ---
show_debug() {
    header
    read -e -p "Enter Domain: " DOMAIN
    if [ -f "$NGINX_CONF_DIR/$DOMAIN" ]; then
        echo -e "\e[33m--- Current Nginx Config for $DOMAIN ---\e[0m"
        cat "$NGINX_CONF_DIR/$DOMAIN"
    else
        echo "No config found."
    fi
    read -p "Press Enter..."
}

# --- سایر منوها ---
delete_data() {
    header
    read -e -p "Enter Domain to Reset/Delete: " DOMAIN
    rm -f "$NGINX_CONF_DIR/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN" "$DATA_DIR/$DOMAIN"*
    systemctl restart nginx
    echo "✔ Deleted."
    sleep 2
}

while true; do
    header
    echo -e "1) Setup Domain & SSL (Step 1)"
    echo -e "2) Add Proxy Path (Step 2)"
    echo -e "3) Debug: Show My Config"
    echo -e "4) Delete Domain Data"
    echo -e "5) Exit"
    read -p " Option: " opt
    case $opt in
        1) install_nginx_ssl ;;
        2) add_proxy ;;
        3) show_debug ;;
        4) delete_data ;;
        5) exit 0 ;;
    esac
done
