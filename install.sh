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
COMMAND_PATH="/usr/local/bin/black-ssl"

if [[ "$0" != "$COMMAND_PATH" && "$(basename "$0")" != "black-ssl" ]]; then
    echo -e "${C_BLUE}❖ Installing 'black-ssl' as a global command...${C_RESET}"
    
    if ! cp "$0" "$COMMAND_PATH" 2>/dev/null; then
        RAW_URL="https://""raw.githubusercontent.com/saeederamy/black-ssl/refs/heads/main/install.sh"
        curl -Ls "$RAW_URL" -o "$COMMAND_PATH"
    fi
    
    chmod +x "$COMMAND_PATH"
    ln -sf "$COMMAND_PATH" "/usr/bin/black-ssl"
    
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
    
    if ! command -v nginx &> /dev/null; then
        echo -e "${C_BLUE}❖ Installing Nginx...${C_RESET}"
        apt update && apt install nginx curl -y
    else
        echo -e "${C_GREEN}✔ Nginx is already installed.${C_RESET}"
    fi
    
    mkdir -p "$NGINX_PROXY_DIR/$DOMAIN"
    
    SKIP_NGINX_OVERWRITE=0
    if [ -f "/etc/nginx/sites-available/$DOMAIN" ]; then
        echo -e "\n${C_YELLOW}⚠ WARNING: An Nginx configuration for '$DOMAIN' already exists!${C_RESET}"
        read -p "Do you want to OVERWRITE the existing config? (y/N): " overwrite
        if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            SKIP_NGINX_OVERWRITE=1
            echo -e "${C_GREEN}✔ Preserving existing Nginx configuration.${C_RESET}"
        fi
    fi

    if [ $SKIP_NGINX_OVERWRITE -eq 0 ]; then
        read -p "🔹 Enter HTTP Listen Port (Default: 80): " HTTP_PORT
        HTTP_PORT=${HTTP_PORT:-80}
        read -p "🔹 Enter HTTPS Listen Port (Default: 443): " HTTPS_PORT
        HTTPS_PORT=${HTTPS_PORT:-443}

        echo -e "${C_BLUE}❖ Creating new Nginx HTTP block on port $HTTP_PORT...${C_RESET}"
        cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen $HTTP_PORT;
    server_name $DOMAIN;
    client_max_body_size 0;
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
    echo -e "  ${C_CYAN}2)${C_RESET} Acme.sh (Uses ZeroSSL to bypass Let's Encrypt Limits)"
    echo -e "  ${C_CYAN}3)${C_RESET} Manual SSL (Upload your own certs)"
    echo -e "  ${C_CYAN}4)${C_RESET} Skip SSL (HTTP Only)"
    read -p "Choice (1/2/3/4): " ssl_choice

    if [ "$ssl_choice" == "1" ]; then
        echo -e "${C_BLUE}❖ Installing Certbot...${C_RESET}"
        apt install certbot python3-certbot-nginx -y
        if certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email; then
            sed -i '/server_name/a \    client_max_body_size 0;' /etc/nginx/sites-available/$DOMAIN
            echo -e "${C_GREEN}✔ Certbot SSL applied successfully!${C_RESET}"
        else
            echo -e "${C_RED}✖ Certbot failed! Check if your domain points to this server's IP and port 80 is free.${C_RESET}"
        fi
    
    elif [ "$ssl_choice" == "2" ]; then
        echo -e "${C_BLUE}❖ Installing Acme.sh...${C_RESET}"
        ACME_URL="https://""get.acme.sh"
        curl -s "$ACME_URL" | sh
        
        ~/.acme.sh/acme.sh --register-account -m "admin@$DOMAIN" --server zerossl
        ~/.acme.sh/acme.sh --set-default-ca --server zerossl
        
        if ~/.acme.sh/acme.sh --issue -d $DOMAIN --nginx --server zerossl --force; then
            mkdir -p /etc/nginx/ssl
            ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
                --key-file /etc/nginx/ssl/$DOMAIN.key \
                --fullchain-file /etc/nginx/ssl/$DOMAIN.cer
                
            if [[ -f "/etc/nginx/ssl/$DOMAIN.cer" && $SKIP_NGINX_OVERWRITE -eq 0 ]]; then
                cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server { listen $HTTP_PORT; server_name $DOMAIN; return 301 https://\$host\$request_uri; }
server {
    listen $HTTPS_PORT ssl;
    server_name $DOMAIN;
    client_max_body_size 0;
    ssl_certificate /etc/nginx/ssl/$DOMAIN.cer;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;
    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;
}
EOF
                echo -e "${C_GREEN}✔ Acme.sh (ZeroSSL) applied successfully!${C_RESET}"
            elif [ $SKIP_NGINX_OVERWRITE -eq 1 ]; then
                echo -e "${C_YELLOW}✔ Acme.sh generated certs, but Nginx config was NOT overwritten as requested.${C_RESET}"
                echo -e "Cert: /etc/nginx/ssl/$DOMAIN.cer | Key: /etc/nginx/ssl/$DOMAIN.key"
            fi
        else
            echo -e "${C_RED}✖ Acme.sh failed to issue certificate!${C_RESET}"
        fi
    
    elif [ "$ssl_choice" == "3" ]; then
        read -p "Enter path to Certificate (.cer/.crt/.pem): " CERT_PATH
        read -p "Enter path to Private Key (.key): " KEY_PATH

        if [[ -f "$CERT_PATH" && -f "$KEY_PATH" && $SKIP_NGINX_OVERWRITE -eq 0 ]]; then
            cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server { listen $HTTP_PORT; server_name $DOMAIN; return 301 https://\$host\$request_uri; }
server {
    listen $HTTPS_PORT ssl;
    server_name $DOMAIN;
    client_max_body_size 0;
    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;
    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;
    error_page 404 /custom_404.html;
    location = /custom_404.html { return 200 "Secure Server is ready."; add_header Content-Type text/plain; }
}
EOF
            echo -e "${C_GREEN}✔ Custom SSL configured!${C_RESET}"
        fi
    fi
    
    nginx -t && systemctl reload nginx
    echo ""
    read -p "Press Enter to return to menu..."
}

# --- Global Domain & SSL Manager ---
function manage_domains() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET}     ${C_WHITE}Global Domain & SSL Manager${C_RESET}          ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    local domains=()
    echo -e "${C_BLUE}❖ Active Domains (Scanned from ALL Nginx configs):${C_RESET}"
    
    # Advanced Scan: Find all server_names in Nginx
    for d in $(grep -hRoP 'server_name\s+\K[a-zA-Z0-9.-]+' /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | tr -d ';' | sort -u); do
        if [[ "$d" != "_" && "$d" != "localhost" ]]; then
            domains+=("$d")
            echo -e "  ${C_GREEN}▶ $d${C_RESET}"
        fi
    done

    if [ ${#domains[@]} -eq 0 ]; then
        echo -e "  ${C_YELLOW}No domains configured on this server yet.${C_RESET}"; echo ""; read -p "Press Enter..." ; return
    fi
    
    echo -e "${C_CYAN}────────────────────────────────────────────${C_RESET}"
    read -p "🔹 Enter a Domain to manage: " DOMAIN
    
    if [[ ! " ${domains[*]} " =~ " ${DOMAIN} " ]]; then
        echo -e "${C_RED}✖ Domain not found in Nginx configs!${C_RESET}"; echo ""; read -p "Press Enter..." ; return
    fi
    
    # Find exact config file for this domain
    CONF_FILE=$(grep -RlP "server_name\s+.*$DOMAIN" /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | head -n 1)
    
    echo -e "\n${C_WHITE}What do you want to do with $DOMAIN?${C_RESET}"
    echo -e "  ${C_CYAN}1)${C_RESET} Check SSL Status & View Paths"
    echo -e "  ${C_YELLOW}2)${C_RESET} Remove SSL Only (Downgrade to HTTP)"
    echo -e "  ${C_RED}3)${C_RESET} Completely Delete Domain Config (Destructive)"
    echo -e "  ${C_CYAN}0)${C_RESET} Back to Menu"
    read -p "Choice: " action
    
    if [ "$action" == "1" ]; then
        echo -e "\n${C_BLUE}❖ Scanning SSL Status for $DOMAIN...${C_RESET}"
        echo -e "${C_WHITE}Nginx Config File:${C_RESET} $CONF_FILE"
        
        cert_path=$(grep -m 1 "ssl_certificate " "$CONF_FILE" | awk '{print $2}' | tr -d ';')
        key_path=$(grep -m 1 "ssl_certificate_key " "$CONF_FILE" | awk '{print $2}' | tr -d ';')
        
        if [[ -n "$cert_path" && -f "$cert_path" ]]; then
             echo -e "${C_GREEN}✔ SSL Detected in Config!${C_RESET}"
             echo -e "${C_WHITE}Certificate Path:${C_RESET} $cert_path"
             echo -e "${C_WHITE}Private Key Path:${C_RESET} $key_path"
             echo -e "${C_YELLOW}Expiration Details:${C_RESET}"
             openssl x509 -enddate -noout -in "$cert_path"
        else
             echo -e "${C_YELLOW}⚠ No active SSL certificate found in the Nginx configuration for $DOMAIN.${C_RESET}"
        fi
        
    elif [ "$action" == "2" ]; then
        read -p "Downgrade $DOMAIN to HTTP and remove SSL settings? (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            echo -e "${C_BLUE}❖ Removing SSL configurations and files...${C_RESET}"
            
            EXTRACTED_PORT=$(grep -m 1 -E 'listen [0-9]+;' "$CONF_FILE" | grep -v 'ssl' | awk '{print $2}' | tr -d ';' || echo 80)
            
            if command -v certbot &> /dev/null; then certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null; fi
            if [ -f ~/.acme.sh/acme.sh ]; then ~/.acme.sh/acme.sh --remove -d "$DOMAIN" 2>/dev/null; rm -rf "/etc/nginx/ssl/$DOMAIN"* 2>/dev/null; fi
            
            # Create a clean HTTP-only block
            cat > "$CONF_FILE" <<EOF
server {
    listen $EXTRACTED_PORT;
    server_name $DOMAIN;
    client_max_body_size 0;
    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;
    
    error_page 404 /custom_404.html;
    location = /custom_404.html {
        return 200 "Server is ready. Please add a proxy path.";
        add_header Content-Type text/plain;
    }
}
EOF
            nginx -t && systemctl reload nginx
            echo -e "${C_GREEN}✔ SSL removed successfully. Domain $DOMAIN is now HTTP-only!${C_RESET}"
        fi
        
    elif [ "$action" == "3" ]; then
        read -p "⚠ DESTRUCTIVE: Delete Nginx config file ($CONF_FILE) and SSLs for $DOMAIN? (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            echo -e "${C_BLUE}❖ Removing Nginx configs...${C_RESET}"
            rm -f "$CONF_FILE"
            rm -f "/etc/nginx/sites-available/$DOMAIN"
            rm -rf "/etc/nginx/proxy.d/$DOMAIN"
            
            if command -v certbot &> /dev/null; then certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null; fi
            if [ -f ~/.acme.sh/acme.sh ]; then ~/.acme.sh/acme.sh --remove -d "$DOMAIN" 2>/dev/null; rm -rf "/etc/nginx/ssl/$DOMAIN"* 2>/dev/null; fi
            
            systemctl reload nginx
            echo -e "${C_GREEN}✔ Domain $DOMAIN successfully removed from server!${C_RESET}"
        fi
    fi
    echo ""; read -p "Press Enter to return to menu..."
}

# --- Add Reverse Proxy ---
function add_proxy() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET}            ${C_WHITE}Add Reverse Proxy${C_RESET}             ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    read -p "🔹 Enter Domain (e.g., example.com): " DOMAIN
    read -p "🔹 Enter Internal App Port (e.g., 8080): " PORT
    echo -e "${C_YELLOW}Tip: For 100% bug-free apps, type '/' (Root). Sub-paths like 'panel' may break complex apps.${C_RESET}"
    read -p "🔹 Enter Path: " PPATH
    
    mkdir -p "$NGINX_PROXY_DIR/$DOMAIN"
    PPATH="${PPATH#/}"; PPATH="${PPATH%/}" 
    
    if [ -z "$PPATH" ]; then
        cat > "$NGINX_PROXY_DIR/$DOMAIN/root.conf" <<EOF
