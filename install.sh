#!/bin/bash

# --- Fix Backspace ^H Issue ---
stty erase ^H

# Check Root Access
if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mError: Please run this script as root (sudo).\e[0m"
  exit 1
fi

NGINX_PROXY_DIR="/etc/nginx/proxy.d"
SCRIPT_NAME="auto-ssl"
GLOBAL_PATH="/usr/local/bin/$SCRIPT_NAME"

# --- Install Script as Global Command ---
setup_command() {
    # If the current script is not already in the global path, copy it there
    if [[ "$(realpath "$0")" != "$GLOBAL_PATH" ]]; then
        cp "$(realpath "$0")" "$GLOBAL_PATH"
        chmod +x "$GLOBAL_PATH"
        echo -e "\e[32m✔ Command '$SCRIPT_NAME' installed. You can now run it from anywhere by typing '$SCRIPT_NAME'.\e[0m"
    fi
}
setup_command

# --- UI Header ---
header() {
    clear
    echo -e "\e[36m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\e[0m"
    echo -e "\e[36m┃\e[0m \e[1;37m        NGINX MANAGER & SSL AUTO-CONFIGURATOR         \e[0m \e[36m┃\e[0m"
    echo -e "\e[36m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\e[0m"
}

# --- 1) Install Nginx & SSL ---
install_nginx_ssl() {
    header
    echo -e "\e[1;33m[1] Setup Domain and Install SSL\e[0m\n"
    read -e -p "Enter Domain (e.g., example.com): " DOMAIN
    
    echo -e "\e[34mInstalling dependencies...\e[0m"
    apt update && apt install nginx curl ufw -y
    mkdir -p "$NGINX_PROXY_DIR/$DOMAIN"

    echo -e "\nChoose SSL Provider:"
    echo "1) Certbot (Standard/Automated)"
    echo "2) Acme.sh (Lightweight/Manual style)"
    read -p "Selection (1/2): " ssl_choice

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
        
        # Configure Nginx for Acme SSL
        cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server { listen 80; server_name $DOMAIN; return 301 https://\$host\$request_uri; }
server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate /etc/nginx/ssl/$DOMAIN.cer;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;
    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;
    location / { return 200 "SSL Server is Active."; add_header Content-Type text/plain; }
}
EOF
    fi
    systemctl reload nginx
    echo -e "\e[32m✔ Setup completed successfully.\e[0m"
    read -p "Press Enter to continue..." 
}

# --- 2) Add Reverse Proxy ---
add_proxy() {
    header
    echo -e "\e[1;33m[2] Add New Reverse Proxy Path\e[0m\n"
    read -e -p "Enter Domain (already setup): " DOMAIN
    if [ ! -d "$NGINX_PROXY_DIR/$DOMAIN" ]; then echo "Error: Domain directory not found."; sleep 2; return; fi
    
    read -e -p "Enter Internal Port (e.g., 8080): " PORT
    read -e -p "Enter Desired Path (e.g., panel): " PPATH
    PPATH="${PPATH#/}"

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
    nginx -t && systemctl reload nginx
    echo -e "\e[32m✔ Success: https://$DOMAIN/$PPATH is now active.\e[0m"
    read -p "Press Enter to continue..." 
}

# --- 3) List Proxies & SSL Keys ---
list_proxies() {
    header
    echo -e "\e[1;33m[3] List of Proxies, Ports, and SSL Keys\e[0m\n"
    if [ ! -d "$NGINX_PROXY_DIR" ]; then echo "No configurations found."; sleep 2; return; fi
    
    for domain_path in "$NGINX_PROXY_DIR"/*; do
        [ -d "$domain_path" ] || continue
        DOMAIN=$(basename "$domain_path")
        echo -e "\e[1;32m● Domain: $DOMAIN\e[0m"
        
        # Show SSL Key Paths
        if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
            echo -e "   \e[90mPrivate Key:\e[0m /etc/letsencrypt/live/$DOMAIN/privkey.pem"
            echo -e "   \e[90mPublic Key: \e[0m /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        elif [ -f "/etc/nginx/ssl/$DOMAIN.key" ]; then
            echo -e "   \e[90mPrivate Key:\e[0m /etc/nginx/ssl/$DOMAIN.key"
            echo -e "   \e[90mPublic Key: \e[0m /etc/nginx/ssl/$DOMAIN.cer"
        fi

        # List Proxy Paths
        shopt -s nullglob
        for conf in "$domain_path"/*.conf; do
            PATH_NAME=$(basename "$conf" .conf)
            PORT=$(grep "proxy_pass" "$conf" | sed -E 's/.*:([0-9]+)\/.*/\1/')
            echo -e "   \e[36m➜ Path: /$PATH_NAME\e[0m  (Port: $PORT)"
        done
        shopt -u nullglob
        echo "----------------------------------------------------"
    done
    read -p "Press Enter to continue..." 
}

# --- 4) Delete Specific Proxy (Interactive) ---
delete_proxy_interactive() {
    header
    echo -e "\e[1;31m[4] Delete a Specific Proxy Path\e[0m\n"
    read -e -p "Enter Domain: " DOMAIN
    if [ ! -d "$NGINX_PROXY_DIR/$DOMAIN" ]; then echo "Domain not found."; sleep 2; return; fi
    
    files=("$NGINX_PROXY_DIR/$DOMAIN"/*.conf)
    if [ ${#files[@]} -eq 0 ]; then echo "No paths found for this domain."; sleep 2; return; fi
    
    echo "Current Active Paths:"
    i=1
    for f in "${files[@]}"; do
        PATH_NAME=$(basename "$f" .conf)
        PORT=$(grep "proxy_pass" "$f" | sed -E 's/.*:([0-9]+)\/.*/\1/')
        echo "$i) Path: /$PATH_NAME (Internal Port: $PORT)"
        let i++
    done
    
    read -p "Enter number to delete: " choice
    target_file="${files[$((choice-1))]}"
    
    if [ -f "$target_file" ]; then
        rm "$target_file"
        systemctl reload nginx
        echo -e "\e[32m✔ Path deleted successfully.\e[0m"
    else
        echo "Invalid selection."
    fi
    sleep 2
}

# --- 5) Firewall Management ---
firewall_menu() {
    header
    echo -e "\e[1;33m[5] Firewall Management (UFW)\e[0m\n"
    echo "1) Open Essential Ports (80, 443, 22)"
    echo "2) Block a specific Port (Hide service from direct access)"
    echo "3) Open a specific Port"
    echo "4) Disable Firewall"
    read -p "Select option: " fw
    case $fw in
        1) ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw --force enable ;;
        2) read -p "Enter Port to Block: " p && ufw deny $p ;;
        3) read -p "Enter Port to Open: " p && ufw allow $p ;;
        4) ufw disable ;;
    esac
}

