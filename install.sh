#!/bin/bash

# --- Color & UI Definitions ---
C_CYAN="\e[1;36m"
C_BLUE="\e[1;34m"
C_GREEN="\e[1;32m"
C_YELLOW="\e[1;33m"
C_RED="\e[1;31m"
C_WHITE="\e[1;37m"
C_RESET="\e[0m"

# --- Root Access Check ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${C_RED}✖ Please run this script as root.${C_RESET}"
  exit 1
fi

# --- Global Command Setup ---
SCRIPT_PATH=$(realpath "$0")
COMMAND_PATH="/usr/local/bin/auto-ssl"

if [[ "$SCRIPT_PATH" != "$COMMAND_PATH" ]]; then
    echo -e "${C_BLUE}❖ Installing 'auto-ssl' as a global command...${C_RESET}"
    cp "$SCRIPT_PATH" "$COMMAND_PATH"
    chmod +x "$COMMAND_PATH"
    ln -sf "$COMMAND_PATH" "/usr/bin/auto-ssl"
    echo -e "${C_GREEN}✔ Done! Type 'auto-ssl' anywhere to launch the panel.${C_RESET}"
    sleep 2
    exec "$COMMAND_PATH" "$@"
fi

NGINX_PROXY_DIR="/etc/nginx/proxy.d"

# --- Nginx & SSL Install (Non-Destructive) ---
function install_nginx_ssl() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET}         ${C_WHITE}Nginx & SSL Configuration${C_RESET}        ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    read -p "🔹 Enter Domain (e.g., example.com): " DOMAIN
    
    if ! command -v nginx &> /dev/null; then
        echo -e "${C_BLUE}❖ Installing Nginx...${C_RESET}"
        apt update && apt install nginx curl -y
    else
        echo -e "${C_GREEN}✔ Nginx is already installed. Skipping installation.${C_RESET}"
    fi
    
    mkdir -p "$NGINX_PROXY_DIR/$DOMAIN"
    
    # Check if domain config already exists to prevent overwriting
    if [ ! -f "/etc/nginx/sites-available/$DOMAIN" ]; then
        echo -e "${C_BLUE}❖ Creating new Nginx block for $DOMAIN...${C_RESET}"
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
    else
        echo -e "${C_YELLOW}⚠ Domain config already exists. Retaining existing Nginx block.${C_RESET}"
    fi
    
    systemctl restart nginx

    echo -e "\n${C_WHITE}Choose SSL Provider:${C_RESET}"
    echo -e "  ${C_CYAN}1)${C_RESET} Certbot (Recommended)"
    echo -e "  ${C_CYAN}2)${C_RESET} Acme.sh"
    echo -e "  ${C_CYAN}3)${C_RESET} Skip SSL (Already Installed)"
    read -p "Choice (1/2/3): " ssl_choice

    if [ "$ssl_choice" == "1" ]; then
        echo -e "${C_BLUE}❖ Installing Certbot...${C_RESET}"
        apt install certbot python3-certbot-nginx -y
        certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email
    elif [ "$ssl_choice" == "2" ]; then
        echo -e "${C_BLUE}❖ Installing Acme.sh...${C_RESET}"
        curl https://get.acme.sh | sh
        source ~/.bashrc
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --issue -d $DOMAIN --nginx
        mkdir -p /etc/nginx/ssl
        ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
            --key-file /etc/nginx/ssl/$DOMAIN.key \
            --fullchain-file /etc/nginx/ssl/$DOMAIN.cer \
            --reloadcmd "systemctl reload nginx"
            
        # Add HTTPS redirect if not exists safely
        cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server { listen 80; server_name $DOMAIN; return 301 https://\$host\$request_uri; }
server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate /etc/nginx/ssl/$DOMAIN.cer;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;
    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;
}
EOF
    fi
    
    systemctl reload nginx
    echo -e "${C_GREEN}✔ Nginx and SSL setup completed for $DOMAIN!${C_RESET}"
    sleep 2
}

# --- Add Reverse Proxy ---
function add_proxy() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET}            ${C_WHITE}Add Reverse Proxy${C_RESET}             ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    read -p "🔹 Enter Domain (e.g., example.com): " DOMAIN
    read -p "🔹 Enter Internal Port (e.g., 8080): " PORT
    echo -e "${C_YELLOW}Tip: Type '/' for Root domain, or type a path like 'panel'${C_RESET}"
    read -p "🔹 Enter Path: " PPATH
    
    if [ ! -d "$NGINX_PROXY_DIR/$DOMAIN" ]; then
        echo -e "${C_YELLOW}Directory missing. Creating it automatically...${C_RESET}"
        mkdir -p "$NGINX_PROXY_DIR/$DOMAIN"
    fi

    PPATH="${PPATH#/}" 
    PPATH="${PPATH%/}" 
    
    if [ -z "$PPATH" ]; then
        # Root Proxy
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
        # Sub-path Proxy with Login Fixes
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

    # --- Login & Redirect Fixes ---
    proxy_redirect / /$PPATH/;
    proxy_cookie_path / /$PPATH/;

    # --- Sub-filter for Hardcoded App Links ---
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
        echo -e "\n${C_GREEN}✔ Success! Access your service at: ${C_WHITE}$SUCCESS_URL${C_RESET}"
    else
        echo -e "${C_RED}✖ Config test failed. Removing invalid config...${C_RESET}"
        rm "$NGINX_PROXY_DIR/$DOMAIN/${PPATH:-root}.conf"
    fi
    sleep 3
}

