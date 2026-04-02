#!/bin/bash

# --- Fix Terminal Backspace Issue ---
stty erase '^H' 2>/dev/null

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
COMMAND_PATH="/usr/local/bin/auto-ssl"

if [[ "$0" != "$COMMAND_PATH" && "$(basename "$0")" != "auto-ssl" ]]; then
    echo -e "${C_BLUE}❖ Installing 'auto-ssl' as a global command...${C_RESET}"
    
    if ! cp "$0" "$COMMAND_PATH" 2>/dev/null; then
        curl -Ls "[https://raw.githubusercontent.com/saeederamy/Auto-SSL-Nginx/refs/heads/main/install.sh](https://raw.githubusercontent.com/saeederamy/Auto-SSL-Nginx/refs/heads/main/install.sh)" -o "$COMMAND_PATH"
    fi
    
    chmod +x "$COMMAND_PATH"
    ln -sf "$COMMAND_PATH" "/usr/bin/auto-ssl"
    
    echo -e "${C_GREEN}✔ Installed! Launching the panel...${C_RESET}"
    sleep 1
    exec "$COMMAND_PATH" "$@"
fi

NGINX_PROXY_DIR="/etc/nginx/proxy.d"

# --- Install Nginx & SSL ---
function install_nginx_ssl() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET}         ${C_WHITE}Nginx & SSL Configuration${C_RESET}        ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    read -p "🔹 Enter Domain (e.g., example.com): " DOMAIN
    
    read -p "🔹 Enter HTTP Listen Port (Default: 80): " HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-80}
    
    read -p "🔹 Enter HTTPS Listen Port (Default: 443): " HTTPS_PORT
    HTTPS_PORT=${HTTPS_PORT:-443}
    
    if ! command -v nginx &> /dev/null; then
        echo -e "${C_BLUE}❖ Installing Nginx...${C_RESET}"
        apt update && apt install nginx curl -y
    else
        echo -e "${C_GREEN}✔ Nginx is already installed.${C_RESET}"
    fi
    
    mkdir -p "$NGINX_PROXY_DIR/$DOMAIN"
    
    # Setup base HTTP config
    if [ ! -f "/etc/nginx/sites-available/$DOMAIN" ]; then
        echo -e "${C_BLUE}❖ Creating new Nginx HTTP block on port $HTTP_PORT...${C_RESET}"
        cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen $HTTP_PORT;
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
    fi
    
    systemctl restart nginx

    echo -e "\n${C_WHITE}Choose SSL Provider:${C_RESET}"
    echo -e "  ${C_CYAN}1)${C_RESET} Certbot (Recommended - *Requires port 80 to be open*)"
    echo -e "  ${C_CYAN}2)${C_RESET} Acme.sh (Good for strict limits)"
    echo -e "  ${C_CYAN}3)${C_RESET} Manual SSL (Upload your own certs)"
    echo -e "  ${C_CYAN}4)${C_RESET} Skip SSL (HTTP Only)"
    read -p "Choice (1/2/3/4): " ssl_choice

    if [ "$ssl_choice" == "1" ]; then
        echo -e "${C_BLUE}❖ Installing Certbot...${C_RESET}"
        apt install certbot python3-certbot-nginx -y
        if certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email; then
            echo -e "${C_GREEN}✔ Certbot SSL applied successfully!${C_RESET}"
        else
            echo -e "${C_RED}✖ Certbot failed! Check if your domain points to this server's IP and port 80 is free.${C_RESET}"
        fi
    
    elif [ "$ssl_choice" == "2" ]; then
        echo -e "${C_BLUE}❖ Installing Acme.sh...${C_RESET}"
        curl [https://get.acme.sh](https://get.acme.sh) | sh
        source ~/.bashrc
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        
        if ~/.acme.sh/acme.sh --issue -d $DOMAIN --nginx; then
            mkdir -p /etc/nginx/ssl
            ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
                --key-file /etc/nginx/ssl/$DOMAIN.key \
                --fullchain-file /etc/nginx/ssl/$DOMAIN.cer
                
            if [[ -f "/etc/nginx/ssl/$DOMAIN.cer" ]]; then
                cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server { listen $HTTP_PORT; server_name $DOMAIN; return 301 https://\$host\$request_uri; }
server {
    listen $HTTPS_PORT ssl;
    server_name $DOMAIN;
    ssl_certificate /etc/nginx/ssl/$DOMAIN.cer;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;
    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;
}
EOF
                echo -e "${C_GREEN}✔ Acme.sh SSL applied successfully!${C_RESET}"
            else
                echo -e "${C_RED}✖ Acme.sh succeeded but cert files missing.${C_RESET}"
            fi
        else
            echo -e "${C_RED}✖ Acme.sh failed to issue certificate!${C_RESET}"
        fi
    
    elif [ "$ssl_choice" == "3" ]; then
        echo -e "\n${C_BLUE}❖ Manual SSL Configuration${C_RESET}"
        read -p "Enter path to Certificate (.cer/.crt/.pem): " CERT_PATH
        read -p "Enter path to Private Key (.key): " KEY_PATH

        if [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]]; then
            cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server { listen $HTTP_PORT; server_name $DOMAIN; return 301 https://\$host\$request_uri; }
server {
    listen $HTTPS_PORT ssl;
    server_name $DOMAIN;
    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;
    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;
    
    error_page 404 /custom_404.html;
    location = /custom_404.html { return 200 "Secure Server is ready."; add_header Content-Type text/plain; }
}
EOF
            echo -e "${C_GREEN}✔ Custom SSL configured for $DOMAIN!${C_RESET}"
        else
            echo -e "${C_RED}✖ Error: One or both files not found. Setup aborted.${C_RESET}"
            sleep 2
            return
        fi
    fi
    
    nginx -t && systemctl reload nginx
    sleep 2
}

# --- Domain & SSL Manager ---
function manage_domains() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET}         ${C_WHITE}Domain & SSL Manager${C_RESET}             ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    local domains=()
    echo -e "${C_BLUE}❖ Configured Domains:${C_RESET}"
    if [ -d "/etc/nginx/sites-available" ]; then
        for d in /etc/nginx/sites-available/*; do
            if [[ -f "$d" && "$(basename "$d")" != "default" ]]; then
                domains+=("$(basename "$d")")
                echo -e "  ${C_GREEN}▶ $(basename "$d")${C_RESET}"
            fi
        done
    fi
    
    if [ ${#domains[@]} -eq 0 ]; then
        echo -e "  ${C_YELLOW}No domains configured yet.${C_RESET}"
        sleep 2
        return
    fi
    
    echo -e "${C_CYAN}────────────────────────────────────────────${C_RESET}"
    read -p "🔹 Enter a Domain from the list: " DOMAIN
    
    if [[ ! " ${domains[*]} " =~ " ${DOMAIN} " ]]; then
        echo -e "${C_RED}✖ Domain not found in the list!${C_RESET}"
        sleep 2
        return
    fi
    
    echo -e "\n${C_WHITE}What do you want to do with $DOMAIN?${C_RESET}"
    echo -e "  ${C_CYAN}1)${C_RESET} Check SSL Expiration Date"
    echo -e "  ${C_RED}2)${C_RESET} Completely Delete Domain & SSL (from Nginx)"
    echo -e "  ${C_CYAN}0)${C_RESET} Back to Menu"
    read -p "Choice: " action
    
    if [ "$action" == "1" ]; then
        echo -e "\n${C_BLUE}❖ Checking SSL Status for $DOMAIN...${C_RESET}"
        if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
            echo -e "${C_GREEN}SSL Type: Certbot${C_RESET}"
            openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        elif [ -f "/etc/nginx/ssl/$DOMAIN.cer" ]; then
            echo -e "${C_GREEN}SSL Type: Acme.sh${C_RESET}"
            openssl x509 -enddate -noout -in "/etc/nginx/ssl/$DOMAIN.cer"
        else
            cert_path=$(grep -m 1 "ssl_certificate " "/etc/nginx/sites-available/$DOMAIN" | awk '{print $2}' | tr -d ';')
            if [[ -n "$cert_path" && -f "$cert_path" ]]; then
                 echo -e "${C_GREEN}SSL Type: Custom/Manual${C_RESET}"
                 openssl x509 -enddate -noout -in "$cert_path"
            else
                 echo -e "${C_YELLOW}No valid SSL certificate found in standard paths for $DOMAIN.${C_RESET}"
            fi
        fi
        read -p "Press Enter to continue..."
        
    elif [ "$action" == "2" ]; then
        read -p "Are you sure you want to delete ALL Nginx and SSL configs for $DOMAIN? (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            echo -e "${C_BLUE}❖ Removing Nginx configs...${C_RESET}"
            rm -f "/etc/nginx/sites-available/$DOMAIN"
            rm -f "/etc/nginx/sites-enabled/$DOMAIN"
            rm -rf "/etc/nginx/proxy.d/$DOMAIN"
            
            if command -v certbot &> /dev/null; then
                certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null
            fi
            
            if [ -f ~/.acme.sh/acme.sh ]; then
                ~/.acme.sh/acme.sh --remove -d "$DOMAIN" 2>/dev/null
                rm -rf "/etc/nginx/ssl/$DOMAIN"* 2>/dev/null
            fi
            
            nginx -t && systemctl reload nginx
            echo -e "${C_GREEN}✔ Domain $DOMAIN successfully removed!${C_RESET}"
            sleep 2
        fi
    fi
}

# --- Add Reverse Proxy ---
function add_proxy() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET}            ${C_WHITE}Add Reverse Proxy${C_RESET}             ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    echo -e "${C_BLUE}❖ Configured Domains:${C_RESET}"
    local found_domains=0
    if [ -d "$NGINX_PROXY_DIR" ]; then
        for d in "$NGINX_PROXY_DIR"/*; do
            if [ -d "$d" ]; then
                echo -e "  ${C_GREEN}✔ $(basename "$d")${C_RESET}"
                found_domains=1
            fi
        done
    fi
    if [ $found_domains -eq 0 ]; then
        echo -e "  ${C_YELLOW}No domains configured yet. Install Nginx & Setup Domain first.${C_RESET}"
    fi
    echo -e "${C_CYAN}────────────────────────────────────────────${C_RESET}"

    read -p "🔹 Enter Domain (e.g., example.com): " DOMAIN
    read -p "🔹 Enter Internal App Port (e.g., 8080): " PORT
    echo -e "${C_YELLOW}Tip: Type '/' for Root domain, or type a path like 'panel'${C_RESET}"
    read -p "🔹 Enter Path: " PPATH
    
    if [ ! -d "$NGINX_PROXY_DIR/$DOMAIN" ]; then
        mkdir -p "$NGINX_PROXY_DIR/$DOMAIN"
    fi

    PPATH="${PPATH#/}" 
    PPATH="${PPATH%/}" 
    
    if [ -z "$PPATH" ]; then
        # Root Proxy
        cat > "$NGINX_PROXY_DIR/$DOMAIN/root.conf" <<EOF
location / {
    proxy_pass [http://127.0.0.1](http://127.0.0.1):$PORT;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
}
EOF
        SUCCESS_URL="http(s)://$DOMAIN/"
    else
        echo -e "\n${C_WHITE}What type of application is this?${C_RESET}"
        echo -e "  ${C_CYAN}1)${C_RESET} Black Hub / Custom Python App (Forces Nginx URL rewriting)"
        echo -e "  ${C_CYAN}2)${C_RESET} X-UI Panel (Direct Pass - *Requires setting Base Path in X-UI*)"
        read -p "Choice (1 or 2): " app_type

        if [ "$app_type" == "1" ]; then
            cat > "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf" <<EOF
location /$PPATH/ {
    proxy_pass [http://127.0.0.1](http://127.0.0.1):$PORT/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # --- Backend Framework Support (Python FastAPI, Flask, etc.) ---
    proxy_set_header X-Forwarded-Prefix /$PPATH;
    proxy_set_header X-Script-Name /$PPATH;

    proxy_redirect / /$PPATH/;
    proxy_cookie_path / /$PPATH/;

    # --- Aggressive HTML/JS Sub-filter ---
    proxy_set_header Accept-Encoding "";
    sub_filter 'src="/' 'src="/$PPATH/';
    sub_filter 'href="/' 'href="/$PPATH/';
    sub_filter 'action="/' 'action="/$PPATH/';
    sub_filter 'url("/' 'url("/$PPATH/';
    
    # Common API calls in JS
    sub_filter 'fetch("/' 'fetch("/$PPATH/';
    sub_filter 'axios.get("/' 'axios.get("/$PPATH/';
    sub_filter 'axios.post("/' 'axios.post("/$PPATH/';
    sub_filter 'axios.put("/' 'axios.put("/$PPATH/';
    sub_filter 'axios.delete("/' 'axios.delete("/$PPATH/';
    sub_filter 'axios("/' 'axios("/$PPATH/';
    
    sub_filter_once off;
    sub_filter_types text/html text/css text/javascript application/javascript application/json;
}
EOF
        else
            cat > "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf" <<EOF
location /$PPATH/ {
    proxy_pass [http://127.0.0.1](http://127.0.0.1):$PORT;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}
EOF
            echo -e "\n${C_YELLOW}⚠ IMPORTANT: For X-UI to work on /$PPATH/, you MUST log in via IP:PORT first and set 'Panel url root path' to '/$PPATH/' in the X-UI settings!${C_RESET}"
            sleep 4
        fi
        SUCCESS_URL="http(s)://$DOMAIN/$PPATH/"
    fi
    
    echo -e "${C_BLUE}❖ Testing Nginx Configuration...${C_RESET}"
    if nginx -t; then
        systemctl reload nginx
        echo -e "\n${C_GREEN}✔ Success! Access your service at: ${C_WHITE}$SUCCESS_URL${C_RESET}"
    else
        echo -e "${C_RED}✖ Nginx test failed! (See error above)${C_RESET}"
        echo -e "${C_YELLOW}Removing the invalid proxy config to prevent Nginx crash...${C_RESET}"
        rm -f "$NGINX_PROXY_DIR/$DOMAIN/${PPATH:-root}.conf"
    fi
    sleep 4
}

# --- List Proxies ---
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
                            echo -e "    ├─ Path: ${C_WHITE}/ (Root)${C_RESET} ➔ Upstream Port: ${C_CYAN}$PORT${C_RESET}"
                        else
                            echo -e "    ├─ Path: ${C_WHITE}/$PPATH${C_RESET} ➔ Upstream Port: ${C_CYAN}$PORT${C_RESET}"
                        fi
                    done
                fi
            fi
        done
    else
        echo -e "  ${C_YELLOW}No auto-ssl proxies found.${C_RESET}"
    fi

    echo ""
    read -p "Press Enter to return to menu..."
}

# --- Remove Path ---
function remove_proxy() {
    read -p "🔹 Enter Domain (e.g., example.com): " DOMAIN
    read -p "🔹 Enter Path to remove (Type 'root' for main proxy): " PPATH
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

# --- Deep Clean ---
function uninstall_all() {
    echo -e "\n${C_RED}⚠ WARNING: This will DEEP CLEAN Nginx, all SSL certs, and configs!${C_RESET}"
    read -p "Are you sure? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo -e "${C_BLUE}❖ Stopping services...${C_RESET}"
        systemctl stop nginx 2>/dev/null
        killall -9 nginx 2>/dev/null
        
        echo -e "${C_BLUE}❖ Purging packages...${C_RESET}"
        apt-get purge nginx nginx-common nginx-core certbot python3-certbot-nginx -y
        apt-get autoremove -y
        
        echo -e "${C_BLUE}❖ Removing remaining files...${C_RESET}"
        rm -rf /etc/nginx /var/www/html /etc/letsencrypt ~/.acme.sh /root/.acme.sh /var/lib/letsencrypt /var/log/letsencrypt
        rm -f "/usr/local/bin/auto-ssl" "/usr/bin/auto-ssl"
        
        echo -e "${C_GREEN}✔ System cleaned successfully. You can now start fresh.${C_RESET}"
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
    echo -e "  ${C_CYAN}1${C_RESET} ${C_WHITE}➜${C_RESET} Install Nginx & Setup Domain (SSL/Ports)"
    echo -e "  ${C_CYAN}2${C_RESET} ${C_WHITE}➜${C_RESET} Add Reverse Proxy (Port ➔ Path)"
    echo -e "  ${C_YELLOW}3${C_RESET} ${C_WHITE}➜${C_RESET} Manage Domains & SSL (Check/Remove)"
    echo -e "  ${C_CYAN}4${C_RESET} ${C_WHITE}➜${C_RESET} List Configured Proxies"
    echo -e "  ${C_CYAN}5${C_RESET} ${C_WHITE}➜${C_RESET} Remove a Specific Proxy Path"
    echo -e "  ${C_RED}6${C_RESET} ${C_WHITE}➜${C_RESET} Danger: Deep Remove All (Nginx, SSL, Configs)"
    echo -e "  ${C_CYAN}0${C_RESET} ${C_WHITE}➜${C_RESET} Exit"
    echo -e "${C_CYAN} ────────────────────────────────────────────────${C_RESET}"
    read -p "  Select Option: " choice

    case $choice in
        1) install_nginx_ssl ;;
        2) add_proxy ;;
        3) manage_domains ;;
        4) list_proxies ;;
        5) remove_proxy ;;
        6) uninstall_all ;;
        0) clear; exit 0 ;;
        *) echo -e "${C_RED}✖ Invalid option.${C_RESET}"; sleep 1 ;;
    esac
done
