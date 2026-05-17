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

# ====================================================================
# HELPER FUNCTIONS
# ====================================================================

# Get all configured domains (from proxy.d AND from nginx configs)
# Returns space-separated list in stdout
function get_all_domains() {
    local domains=()
    # From proxy.d
    if [ -d "$NGINX_PROXY_DIR" ]; then
        for d in "$NGINX_PROXY_DIR"/*; do
            [ -d "$d" ] && domains+=("$(basename "$d")")
        done
    fi
    # From nginx configs (catch domains added externally)
    for d in $(grep -hRoP 'server_name\s+\K[a-zA-Z0-9.-]+' /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | tr -d ';' | sort -u); do
        if [[ "$d" != "_" && "$d" != "localhost" ]]; then
            # Avoid duplicates
            local exists=0
            for existing in "${domains[@]}"; do
                [ "$existing" = "$d" ] && exists=1 && break
            done
            [ $exists -eq 0 ] && domains+=("$d")
        fi
    done
    echo "${domains[@]}"
}

# Show a numbered menu of domains, let user pick one.
# Sets the global variable SELECTED_DOMAIN.
# Returns 1 if no domains or user cancels.
function pick_domain() {
    SELECTED_DOMAIN=""
    local domains_str
    domains_str=$(get_all_domains)
    
    if [ -z "$domains_str" ]; then
        echo -e "${C_YELLOW}⚠ No domains configured yet. Please add one first via option 1.${C_RESET}"
        return 1
    fi
    
    # Convert to array
    local domains=()
    read -ra domains <<< "$domains_str"
    
    echo -e "\n${C_BLUE}❖ Available Domains:${C_RESET}"
    local i=1
    for d in "${domains[@]}"; do
        echo -e "  ${C_CYAN}$i)${C_RESET} $d"
        i=$((i+1))
    done
    echo -e "  ${C_CYAN}0)${C_RESET} Cancel / Enter manually"
    
    read -ep "🔹 Select domain by number (or 0 to type manually): " choice
    
    if [[ "$choice" == "0" || -z "$choice" ]]; then
        read -ep "🔹 Enter Domain manually: " SELECTED_DOMAIN
        [ -z "$SELECTED_DOMAIN" ] && return 1
        return 0
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#domains[@]}" ]; then
        SELECTED_DOMAIN="${domains[$((choice-1))]}"
        echo -e "${C_GREEN}✔ Selected: $SELECTED_DOMAIN${C_RESET}"
        return 0
    fi
    
    echo -e "${C_RED}✖ Invalid selection.${C_RESET}"
    return 1
}

# Show numbered menu of paths under a domain. Sets SELECTED_PATH.
function pick_path() {
    SELECTED_PATH=""
    local domain="$1"
    local domain_dir="$NGINX_PROXY_DIR/$domain"
    
    if [ ! -d "$domain_dir" ]; then
        echo -e "${C_YELLOW}⚠ No paths configured for $domain.${C_RESET}"
        return 1
    fi
    
    local paths=()
    for conf in "$domain_dir"/*.conf; do
        [ -f "$conf" ] && paths+=("$(basename "$conf" .conf)")
    done
    
    if [ ${#paths[@]} -eq 0 ]; then
        echo -e "${C_YELLOW}⚠ No paths configured for $domain.${C_RESET}"
        return 1
    fi
    
    echo -e "\n${C_BLUE}❖ Paths configured for $domain:${C_RESET}"
    local i=1
    for p in "${paths[@]}"; do
        local port
        port=$(grep "proxy_pass" "$domain_dir/$p.conf" 2>/dev/null | sed -E 's/.*:([0-9]+)\/?;/\1/')
        local display="$p"
        [ "$p" = "root" ] && display="/ (root)"
        echo -e "  ${C_CYAN}$i)${C_RESET} $display ➔ port $port"
        i=$((i+1))
    done
    echo -e "  ${C_CYAN}0)${C_RESET} Cancel / Enter manually"
    
    read -ep "🔹 Select path by number: " choice
    
    if [[ "$choice" == "0" || -z "$choice" ]]; then
        read -ep "🔹 Enter Path manually (or 'root'): " SELECTED_PATH
        [ -z "$SELECTED_PATH" ] && return 1
        return 0
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#paths[@]}" ]; then
        SELECTED_PATH="${paths[$((choice-1))]}"
        echo -e "${C_GREEN}✔ Selected: $SELECTED_PATH${C_RESET}"
        return 0
    fi
    
    echo -e "${C_RED}✖ Invalid selection.${C_RESET}"
    return 1
}

# Get Nginx service status (returns "active", "inactive", "failed", or "not-installed")
function nginx_status() {
    if ! command -v nginx &>/dev/null; then
        echo "not-installed"
        return
    fi
    systemctl is-active nginx 2>/dev/null || echo "inactive"
}

# Show colored status for menu display
function nginx_status_display() {
    local s
    s=$(nginx_status)
    case "$s" in
        active)        echo -e "${C_GREEN}● running${C_RESET}" ;;
        inactive)      echo -e "${C_YELLOW}● stopped${C_RESET}" ;;
        failed)        echo -e "${C_RED}● FAILED${C_RESET}" ;;
        not-installed) echo -e "${C_RED}● not installed${C_RESET}" ;;
        *)             echo -e "${C_YELLOW}● $s${C_RESET}" ;;
    esac
}

# De-duplicate client_max_body_size in a file
function dedupe_client_max_body_size() {
    local file="$1"
    [ ! -f "$file" ] && return 1
    awk '
        /^[[:space:]]*server[[:space:]]*\{/ { in_block=1; seen=0; print; next }
        /^[[:space:]]*\}/                   { in_block=0; seen=0; print; next }
        {
            stripped=$0
            gsub(/^[ \t]+|[ \t]+$/, "", stripped)
            if (in_block && stripped ~ /^client_max_body_size 0;$/) {
                if (seen) next
                seen=1
            }
            print
        }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

function inject_directive_once() {
    local file="$1"
    [ ! -f "$file" ] && return 1
    if grep -qF "client_max_body_size 0;" "$file"; then
        return 0
    fi
    sed -i '/server_name/a \    client_max_body_size 0;' "$file"
}

# Try to reload nginx. If it fails, show the error and offer to revert a file.
# Args: $1 = the file we just modified (will be removed on failure if $2=revert)
# Returns 0 on success, 1 on failure.
function nginx_safe_reload() {
    local revert_file="$1"
    local mode="${2:-revert}"   # revert | keep
    
    if nginx -t 2>/tmp/nginx_test_err; then
        systemctl reload nginx
        return 0
    fi
    
    echo -e "\n${C_RED}✖ Nginx test FAILED!${C_RESET}"
    echo -e "${C_YELLOW}Error output:${C_RESET}"
    cat /tmp/nginx_test_err
    echo ""
    
    if [ -n "$revert_file" ] && [ -f "$revert_file" ] && [ "$mode" = "revert" ]; then
        echo -e "${C_BLUE}❖ Auto-reverting the change: $revert_file${C_RESET}"
        rm -f "$revert_file"
        if nginx -t 2>/dev/null; then
            systemctl reload nginx
            echo -e "${C_GREEN}✔ Reverted. Nginx is OK again.${C_RESET}"
        else
            echo -e "${C_RED}✖ Still broken after revert. Try option 7 (Fix Nginx).${C_RESET}"
        fi
    else
        echo -e "${C_YELLOW}⚠ Try option 7 (Fix Nginx) to attempt auto-repair.${C_RESET}"
    fi
    return 1
}

# ====================================================================
# Install Nginx & SSL
# ====================================================================
function install_nginx_ssl() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_WHITE}Nginx & SSL Configuration${C_RESET} ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    read -ep "🔹 Enter Domain (e.g., example.com): " DOMAIN
    [ -z "$DOMAIN" ] && { echo -e "${C_RED}✖ Empty domain.${C_RESET}"; return; }
    
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
        read -ep "Do you want to OVERWRITE the existing config? (y/N): " overwrite
        if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            SKIP_NGINX_OVERWRITE=1
            echo -e "${C_GREEN}✔ Preserving existing Nginx configuration.${C_RESET}"
        fi
    fi
    if [ $SKIP_NGINX_OVERWRITE -eq 0 ]; then
        read -ep "🔹 Enter HTTP Listen Port (Default: 80): " HTTP_PORT
        HTTP_PORT=${HTTP_PORT:-80}
        read -ep "🔹 Enter HTTPS Listen Port (Default: 443): " HTTPS_PORT
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
    echo -e " ${C_CYAN}1)${C_RESET} Certbot (Recommended - *Requires port 80 to be open*)"
    echo -e " ${C_CYAN}2)${C_RESET} Acme.sh (Uses ZeroSSL to bypass Let's Encrypt Limits)"
    echo -e " ${C_CYAN}3)${C_RESET} Manual SSL (Upload your own certs)"
    echo -e " ${C_CYAN}4)${C_RESET} Skip SSL (HTTP Only)"
    read -ep "Choice (1/2/3/4): " ssl_choice
    if [ "$ssl_choice" == "1" ]; then
        echo -e "${C_BLUE}❖ Installing Certbot...${C_RESET}"
        apt install certbot python3-certbot-nginx -y
        if certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email; then
            inject_directive_once "/etc/nginx/sites-available/$DOMAIN"
            dedupe_client_max_body_size "/etc/nginx/sites-available/$DOMAIN"
            nginx -t && systemctl reload nginx
            echo -e "${C_GREEN}✔ Certbot SSL applied successfully!${C_RESET}"
        else
            echo -e "${C_RED}✖ Certbot failed!${C_RESET}"
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
                echo -e "${C_YELLOW}✔ Acme.sh generated certs, but Nginx config was NOT overwritten.${C_RESET}"
            fi
        else
            echo -e "${C_RED}✖ Acme.sh failed to issue certificate!${C_RESET}"
        fi
    elif [ "$ssl_choice" == "3" ]; then
        read -ep "Enter path to Certificate (.cer/.crt/.pem): " CERT_PATH
        read -ep "Enter path to Private Key (.key): " KEY_PATH
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
    read -ep "Press Enter to return to menu..."
}

# ====================================================================
# Global Domain & SSL Manager
# ====================================================================
function manage_domains() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_WHITE}Global Domain & SSL Manager${C_RESET} ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    pick_domain || { echo ""; read -ep "Press Enter..."; return; }
    local DOMAIN="$SELECTED_DOMAIN"
    
    CONF_FILE=$(grep -RlP "server_name\s+.*$DOMAIN" /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | head -n 1)
    [ -z "$CONF_FILE" ] && [ -f "/etc/nginx/sites-available/$DOMAIN" ] && CONF_FILE="/etc/nginx/sites-available/$DOMAIN"
    
    if [ -z "$CONF_FILE" ]; then
        echo -e "${C_RED}✖ Config file for $DOMAIN not found!${C_RESET}"
        echo ""; read -ep "Press Enter..."; return
    fi
    
    echo -e "\n${C_WHITE}What do you want to do with $DOMAIN?${C_RESET}"
    echo -e " ${C_CYAN}1)${C_RESET} Check SSL Status & View Paths"
    echo -e " ${C_YELLOW}2)${C_RESET} Remove SSL Only (Downgrade to HTTP)"
    echo -e " ${C_RED}3)${C_RESET} Completely Delete Domain Config (Destructive)"
    echo -e " ${C_CYAN}0)${C_RESET} Back to Menu"
    read -ep "Choice: " action
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
        read -ep "Downgrade $DOMAIN to HTTP and remove SSL settings? (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            echo -e "${C_BLUE}❖ Removing SSL configurations and files...${C_RESET}"
            EXTRACTED_PORT=$(grep -m 1 -E 'listen [0-9]+;' "$CONF_FILE" | grep -v 'ssl' | awk '{print $2}' | tr -d ';' || echo 80)
            if command -v certbot &> /dev/null; then certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null; fi
            if [ -f ~/.acme.sh/acme.sh ]; then ~/.acme.sh/acme.sh --remove -d "$DOMAIN" 2>/dev/null; rm -rf "/etc/nginx/ssl/$DOMAIN"* 2>/dev/null; fi
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
        read -ep "⚠ DESTRUCTIVE: Delete Nginx config file ($CONF_FILE) and SSLs for $DOMAIN? (y/n): " confirm
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
    echo ""; read -ep "Press Enter to return to menu..."
}

# ====================================================================
# Add Reverse Proxy (with domain picker + auto-revert on error)
# ====================================================================
function add_proxy() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_WHITE}Add Reverse Proxy${C_RESET} ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    pick_domain || { echo ""; read -ep "Press Enter..."; return; }
    local DOMAIN="$SELECTED_DOMAIN"
    
    read -ep "🔹 Enter Internal App Port (e.g., 8080): " PORT
    [ -z "$PORT" ] && { echo -e "${C_RED}✖ Port required.${C_RESET}"; echo ""; read -ep "Press Enter..."; return; }
    
    echo -e "${C_YELLOW}Tip: For 100% bug-free apps, type '/' (Root). Sub-paths like 'panel' may break complex apps.${C_RESET}"
    read -ep "🔹 Enter Path: " PPATH
    mkdir -p "$NGINX_PROXY_DIR/$DOMAIN"
    PPATH="${PPATH#/}"; PPATH="${PPATH%/}"
    
    local CONF_FILE
    if [ -z "$PPATH" ]; then
        CONF_FILE="$NGINX_PROXY_DIR/$DOMAIN/root.conf"
        cat > "$CONF_FILE" <<EOF
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
        CONF_FILE="$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf"
        echo -e "\n${C_WHITE}What type of application is this?${C_RESET}"
        echo -e " ${C_CYAN}1)${C_RESET} Black Hub / Custom App (Safe Routing + Upload Fixes)"
        echo -e " ${C_CYAN}2)${C_RESET} X-UI Panel (Direct Pass - *Requires setting Base Path in X-UI*)"
        read -ep "Choice (1 or 2): " app_type
        if [ "$app_type" == "1" ]; then
            cat > "$CONF_FILE" <<EOF
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
    proxy_set_header Accept-Encoding "";
    sub_filter '<head>' '<head><base href="/$PPATH/">';
    sub_filter 'src="/' 'src="/$PPATH/';
    sub_filter 'href="/' 'href="/$PPATH/';
    sub_filter_once off;
    sub_filter_types text/html text/css application/javascript;
}
EOF
        else
            cat > "$CONF_FILE" <<EOF
location /$PPATH/ {
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
            echo -e "\n${C_YELLOW}⚠ IMPORTANT: For X-UI on /$PPATH/, set 'Panel url root path' to '/$PPATH/' in X-UI settings!${C_RESET}"
        fi
        echo -e "\n${C_YELLOW}⚠ If your app has broken links on /$PPATH/, remove and add it as '/' instead!${C_RESET}"
    fi
    
    # Auto-revert if nginx fails
    if nginx_safe_reload "$CONF_FILE" "revert"; then
        echo -e "\n${C_GREEN}✔ Reverse proxy added successfully!${C_RESET}"
    fi
    echo ""; read -ep "Press Enter..."
}

# ====================================================================
# List Proxies (UNCHANGED — was working)
# ====================================================================
function list_proxies() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_WHITE}List All Configured Proxies${C_RESET} ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    echo -e "\n${C_BLUE}❖ Script Managed Proxies (proxy.d):${C_RESET}"
    if [ -d "$NGINX_PROXY_DIR" ]; then
        for domain_path in "$NGINX_PROXY_DIR"/*; do
            DOMAIN=$(basename "$domain_path")
            echo -e "  ${C_GREEN}▶ $DOMAIN${C_RESET}"
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
        echo "$EXTERNAL_PROXIES" | awk -F':' '{print "    ├─ File: " $1 " ➔ " $3":"$4}' | sed 's/;//g'
    else
        echo -e "  ${C_YELLOW}No external proxies found.${C_RESET}"
    fi
    echo ""; read -ep "Press Enter..."
}

# ====================================================================
# Remove Proxy Path (with domain + path pickers)
# ====================================================================
function remove_proxy() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_WHITE}Remove a Reverse Proxy Path${C_RESET} ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    pick_domain || { echo ""; read -ep "Press Enter..."; return; }
    local DOMAIN="$SELECTED_DOMAIN"
    
    pick_path "$DOMAIN" || { echo ""; read -ep "Press Enter..."; return; }
    local PPATH="$SELECTED_PATH"
    
    PPATH="${PPATH#/}"; PPATH="${PPATH%/}"; [ -z "$PPATH" ] && PPATH="root"
    
    if [ -f "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf" ]; then
        read -ep "⚠ Remove $DOMAIN/$PPATH? (y/N): " ok
        if [[ "$ok" == "y" || "$ok" == "Y" ]]; then
            rm "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf"
            if nginx -t 2>/tmp/nginx_test_err; then
                systemctl reload nginx
                echo -e "${C_GREEN}✔ Removed.${C_RESET}"
            else
                echo -e "${C_RED}✖ Nginx broke after removal:${C_RESET}"
                cat /tmp/nginx_test_err
            fi
        fi
    else
        echo -e "${C_RED}✖ Path configuration not found!${C_RESET}"
    fi
    echo ""; read -ep "Press Enter..."
}

# ====================================================================
# Fix Nginx (auto-repair attempt)
# ====================================================================
function fix_nginx() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_WHITE}Auto-Fix Nginx${C_RESET}              ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    echo -e "\n${C_BLUE}❖ Step 1: Checking current Nginx status...${C_RESET}"
    local status
    status=$(nginx_status)
    echo -e "Current status: $(nginx_status_display)"
    
    echo -e "\n${C_BLUE}❖ Step 2: Testing Nginx configuration...${C_RESET}"
    if nginx -t 2>/tmp/nginx_test_err; then
        echo -e "${C_GREEN}✔ Config is valid.${C_RESET}"
    else
        echo -e "${C_RED}✖ Config has errors:${C_RESET}"
        cat /tmp/nginx_test_err
    fi
    
    echo -e "\n${C_BLUE}❖ Step 3: Fixing duplicate client_max_body_size lines...${C_RESET}"
    local fixed=0
    for f in /etc/nginx/sites-available/* /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
        [ -f "$f" ] || continue
        local before
        before=$(grep -c "client_max_body_size" "$f" 2>/dev/null)
        before=${before:-0}
        dedupe_client_max_body_size "$f"
        local after
        after=$(grep -c "client_max_body_size" "$f" 2>/dev/null)
        after=${after:-0}
        if [ "$before" -gt "$after" ]; then
            echo -e "  ${C_GREEN}✔${C_RESET} $f  ($before → $after)"
            fixed=$((fixed+1))
        fi
    done
    [ "$fixed" -eq 0 ] && echo -e "  ${C_GREEN}✔ No duplicates found.${C_RESET}"
    
    echo -e "\n${C_BLUE}❖ Step 4: Checking for orphan symlinks in sites-enabled...${C_RESET}"
    local orphans=0
    for link in /etc/nginx/sites-enabled/*; do
        [ -L "$link" ] && [ ! -e "$link" ] && {
            echo -e "  ${C_YELLOW}⚠ Removing broken symlink: $link${C_RESET}"
            rm -f "$link"
            orphans=$((orphans+1))
        }
    done
    [ "$orphans" -eq 0 ] && echo -e "  ${C_GREEN}✔ No orphan symlinks.${C_RESET}"
    
    echo -e "\n${C_BLUE}❖ Step 5: Re-testing Nginx...${C_RESET}"
    if nginx -t 2>/tmp/nginx_test_err; then
        echo -e "${C_GREEN}✔ Config is valid!${C_RESET}"
        
        echo -e "\n${C_BLUE}❖ Step 6: Restarting Nginx...${C_RESET}"
        if systemctl restart nginx; then
            sleep 1
            local new_status
            new_status=$(nginx_status)
            if [ "$new_status" = "active" ]; then
                echo -e "${C_GREEN}✔ Nginx restarted successfully!${C_RESET}"
            else
                echo -e "${C_YELLOW}⚠ Nginx status: $new_status${C_RESET}"
                systemctl status nginx --no-pager | head -n 15
            fi
        else
            echo -e "${C_RED}✖ Failed to restart Nginx.${C_RESET}"
            systemctl status nginx --no-pager | head -n 15
        fi
    else
        echo -e "${C_RED}✖ Config still has errors:${C_RESET}"
        cat /tmp/nginx_test_err
        echo ""
        echo -e "${C_YELLOW}Try manually editing the file mentioned above, or use option 3 to delete the broken domain.${C_RESET}"
    fi
    
    echo ""; read -ep "Press Enter..."
}

# ====================================================================
# Service Control (start/stop/restart Nginx)
# ====================================================================
function service_control() {
    while true; do
        clear
        echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
        echo -e "${C_CYAN}│${C_RESET} ${C_WHITE}Nginx Service Control${C_RESET}        ${C_CYAN}│${C_RESET}"
        echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
        echo ""
        echo -e "  Current status: $(nginx_status_display)"
        echo ""
        echo -e "  ${C_GREEN}1)${C_RESET} Start Nginx"
        echo -e "  ${C_YELLOW}2)${C_RESET} Stop Nginx"
        echo -e "  ${C_BLUE}3)${C_RESET} Restart Nginx"
        echo -e "  ${C_BLUE}4)${C_RESET} Reload Nginx (no downtime)"
        echo -e "  ${C_CYAN}5)${C_RESET} Show full service status"
        echo -e "  ${C_CYAN}6)${C_RESET} Enable on boot"
        echo -e "  ${C_CYAN}7)${C_RESET} Disable on boot"
        echo -e "  ${C_WHITE}0)${C_RESET} Back to main menu"
        read -ep "  Choice: " c
        case "$c" in
            1)
                systemctl start nginx && echo -e "${C_GREEN}✔ Started.${C_RESET}" || echo -e "${C_RED}✖ Failed.${C_RESET}"
                read -ep "Press Enter..."
                ;;
            2)
                read -ep "⚠ Stop Nginx? Sites will go down. (y/N): " ok
                if [[ "$ok" == "y" || "$ok" == "Y" ]]; then
                    systemctl stop nginx && echo -e "${C_GREEN}✔ Stopped.${C_RESET}" || echo -e "${C_RED}✖ Failed.${C_RESET}"
                fi
                read -ep "Press Enter..."
                ;;
            3)
                if nginx -t 2>/tmp/nginx_test_err; then
                    systemctl restart nginx && echo -e "${C_GREEN}✔ Restarted.${C_RESET}" || echo -e "${C_RED}✖ Failed.${C_RESET}"
                else
                    echo -e "${C_RED}✖ Config has errors. Refusing to restart:${C_RESET}"
                    cat /tmp/nginx_test_err
                    echo -e "${C_YELLOW}Tip: Use option 7 (Fix Nginx) in main menu.${C_RESET}"
                fi
                read -ep "Press Enter..."
                ;;
            4)
                if nginx -t 2>/tmp/nginx_test_err; then
                    systemctl reload nginx && echo -e "${C_GREEN}✔ Reloaded.${C_RESET}" || echo -e "${C_RED}✖ Failed.${C_RESET}"
                else
                    echo -e "${C_RED}✖ Config has errors:${C_RESET}"
                    cat /tmp/nginx_test_err
                fi
                read -ep "Press Enter..."
                ;;
            5)
                systemctl status nginx --no-pager | head -n 25
                echo ""; read -ep "Press Enter..."
                ;;
            6)
                systemctl enable nginx && echo -e "${C_GREEN}✔ Nginx will start on boot.${C_RESET}"
                read -ep "Press Enter..."
                ;;
            7)
                systemctl disable nginx && echo -e "${C_GREEN}✔ Nginx will NOT start on boot.${C_RESET}"
                read -ep "Press Enter..."
                ;;
            0) return ;;
        esac
    done
}

# ====================================================================
# Self-Update from GitHub
# ====================================================================
function update_script() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_WHITE}Update Script from GitHub${C_RESET}    ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    local REMOTE_URL="https://""raw.githubusercontent.com/saeederamy/black-ssl/refs/heads/main/install.sh"
    local TMP_FILE="/tmp/black-ssl-update.sh"
    local BACKUP_FILE="/tmp/black-ssl-backup-$(date +%Y%m%d_%H%M%S).sh"
    
    echo -e "\n${C_BLUE}❖ Step 1: Downloading latest version...${C_RESET}"
    if ! curl -fsSL "$REMOTE_URL" -o "$TMP_FILE"; then
        echo -e "${C_RED}✖ Download failed! Check your internet connection.${C_RESET}"
        rm -f "$TMP_FILE"
        echo ""; read -ep "Press Enter..."
        return
    fi
    
    # Verify file is non-empty
    if [ ! -s "$TMP_FILE" ]; then
        echo -e "${C_RED}✖ Downloaded file is empty!${C_RESET}"
        rm -f "$TMP_FILE"
        echo ""; read -ep "Press Enter..."
        return
    fi
    echo -e "${C_GREEN}✔ Downloaded ($(wc -c < "$TMP_FILE") bytes)${C_RESET}"
    
    echo -e "\n${C_BLUE}❖ Step 2: Verifying syntax...${C_RESET}"
    if ! bash -n "$TMP_FILE" 2>/tmp/syntax_err; then
        echo -e "${C_RED}✖ Syntax error in downloaded file! Update aborted.${C_RESET}"
        cat /tmp/syntax_err
        rm -f "$TMP_FILE"
        echo ""; read -ep "Press Enter..."
        return
    fi
    echo -e "${C_GREEN}✔ Syntax OK${C_RESET}"
    
    echo -e "\n${C_BLUE}❖ Step 3: Comparing versions...${C_RESET}"
    if cmp -s "$COMMAND_PATH" "$TMP_FILE"; then
        echo -e "${C_GREEN}✔ You already have the latest version!${C_RESET}"
        rm -f "$TMP_FILE"
        echo ""; read -ep "Press Enter..."
        return
    fi
    
    local current_lines new_lines
    current_lines=$(wc -l < "$COMMAND_PATH")
    new_lines=$(wc -l < "$TMP_FILE")
    echo -e "  Current: $current_lines lines"
    echo -e "  New:     $new_lines lines"
    
    echo ""
    read -ep "🔹 Apply update? (Y/n): " ok
    if [[ "$ok" == "n" || "$ok" == "N" ]]; then
        echo -e "${C_YELLOW}Update cancelled.${C_RESET}"
        rm -f "$TMP_FILE"
        echo ""; read -ep "Press Enter..."
        return
    fi
    
    echo -e "\n${C_BLUE}❖ Step 4: Backing up current version...${C_RESET}"
    if cp "$COMMAND_PATH" "$BACKUP_FILE"; then
        echo -e "${C_GREEN}✔ Backup saved: $BACKUP_FILE${C_RESET}"
    else
        echo -e "${C_YELLOW}⚠ Could not create backup, continuing anyway...${C_RESET}"
    fi
    
    echo -e "\n${C_BLUE}❖ Step 5: Installing new version...${C_RESET}"
    if mv "$TMP_FILE" "$COMMAND_PATH" && chmod +x "$COMMAND_PATH"; then
        ln -sf "$COMMAND_PATH" "/usr/bin/black-ssl"
        echo -e "${C_GREEN}✔ Update installed successfully!${C_RESET}"
        echo ""
        echo -e "${C_YELLOW}To restore the previous version if something breaks:${C_RESET}"
        echo -e "  ${C_WHITE}cp $BACKUP_FILE $COMMAND_PATH && chmod +x $COMMAND_PATH${C_RESET}"
        echo ""
        read -ep "🔹 Relaunch script with the new version now? (Y/n): " go
        if [[ "$go" != "n" && "$go" != "N" ]]; then
            echo -e "${C_BLUE}❖ Restarting...${C_RESET}"
            sleep 1
            exec "$COMMAND_PATH"
        fi
    else
        echo -e "${C_RED}✖ Failed to install the new version!${C_RESET}"
        if [ -f "$BACKUP_FILE" ]; then
            echo -e "${C_YELLOW}Restoring backup...${C_RESET}"
            cp "$BACKUP_FILE" "$COMMAND_PATH" && chmod +x "$COMMAND_PATH"
        fi
    fi
    echo ""; read -ep "Press Enter..."
}

# ====================================================================
# Deep Clean
# ====================================================================
function uninstall_all() {
    read -ep "⚠ DESTRUCTIVE: Purge Nginx, SSL, and all Configs from Server? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop nginx 2>/dev/null; killall -9 nginx 2>/dev/null
        apt-get purge nginx nginx-common nginx-core certbot python3-certbot-nginx -y; apt-get autoremove -y
        rm -rf /etc/nginx /var/www/html /etc/letsencrypt ~/.acme.sh /root/.acme.sh /usr/local/bin/black-ssl /usr/bin/black-ssl
        echo -e "${C_GREEN}✔ System fully cleaned.${C_RESET}"; exit 0
    fi
}

# ====================================================================
# MAIN MENU
# ====================================================================
while true; do
    clear
    echo -e "${C_CYAN} ╭──────────────────────────────────────────────╮"
    echo -e "  │           ${C_WHITE}✨ BLACK SSL MANAGER ✨${C_CYAN}            │"
    echo -e "  ╰──────────────────────────────────────────────╯${C_RESET}"
    echo -e "  Nginx: $(nginx_status_display)"
    echo ""
    echo -e "  1 ➜ Install Nginx & Setup Domain"
    echo -e "  2 ➜ Add Reverse Proxy (Port ➔ Path)"
    echo -e "  3 ➜ Global Domain & SSL Manager (Scan/Check/Remove)"
    echo -e "  4 ➜ List All Proxies (Internal & External)"
    echo -e "  5 ➜ Remove a Specific Proxy Path"
    echo -e "  ${C_YELLOW}7 ➜ Fix Nginx (Auto-repair config & duplicates)${C_RESET}"
    echo -e "  ${C_CYAN}8 ➜ Nginx Service Control (Start/Stop/Restart)${C_RESET}"
    echo -e "  ${C_GREEN}9 ➜ Update Script from GitHub${C_RESET}"
    echo -e "  6 ➜ Danger: Deep Remove All"
    echo -e "  0 ➜ Exit"
    read -ep "  Select Option: " choice
    case $choice in
        1) install_nginx_ssl ;;
        2) add_proxy ;;
        3) manage_domains ;;
        4) list_proxies ;;
        5) remove_proxy ;;
        6) uninstall_all ;;
        7) fix_nginx ;;
        8) service_control ;;
        9) update_script ;;
        0) clear; exit 0 ;;
    esac
done