location / {
    client_max_body_size 0;
    proxy_pass http://127.0.0.1:$PORT;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}
EOF
    else
        cat > "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf" <<EOF
location /$PPATH/ {
    client_max_body_size 0;
    proxy_pass http://127.0.0.1:$PORT/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Prefix /$PPATH;

    proxy_redirect / /$PPATH/;
    proxy_cookie_path / /$PPATH/;

    # Standard safe HTML rewrites only
    proxy_set_header Accept-Encoding "";
    sub_filter '<head>' '<head><base href="/$PPATH/">';
    sub_filter 'src="/' 'src="/$PPATH/';
    sub_filter 'href="/' 'href="/$PPATH/';
    sub_filter_once off;
    sub_filter_types text/html text/css application/javascript;
}
EOF
        echo -e "\n${C_YELLOW}⚠ If your app has broken links or fails to upload on /$PPATH/, it means your app requires running on the ROOT path (/). Remove this path and add it as '/' instead!${C_RESET}"
    fi
    
    if nginx -t; then
        systemctl reload nginx
        echo -e "\n${C_GREEN}✔ Success!${C_RESET}"
    else
        rm -f "$NGINX_PROXY_DIR/$DOMAIN/${PPATH:-root}.conf"
    fi
    echo ""; read -p "Press Enter..."
}