# --- 6) Cleanup & Uninstall ---
uninstall_all() {
    header
    echo -e "\e[1;31m!!! WARNING: This will remove Nginx, SSL, and this Script !!!\e[0m"
    read -p "Are you sure? (y/n): " confirm
    if [ "$confirm" == "y" ]; then
        systemctl stop nginx
        apt purge nginx certbot -y
        apt autoremove -y
        rm -rf /etc/nginx /etc/letsencrypt ~/.acme.sh "$GLOBAL_PATH"
        echo -e "\e[32m✔ All configurations removed.\e[0m"
        echo -e "\e[33mDeleting script file in 3 seconds...\e[0m"
        sleep 3
        rm -- "$0"
        exit
    fi
}

# --- Main Menu Loop ---
while true; do
    header
    echo -e "\e[1;32m1)\e[0m Install Nginx & Setup SSL for New Domain"
    echo -e "\e[1;32m2)\e[0m Add Reverse Proxy Path (Port -> Path)"
    echo -e "\e[1;32m3)\e[0m List All Proxies & SSL Key Paths"
    echo -e "\e[1;32m4)\e[0m Remove a Specific Proxy Path"
    echo -e "\e[1;32m5)\e[0m Firewall Management (UFW)"
    echo -e "\e[1;31m6)\e[0m FULL UNINSTALL (Remove Nginx, SSL, and Script)"
    echo -e "\e[1;37m7)\e[0m Exit"
    echo -e "\e[36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\e[0m"
    read -p " Select Option [1-7]: " main_choice

    case $main_choice in
        1) install_nginx_ssl ;;
        2) add_proxy ;;
        3) list_proxies ;;
        4) delete_proxy_interactive ;;
        5) firewall_menu ;;
        6) uninstall_all ;;
        7) exit 0 ;;
        *) echo "Invalid selection."; sleep 1 ;;
    esac
done