# --- Remove & List Functions ---
function list_proxies() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET}       ${C_WHITE}List All Configured Proxies${C_RESET}        ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    echo -e "${C_BLUE}❖ Script Managed Proxies:${C_RESET}"
    if [ -d "$NGINX_PROXY_DIR" ]; then
        for domain_path in "$NGINX_PROXY_DIR"/*; do
            if [ -d "$domain_path" ]; then
                DOMAIN=$(basename "$domain_path")
                echo -e " ${C_GREEN}▶ Domain: $DOMAIN${C_RESET}"
                shopt -s nullglob
                CONF_FILES=("$domain_path"/*.conf)
                shopt -u nullglob
                
                if [ ${#CONF_FILES[@]} -eq 0 ]; then
                    echo -e "    ${C_YELLOW}No paths configured inside proxy.d${C_RESET}"
                else
                    for conf_file in "${CONF_FILES[@]}"; do
                        PPATH=$(basename "$conf_file" .conf)
                        PORT=$(grep "proxy_pass" "$conf_file" | sed -E 's/.*:([0-9]+)\/?;/\1/')
                        if [ "$PPATH" == "root" ]; then
                            echo -e "    ├─ Path: ${C_WHITE}/ (Root)${C_RESET} ➔ Port: ${C_CYAN}$PORT${C_RESET}"
                        else
                            echo -e "    ├─ Path: ${C_WHITE}/$PPATH${C_RESET} ➔ Port: ${C_CYAN}$PORT${C_RESET}"
                        fi
                    done
                fi
            fi
        done
    else
        echo -e "  ${C_YELLOW}No auto-ssl proxies found.${C_RESET}"
    fi

    echo -e "\n${C_BLUE}❖ General System Nginx Proxies (Outside script):${C_RESET}"
    grep -Rn "proxy_pass" /etc/nginx/sites-enabled/ 2>/dev/null | awk -F'[/:]' '{print "    ├─ Config: " $5 " ➔ " $NF}' | sed 's/proxy_pass//g; s/;//g' || echo -e "  ${C_YELLOW}None found.${C_RESET}"

    echo ""
    read -p "Press Enter to return to menu..."
}

function remove_proxy() {
    read -p "🔹 Enter Domain (e.g., example.com): " DOMAIN
    read -p "🔹 Enter Path to remove (Type 'root' for main domain proxy): " PPATH
    PPATH="${PPATH#/}"; PPATH="${PPATH%/}"
    [ -z "$PPATH" ] && PPATH="root"
    
    if [ -f "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf" ]; then
        rm "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf"
        nginx -t && systemctl reload nginx
        echo -e "${C_GREEN}✔ Path successfully removed.${C_RESET}"
    else
        echo -e "${C_RED}✖ Path configuration not found!${C_RESET}"
    fi
    sleep 2
}

function uninstall_all() {
    echo -e "\n${C_RED}⚠ WARNING: This will delete Nginx, all SSL certs, and configs!${C_RESET}"
    read -p "Are you sure? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop nginx
        apt purge nginx certbot python3-certbot-nginx -y
        apt autoremove -y
        rm -rf /etc/nginx /var/www/html /etc/letsencrypt ~/.acme.sh /root/.acme.sh
        rm -f "/usr/local/bin/auto-ssl" "/usr/bin/auto-ssl"
        echo -e "${C_GREEN}✔ System cleaned successfully.${C_RESET}"
        exit 0
    fi
}

# --- Main Menu Loop ---
while true; do
    clear
    echo -e "${C_CYAN}"
    echo -e " ╭──────────────────────────────────────────────╮"
    echo -e " │                                              │"
    echo -e " │        ${C_WHITE}✨ AUTO NGINX & SSL MANAGER ✨${C_CYAN}        │"
    echo -e " │            ${C_BLUE}Seamless Reverse Proxy${C_CYAN}            │"
    echo -e " │                                              │"
    echo -e " ╰──────────────────────────────────────────────╯${C_RESET}"
    echo -e "  ${C_CYAN}1${C_RESET} ${C_WHITE}➜${C_RESET} Install Nginx & Get SSL"
    echo -e "  ${C_CYAN}2${C_RESET} ${C_WHITE}➜${C_RESET} Add Reverse Proxy (Port ➔ Path)"
    echo -e "  ${C_CYAN}3${C_RESET} ${C_WHITE}➜${C_RESET} List Configured Ports & Paths"
    echo -e "  ${C_CYAN}4${C_RESET} ${C_WHITE}➜${C_RESET} Remove a Specific Proxy Path"
    echo -e "  ${C_RED}5${C_RESET} ${C_WHITE}➜${C_RESET} Danger: Remove All (Nginx, SSL, Configs)"
    echo -e "  ${C_CYAN}0${C_RESET} ${C_WHITE}➜${C_RESET} Exit"
    echo -e "${C_CYAN} ────────────────────────────────────────────────${C_RESET}"
    read -p "  Select Option: " choice

    case $choice in
        1) install_nginx_ssl ;;
        2) add_proxy ;;
        3) list_proxies ;;
        4) remove_proxy ;;
        5) uninstall_all ;;
        0) clear; exit 0 ;;
        *) echo -e "${C_RED}✖ Invalid option.${C_RESET}"; sleep 1 ;;
    esac
done