# --- List Proxies ---
function list_proxies() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET}       ${C_WHITE}List All Configured Proxies${C_RESET}        ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    echo -e "\n${C_BLUE}❖ Script Managed Proxies (proxy.d):${C_RESET}"
    if [ -d "$NGINX_PROXY_DIR" ]; then
        for domain_path in "$NGINX_PROXY_DIR"/*; do
            DOMAIN=$(basename "$domain_path")
            echo -e " ${C_GREEN}▶ $DOMAIN${C_RESET}"
            for conf_file in "$domain_path"/*.conf; do
                [ -e "$conf_file" ] || continue
                PPATH=$(basename "$conf_file" .conf)
                PORT=$(grep "proxy_pass" "$conf_file" | sed -E 's/.*:([0-9]+)\/?;/\1/')
                if [ "$PPATH" == "root" ]; then echo -e "    ├─ Path: / ➔ Port: $PORT"
                else echo -e "    ├─ Path: /$PPATH ➔ Port: $PORT"
                fi
            done
        done
    fi

    echo -e "\n${C_BLUE}❖ Externally Managed Proxies (Found in Nginx Configs):${C_RESET}"
    EXTERNAL_PROXIES=$(grep -RnE "^\s*proxy_pass" /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | grep -v "$NGINX_PROXY_DIR")
    if [ -n "$EXTERNAL_PROXIES" ]; then
        echo "$EXTERNAL_PROXIES" | awk -F':' '{print "  ├─ File: " $1 " ➔ " $3":"$4}' | sed 's/;//g'
    else
        echo -e "  ${C_YELLOW}No external proxies found.${C_RESET}"
    fi

    echo ""; read -p "Press Enter..."
}

# --- Remove Path ---
function remove_proxy() {
    read -p "🔹 Enter Domain: " DOMAIN
    read -p "🔹 Enter Path to remove (Type 'root' for main proxy): " PPATH
    PPATH="${PPATH#/}"; PPATH="${PPATH%/}"; [ -z "$PPATH" ] && PPATH="root"
    if [ -f "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf" ]; then
        rm "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf"
        systemctl reload nginx; echo -e "${C_GREEN}✔ Removed.${C_RESET}"
    else
        echo -e "${C_RED}✖ Path configuration not found!${C_RESET}"
    fi
    echo ""; read -p "Press Enter..."
}

# --- Deep Clean ---
function uninstall_all() {
    read -p "⚠ DESTRUCTIVE: Purge Nginx, SSL, and all Configs from Server? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop nginx 2>/dev/null; killall -9 nginx 2>/dev/null
        apt-get purge nginx nginx-common nginx-core certbot python3-certbot-nginx -y; apt-get autoremove -y
        rm -rf /etc/nginx /var/www/html /etc/letsencrypt ~/.acme.sh /root/.acme.sh /usr/local/bin/black-ssl /usr/bin/black-ssl
        echo -e "${C_GREEN}✔ System fully cleaned.${C_RESET}"; exit 0
    fi
}

while true; do
    clear
    echo -e "${C_CYAN} ╭──────────────────────────────────────────────╮"
    echo -e " │        ${C_WHITE}✨ BLACK SSL MANAGER ✨${C_CYAN}               │"
    echo -e " ╰──────────────────────────────────────────────╯${C_RESET}"
    echo -e "  1 ➜ Install Nginx & Setup Domain"
    echo -e "  2 ➜ Add Reverse Proxy (Port ➔ Path)"
    echo -e "  3 ➜ Global Domain & SSL Manager (Scan/Check/Remove)"
    echo -e "  4 ➜ List All Proxies (Internal & External)"
    echo -e "  5 ➜ Remove a Specific Proxy Path"
    echo -e "  6 ➜ Danger: Deep Remove All"
    echo -e "  0 ➜ Exit"
    read -p "  Select Option: " choice
    case $choice in
        1) install_nginx_ssl ;; 2) add_proxy ;; 3) manage_domains ;; 4) list_proxies ;; 5) remove_proxy ;; 6) uninstall_all ;; 0) clear; exit 0 ;;
    esac
done
