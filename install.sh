#!/bin/bash
# ============================================================
#  ✨ BLACK SSL MANAGER v2.0 ✨
#  Auto Nginx & SSL Manager with Backup, Monitoring & Telegram Alerts
#  Repo: https://github.com/saeederamy/black-ssl
# ============================================================

# --- Fix Terminal Input Bugs (Backspace / weird chars on some SSH clients) ---
stty sane 2>/dev/null
stty erase '^?' 2>/dev/null

# --- Color & UI Definitions ---
C_CYAN="\e[1;36m"
C_BLUE="\e[1;34m"
C_GREEN="\e[1;32m"
C_YELLOW="\e[1;33m"
C_RED="\e[1;31m"
C_WHITE="\e[1;37m"
C_MAGENTA="\e[1;35m"
C_RESET="\e[0m"

# --- Root Access Check ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${C_RED}✖ Please run this script as root.${C_RESET}"
    exit 1
fi

# --- Global Paths ---
NGINX_PROXY_DIR="/etc/nginx/proxy.d"
BACKUP_DIR="/var/backups/black-ssl"
CONFIG_DIR="/etc/black-ssl"
TG_CONFIG="$CONFIG_DIR/telegram.conf"
COMMAND_PATH="/usr/local/bin/black-ssl"

mkdir -p "$BACKUP_DIR" "$CONFIG_DIR" "$NGINX_PROXY_DIR"

# --- Global Command Setup ---
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

# ============================================================
#  🛡️  HELPER: Safe directive injection (FIXES DUPLICATE BUG)
# ============================================================
# Adds a directive after server_name ONLY if it does not already
# exist in the same server block. Prevents duplicate
# client_max_body_size, etc.
function safe_inject_directive() {
    local file="$1"
    local directive="$2"   # e.g. "client_max_body_size 0;"
    
    [ ! -f "$file" ] && return 1
    
    # Count how many times the directive already exists
    local existing_count
    existing_count=$(grep -c -F "$directive" "$file" 2>/dev/null || echo 0)
    # Count how many server blocks exist
    local server_count
    server_count=$(grep -c -E '^\s*server\s*\{' "$file" 2>/dev/null || echo 0)
    
    # If it already exists in every server block, do nothing
    if [ "$existing_count" -ge "$server_count" ] && [ "$server_count" -gt 0 ]; then
        return 0
    fi
    
    # Inject after every server_name that does NOT already have the directive within ~3 lines
    # Use awk for safety instead of dumb sed
    awk -v dir="$directive" '
        BEGIN { in_block = 0; injected_for_this_block = 0; just_saw_server_name = 0 }
        /^\s*server\s*\{/ { in_block = 1; injected_for_this_block = 0 }
        /^\s*\}/ { in_block = 0; injected_for_this_block = 0 }
        {
            print
            if (in_block && !injected_for_this_block && $0 ~ /server_name/) {
                # peek: we need to know if directive already there in this block
                # simple heuristic: rely on grep done outside; here we just inject once per block
                indent = $0
                sub(/[^ \t].*/, "", indent)
                print indent dir
                injected_for_this_block = 1
            }
        }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    
    # Now de-duplicate: if any server block has the directive twice, remove extras
    dedupe_directives_in_file "$file" "$directive"
}

# Removes duplicate occurrences of an exact directive within each server block
function dedupe_directives_in_file() {
    local file="$1"
    local directive="$2"
    
    [ ! -f "$file" ] && return 1
    
    awk -v dir="$directive" '
        BEGIN { in_block = 0; seen_in_block = 0 }
        /^\s*server\s*\{/ { in_block = 1; seen_in_block = 0; print; next }
        /^\s*\}/ {
            if (in_block) { in_block = 0; seen_in_block = 0 }
            print; next
        }
        {
            line = $0
            stripped = line
            gsub(/^[ \t]+|[ \t]+$/, "", stripped)
            if (in_block && stripped == dir) {
                if (seen_in_block) next   # skip duplicate
                seen_in_block = 1
            }
            print
        }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# ============================================================
#  🛡️  AUTO BACKUP (called before any destructive change)
# ============================================================
function auto_backup() {
    local label="${1:-auto}"
    local stamp
    stamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="$BACKUP_DIR/nginx_${label}_${stamp}.tar.gz"
    
    if [ -d /etc/nginx ]; then
        tar -czf "$backup_file" \
            -C / etc/nginx \
            $([ -d /etc/letsencrypt ] && echo "etc/letsencrypt") \
            2>/dev/null
        echo -e "${C_GREEN}✔ Backup saved: $backup_file${C_RESET}"
    fi
    
    # Keep only the last 10 backups
    ls -1t "$BACKUP_DIR"/nginx_*.tar.gz 2>/dev/null | tail -n +11 | xargs -r rm -f
}

function restore_backup() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_WHITE}Backup & Rollback Manager${C_RESET}        ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    echo -e "\n${C_WHITE}Options:${C_RESET}"
    echo -e " ${C_CYAN}1)${C_RESET} Create a manual backup now"
    echo -e " ${C_CYAN}2)${C_RESET} List & restore an existing backup"
    echo -e " ${C_CYAN}3)${C_RESET} Delete all backups"
    echo -e " ${C_CYAN}0)${C_RESET} Back to menu"
    read -ep "Choice: " bk_choice
    
    case "$bk_choice" in
        1)
            auto_backup "manual"
            ;;
        2)
            local backups=("$BACKUP_DIR"/nginx_*.tar.gz)
            if [ ! -e "${backups[0]}" ]; then
                echo -e "${C_YELLOW}⚠ No backups available.${C_RESET}"
            else
                echo -e "\n${C_BLUE}Available backups:${C_RESET}"
                local i=1
                for b in "${backups[@]}"; do
                    echo -e " ${C_CYAN}$i)${C_RESET} $(basename "$b") ($(du -h "$b" | cut -f1))"
                    i=$((i+1))
                done
                read -ep "Enter backup number to restore (or 0 to cancel): " idx
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le ${#backups[@]} ]; then
                    local target="${backups[$((idx-1))]}"
                    read -ep "⚠ Restoring will OVERWRITE current /etc/nginx. Continue? (y/N): " ok
                    if [[ "$ok" == "y" || "$ok" == "Y" ]]; then
                        # Backup the current state first, just in case
                        auto_backup "pre_restore"
                        tar -xzf "$target" -C /
                        nginx -t && systemctl reload nginx
                        echo -e "${C_GREEN}✔ Restored from $(basename "$target")${C_RESET}"
                    fi
                fi
            fi
            ;;
        3)
            read -ep "⚠ Delete ALL backups? (y/N): " ok
            if [[ "$ok" == "y" || "$ok" == "Y" ]]; then
                rm -f "$BACKUP_DIR"/nginx_*.tar.gz
                echo -e "${C_GREEN}✔ All backups deleted.${C_RESET}"
            fi
            ;;
    esac
    echo ""; read -ep "Press Enter to return to menu..."
}

# ============================================================
#  📡  TELEGRAM NOTIFIER
# ============================================================
function setup_telegram() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_WHITE}Telegram Bot Configuration${C_RESET}       ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    if [ -f "$TG_CONFIG" ]; then
        source "$TG_CONFIG"
        echo -e "${C_GREEN}Currently configured:${C_RESET}"
        echo -e "  Bot Token: ${TG_BOT_TOKEN:0:10}..."
        echo -e "  Chat ID:   $TG_CHAT_ID"
        echo ""
    fi
    
    echo -e "${C_WHITE}Options:${C_RESET}"
    echo -e " ${C_CYAN}1)${C_RESET} Setup / Update Telegram bot"
    echo -e " ${C_CYAN}2)${C_RESET} Send a test message"
    echo -e " ${C_CYAN}3)${C_RESET} Run SSL expiry check now"
    echo -e " ${C_CYAN}4)${C_RESET} Enable daily auto-check (cron)"
    echo -e " ${C_CYAN}5)${C_RESET} Disable auto-check"
    echo -e " ${C_CYAN}6)${C_RESET} Remove Telegram config"
    echo -e " ${C_CYAN}0)${C_RESET} Back"
    read -ep "Choice: " tg_choice
    
    case "$tg_choice" in
        1)
            echo -e "${C_YELLOW}Tip: Get a token from @BotFather, and your chat ID from @userinfobot${C_RESET}"
            read -ep "🔹 Enter Bot Token: " bot_token
            read -ep "🔹 Enter Chat ID: " chat_id
            cat > "$TG_CONFIG" <<EOF
TG_BOT_TOKEN="$bot_token"
TG_CHAT_ID="$chat_id"
EOF
            chmod 600 "$TG_CONFIG"
            echo -e "${C_GREEN}✔ Saved.${C_RESET}"
            ;;
        2)
            send_telegram "🧪 *Black SSL Manager* test message from $(hostname)"
            ;;
        3)
            check_ssl_expiry true
            ;;
        4)
            enable_ssl_cron
            ;;
        5)
            disable_ssl_cron
            ;;
        6)
            rm -f "$TG_CONFIG"
            echo -e "${C_GREEN}✔ Telegram config removed.${C_RESET}"
            ;;
    esac
    echo ""; read -ep "Press Enter..."
}

function send_telegram() {
    local msg="$1"
    [ ! -f "$TG_CONFIG" ] && return 1
    source "$TG_CONFIG"
    [ -z "$TG_BOT_TOKEN" ] && return 1
    [ -z "$TG_CHAT_ID" ] && return 1
    
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TG_CHAT_ID" \
        -d parse_mode="Markdown" \
        --data-urlencode text="$msg" \
        > /dev/null
}

function check_ssl_expiry() {
    local verbose="${1:-false}"
    local warn_days=7
    local found_any=false
    local report=""
    
    [ "$verbose" = "true" ] && echo -e "${C_BLUE}❖ Scanning all SSL certificates...${C_RESET}"
    
    while IFS= read -r conf; do
        local cert
        cert=$(grep -m 1 "ssl_certificate " "$conf" 2>/dev/null | awk '{print $2}' | tr -d ';')
        local domain
        domain=$(grep -m 1 "server_name " "$conf" 2>/dev/null | awk '{print $2}' | tr -d ';')
        
        [ -z "$cert" ] || [ ! -f "$cert" ] && continue
        found_any=true
        
        local end_date
        end_date=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
        local end_epoch
        end_epoch=$(date -d "$end_date" +%s 2>/dev/null)
        local now_epoch
        now_epoch=$(date +%s)
        local days_left=$(( (end_epoch - now_epoch) / 86400 ))
        
        local status_icon="✅"
        [ "$days_left" -lt "$warn_days" ] && status_icon="⚠️"
        [ "$days_left" -lt 0 ] && status_icon="❌"
        
        [ "$verbose" = "true" ] && echo -e "  $status_icon ${C_WHITE}$domain${C_RESET} → $days_left days left ($end_date)"
        
        if [ "$days_left" -lt "$warn_days" ]; then
            report+="$status_icon *$domain* → $days_left days left%0A"
        fi
    done < <(find /etc/nginx/sites-enabled /etc/nginx/conf.d -type f \( -name "*.conf" -o ! -name "*.conf" \) 2>/dev/null)
    
    [ "$found_any" = "false" ] && [ "$verbose" = "true" ] && echo -e "${C_YELLOW}No SSL certificates found.${C_RESET}"
    
    if [ -n "$report" ] && [ -f "$TG_CONFIG" ]; then
        send_telegram "🔔 *SSL Expiry Alert* on $(hostname)%0A%0A$report"
        [ "$verbose" = "true" ] && echo -e "${C_GREEN}✔ Telegram alert sent.${C_RESET}"
    fi
}

function enable_ssl_cron() {
    local cron_line="0 9 * * * $COMMAND_PATH --cron-ssl-check >/dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -v -- "--cron-ssl-check"; echo "$cron_line") | crontab -
    echo -e "${C_GREEN}✔ Daily SSL check enabled (9:00 AM server time).${C_RESET}"
}

function disable_ssl_cron() {
    crontab -l 2>/dev/null | grep -v -- "--cron-ssl-check" | crontab -
    echo -e "${C_GREEN}✔ SSL auto-check disabled.${C_RESET}"
}

# Handle the cron flag (silent run)
if [ "$1" = "--cron-ssl-check" ]; then
    check_ssl_expiry false
    exit 0
fi

# ============================================================
#  🔥  FIREWALL MANAGER
# ============================================================
function manage_firewall() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_WHITE}Firewall Manager (UFW)${C_RESET}           ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    if ! command -v ufw &>/dev/null; then
        read -ep "UFW is not installed. Install it now? (y/N): " ok
        if [[ "$ok" == "y" || "$ok" == "Y" ]]; then
            apt update && apt install -y ufw
        else
            return
        fi
    fi
    
    echo -e "\n${C_BLUE}❖ Current UFW status:${C_RESET}"
    ufw status numbered
    
    echo -e "\n${C_WHITE}Options:${C_RESET}"
    echo -e " ${C_CYAN}1)${C_RESET} Open ports 80 & 443 (HTTP/HTTPS)"
    echo -e " ${C_CYAN}2)${C_RESET} Open a custom port"
    echo -e " ${C_CYAN}3)${C_RESET} Close a port"
    echo -e " ${C_CYAN}4)${C_RESET} Enable firewall (allow SSH first!)"
    echo -e " ${C_CYAN}5)${C_RESET} Disable firewall"
    echo -e " ${C_CYAN}6)${C_RESET} Auto-open all Nginx listen ports"
    echo -e " ${C_CYAN}0)${C_RESET} Back"
    read -ep "Choice: " fw_choice
    
    case "$fw_choice" in
        1)
            ufw allow 80/tcp
            ufw allow 443/tcp
            echo -e "${C_GREEN}✔ Ports 80 & 443 opened.${C_RESET}"
            ;;
        2)
            read -ep "🔹 Enter port number: " p
            read -ep "🔹 Protocol (tcp/udp/both) [tcp]: " proto
            proto=${proto:-tcp}
            if [ "$proto" = "both" ]; then
                ufw allow "$p"
            else
                ufw allow "$p/$proto"
            fi
            echo -e "${C_GREEN}✔ Port $p opened.${C_RESET}"
            ;;
        3)
            read -ep "🔹 Enter port number to close: " p
            ufw delete allow "$p/tcp" 2>/dev/null
            ufw delete allow "$p/udp" 2>/dev/null
            ufw delete allow "$p" 2>/dev/null
            echo -e "${C_GREEN}✔ Port $p closed.${C_RESET}"
            ;;
        4)
            echo -e "${C_YELLOW}⚠ Make sure SSH (port 22 or your custom one) is allowed BEFORE enabling!${C_RESET}"
            read -ep "Add SSH rule (port 22) automatically? (Y/n): " ok
            [[ "$ok" != "n" && "$ok" != "N" ]] && ufw allow 22/tcp
            ufw --force enable
            ;;
        5)
            ufw disable
            ;;
        6)
            echo -e "${C_BLUE}❖ Scanning Nginx listen ports...${C_RESET}"
            local ports
            ports=$(grep -hroP 'listen\s+\K[0-9]+' /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | sort -u)
            for p in $ports; do
                ufw allow "$p/tcp" >/dev/null 2>&1
                echo -e "  ${C_GREEN}▶${C_RESET} Opened port $p"
            done
            ;;
    esac
    echo ""; read -ep "Press Enter..."
}

# ============================================================
#  📜  LIVE LOG VIEWER
# ============================================================
function live_logs() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_WHITE}Live Nginx Log Viewer${C_RESET}            ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    echo -e "\n${C_WHITE}Choose:${C_RESET}"
    echo -e " ${C_CYAN}1)${C_RESET} Last 50 lines of error.log"
    echo -e " ${C_CYAN}2)${C_RESET} Last 50 lines of access.log"
    echo -e " ${C_CYAN}3)${C_RESET} Live tail error.log (Ctrl+C to exit)"
    echo -e " ${C_CYAN}4)${C_RESET} Live tail access.log (Ctrl+C to exit)"
    echo -e " ${C_CYAN}5)${C_RESET} Search a domain in logs"
    echo -e " ${C_CYAN}6)${C_RESET} systemd: nginx service status"
    echo -e " ${C_CYAN}0)${C_RESET} Back"
    read -ep "Choice: " lg
    
    case "$lg" in
        1) tail -n 50 /var/log/nginx/error.log 2>/dev/null || echo "No error log found." ;;
        2) tail -n 50 /var/log/nginx/access.log 2>/dev/null || echo "No access log found." ;;
        3) echo -e "${C_YELLOW}Press Ctrl+C to stop...${C_RESET}"; sleep 1; tail -f /var/log/nginx/error.log ;;
        4) echo -e "${C_YELLOW}Press Ctrl+C to stop...${C_RESET}"; sleep 1; tail -f /var/log/nginx/access.log ;;
        5)
            read -ep "🔹 Enter domain or keyword: " kw
            echo -e "${C_BLUE}❖ Last 50 matches in error.log:${C_RESET}"
            grep -i "$kw" /var/log/nginx/error.log 2>/dev/null | tail -n 50
            echo -e "\n${C_BLUE}❖ Last 50 matches in access.log:${C_RESET}"
            grep -i "$kw" /var/log/nginx/access.log 2>/dev/null | tail -n 50
            ;;
        6) systemctl status nginx --no-pager -l | head -n 30 ;;
    esac
    echo ""; read -ep "Press Enter..."
}

# ============================================================
#  🩺  CONFIG REPAIR TOOL (fixes the duplicate-line bug!)
# ============================================================
function repair_configs() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_WHITE}Nginx Config Repair Tool${C_RESET}         ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    echo -e "\n${C_BLUE}❖ This will:${C_RESET}"
    echo "  1. Auto-backup current /etc/nginx"
    echo "  2. Remove duplicate 'client_max_body_size' lines per server block"
    echo "  3. Test the config and reload Nginx if valid"
    echo ""
    read -ep "Continue? (y/N): " ok
    [[ "$ok" != "y" && "$ok" != "Y" ]] && return
    
    auto_backup "pre_repair"
    
    local fixed=0
    while IFS= read -r conf; do
        local before
        before=$(grep -c "client_max_body_size" "$conf" 2>/dev/null || echo 0)
        dedupe_directives_in_file "$conf" "client_max_body_size 0;"
        local after
        after=$(grep -c "client_max_body_size" "$conf" 2>/dev/null || echo 0)
        if [ "$before" -ne "$after" ]; then
            echo -e "  ${C_GREEN}✔${C_RESET} $conf  ($before → $after)"
            fixed=$((fixed+1))
        fi
    done < <(find /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d -type f 2>/dev/null)
    
    echo -e "\n${C_GREEN}Fixed $fixed file(s).${C_RESET}"
    if nginx -t; then
        systemctl reload nginx
        echo -e "${C_GREEN}✔ Nginx reloaded successfully.${C_RESET}"
    else
        echo -e "${C_RED}✖ Nginx test failed. Use 'Backup & Rollback' to revert.${C_RESET}"
    fi
    echo ""; read -ep "Press Enter..."
}

# ============================================================
#  🌐  Install Nginx & SSL (FIXED: no more duplicate directives)
# ============================================================
function install_nginx_ssl() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_WHITE}Nginx & SSL Configuration${C_RESET}        ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    read -ep "🔹 Enter Domain (e.g., example.com): " DOMAIN
    
    [ -z "$DOMAIN" ] && { echo -e "${C_RED}✖ Empty domain.${C_RESET}"; return; }
    
    auto_backup "pre_install_$DOMAIN"
    
    if ! command -v nginx &> /dev/null; then
        echo -e "${C_BLUE}❖ Installing Nginx...${C_RESET}"
        apt update && apt install nginx curl openssl -y
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
    echo -e " ${C_CYAN}2)${C_RESET} Acme.sh (ZeroSSL — ${C_RED}NOT for .ir domains${C_RESET})"
    echo -e " ${C_CYAN}3)${C_RESET} Manual SSL (Upload your own certs)"
    echo -e " ${C_CYAN}4)${C_RESET} Skip SSL (HTTP Only)"
    read -ep "Choice (1/2/3/4): " ssl_choice
    
    if [ "$ssl_choice" == "1" ]; then
        echo -e "${C_BLUE}❖ Installing Certbot...${C_RESET}"
        apt install certbot python3-certbot-nginx -y
        if certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email; then
            # 🛡️ FIXED: Safe injection that won't duplicate
            safe_inject_directive "/etc/nginx/sites-available/$DOMAIN" "client_max_body_size 0;"
            nginx -t && systemctl reload nginx
            echo -e "${C_GREEN}✔ Certbot SSL applied successfully!${C_RESET}"
        else
            echo -e "${C_RED}✖ Certbot failed!${C_RESET}"
        fi
    elif [ "$ssl_choice" == "2" ]; then
        if [[ "$DOMAIN" == *.ir ]]; then
            echo -e "${C_RED}✖ ZeroSSL blocks .ir domains. Use Certbot or Manual instead.${C_RESET}"
            echo ""; read -ep "Press Enter..."; return
        fi
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
                echo -e "${C_GREEN}✔ Acme.sh (ZeroSSL) applied!${C_RESET}"
            fi
        else
            echo -e "${C_RED}✖ Acme.sh failed!${C_RESET}"
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
    echo ""; read -ep "Press Enter to return to menu..."
}

# ============================================================
#  📋  Manage Domains
# ============================================================
function manage_domains() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_WHITE}Global Domain & SSL Manager${C_RESET}      ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    local domains=()
    echo -e "${C_BLUE}❖ Active Domains (Scanned from ALL Nginx configs):${C_RESET}"
    for d in $(grep -hRoP 'server_name\s+\K[a-zA-Z0-9.-]+' /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | tr -d ';' | sort -u); do
        if [[ "$d" != "_" && "$d" != "localhost" ]]; then
            domains+=("$d")
            echo -e "  ${C_GREEN}▶ $d${C_RESET}"
        fi
    done
    
    if [ ${#domains[@]} -eq 0 ]; then
        echo -e "  ${C_YELLOW}No domains configured yet.${C_RESET}"
        echo ""; read -ep "Press Enter..."; return
    fi
    
    echo -e "${C_CYAN}────────────────────────────────────────────${C_RESET}"
    read -ep "🔹 Enter a Domain to manage: " DOMAIN
    
    if [[ ! " ${domains[*]} " =~ " ${DOMAIN} " ]]; then
        echo -e "${C_RED}✖ Domain not found!${C_RESET}"
        echo ""; read -ep "Press Enter..."; return
    fi
    
    CONF_FILE=$(grep -RlP "server_name\s+.*$DOMAIN" /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | head -n 1)
    
    echo -e "\n${C_WHITE}What do you want to do with $DOMAIN?${C_RESET}"
    echo -e " ${C_CYAN}1)${C_RESET} Check SSL Status"
    echo -e " ${C_YELLOW}2)${C_RESET} Remove SSL Only (Downgrade to HTTP)"
    echo -e " ${C_RED}3)${C_RESET} Completely Delete Domain Config"
    echo -e " ${C_CYAN}0)${C_RESET} Back"
    read -ep "Choice: " action
    
    if [ "$action" == "1" ]; then
        echo -e "\n${C_BLUE}❖ Scanning SSL Status for $DOMAIN...${C_RESET}"
        echo -e "${C_WHITE}Config File:${C_RESET} $CONF_FILE"
        cert_path=$(grep -m 1 "ssl_certificate " "$CONF_FILE" | awk '{print $2}' | tr -d ';')
        key_path=$(grep -m 1 "ssl_certificate_key " "$CONF_FILE" | awk '{print $2}' | tr -d ';')
        if [[ -n "$cert_path" && -f "$cert_path" ]]; then
            echo -e "${C_GREEN}✔ SSL Active!${C_RESET}"
            echo -e "Certificate: $cert_path"
            echo -e "Key: $key_path"
            openssl x509 -enddate -noout -in "$cert_path"
        else
            echo -e "${C_YELLOW}⚠ No SSL found.${C_RESET}"
        fi
    elif [ "$action" == "2" ]; then
        read -ep "Downgrade to HTTP? (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            auto_backup "pre_downgrade_$DOMAIN"
            EXTRACTED_PORT=$(grep -m 1 -E 'listen [0-9]+;' "$CONF_FILE" | grep -v 'ssl' | awk '{print $2}' | tr -d ';' || echo 80)
            command -v certbot &>/dev/null && certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null
            [ -f ~/.acme.sh/acme.sh ] && { ~/.acme.sh/acme.sh --remove -d "$DOMAIN" 2>/dev/null; rm -rf "/etc/nginx/ssl/$DOMAIN"* 2>/dev/null; }
            cat > "$CONF_FILE" <<EOF
server {
    listen $EXTRACTED_PORT;
    server_name $DOMAIN;
    client_max_body_size 0;
    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;
    error_page 404 /custom_404.html;
    location = /custom_404.html {
        return 200 "Server is ready.";
        add_header Content-Type text/plain;
    }
}
EOF
            nginx -t && systemctl reload nginx
            echo -e "${C_GREEN}✔ Downgraded to HTTP!${C_RESET}"
        fi
    elif [ "$action" == "3" ]; then
        read -ep "⚠ DESTRUCTIVE: Delete $DOMAIN config? (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            auto_backup "pre_delete_$DOMAIN"
            rm -f "$CONF_FILE"
            rm -f "/etc/nginx/sites-available/$DOMAIN"
            rm -rf "/etc/nginx/proxy.d/$DOMAIN"
            command -v certbot &>/dev/null && certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null
            [ -f ~/.acme.sh/acme.sh ] && { ~/.acme.sh/acme.sh --remove -d "$DOMAIN" 2>/dev/null; rm -rf "/etc/nginx/ssl/$DOMAIN"* 2>/dev/null; }
            systemctl reload nginx
            echo -e "${C_GREEN}✔ Domain removed!${C_RESET}"
        fi
    fi
    echo ""; read -ep "Press Enter..."
}

# ============================================================
#  🔀  Add Reverse Proxy
# ============================================================
function add_proxy() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_WHITE}Add Reverse Proxy${C_RESET}                ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    read -ep "🔹 Enter Domain: " DOMAIN
    read -ep "🔹 Enter Internal App Port (e.g., 8080): " PORT
    echo -e "${C_YELLOW}Tip: Use '/' for root path. Sub-paths may break complex SPAs.${C_RESET}"
    read -ep "🔹 Enter Path: " PPATH
    
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
        echo -e "\n${C_WHITE}App type?${C_RESET}"
        echo -e " ${C_CYAN}1)${C_RESET} Black Hub / Custom (with sub_filter rewrites)"
        echo -e " ${C_CYAN}2)${C_RESET} X-UI Panel (direct pass)"
        read -ep "Choice (1/2): " app_type
        
        if [ "$app_type" == "1" ]; then
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
    proxy_set_header Accept-Encoding "";
    sub_filter '<head>' '<head><base href="/$PPATH/">';
    sub_filter 'src="/' 'src="/$PPATH/';
    sub_filter 'href="/' 'href="/$PPATH/';
    sub_filter_once off;
    sub_filter_types text/html text/css application/javascript;
}
EOF
        else
            cat > "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf" <<EOF
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
            echo -e "\n${C_YELLOW}⚠ Set 'Panel url root path' to '/$PPATH/' in X-UI settings!${C_RESET}"
        fi
    fi
    
    if nginx -t; then
        systemctl reload nginx
        echo -e "\n${C_GREEN}✔ Success!${C_RESET}"
    else
        rm -f "$NGINX_PROXY_DIR/$DOMAIN/${PPATH:-root}.conf"
        echo -e "${C_RED}✖ Failed. Reverted.${C_RESET}"
    fi
    echo ""; read -ep "Press Enter..."
}

# ============================================================
#  📃  List Proxies
# ============================================================
function list_proxies() {
    echo -e "\n${C_CYAN}╭──────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_WHITE}List All Configured Proxies${C_RESET}      ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}╰──────────────────────────────────────────╯${C_RESET}"
    
    echo -e "\n${C_BLUE}❖ Script Managed Proxies:${C_RESET}"
    if [ -d "$NGINX_PROXY_DIR" ]; then
        for domain_path in "$NGINX_PROXY_DIR"/*; do
            [ -d "$domain_path" ] || continue
            DOMAIN=$(basename "$domain_path")
            echo -e "  ${C_GREEN}▶ $DOMAIN${C_RESET}"
            for conf_file in "$domain_path"/*.conf; do
                [ -e "$conf_file" ] || continue
                PPATH=$(basename "$conf_file" .conf)
                PORT=$(grep "proxy_pass" "$conf_file" | head -n 1 | sed -E 's/.*:([0-9]+)\/?;.*/\1/')
                if [ "$PPATH" == "root" ]; then
                    echo -e "    ├─ Path: / ➔ Port: $PORT"
                else
                    echo -e "    ├─ Path: /$PPATH ➔ Port: $PORT"
                fi
            done
        done
    fi
    
    echo -e "\n${C_BLUE}❖ Externally Managed Proxies:${C_RESET}"
    EXTERNAL_PROXIES=$(grep -RnE "^\s*proxy_pass" /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | grep -v "$NGINX_PROXY_DIR")
    if [ -n "$EXTERNAL_PROXIES" ]; then
        echo "$EXTERNAL_PROXIES" | awk -F':' '{print "    ├─ "$1" ➔ "$3":"$4}' | sed 's/;//g'
    else
        echo -e "  ${C_YELLOW}None.${C_RESET}"
    fi
    echo ""; read -ep "Press Enter..."
}

function remove_proxy() {
    read -ep "🔹 Domain: " DOMAIN
    read -ep "🔹 Path (or 'root' for /): " PPATH
    PPATH="${PPATH#/}"; PPATH="${PPATH%/}"; [ -z "$PPATH" ] && PPATH="root"
    if [ -f "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf" ]; then
        rm "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf"
        systemctl reload nginx
        echo -e "${C_GREEN}✔ Removed.${C_RESET}"
    else
        echo -e "${C_RED}✖ Not found.${C_RESET}"
    fi
    echo ""; read -ep "Press Enter..."
}

function uninstall_all() {
    read -ep "⚠ DESTRUCTIVE: Purge everything? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        auto_backup "pre_uninstall_FINAL"
        systemctl stop nginx 2>/dev/null
        killall -9 nginx 2>/dev/null
        apt-get purge nginx nginx-common nginx-core certbot python3-certbot-nginx -y
        apt-get autoremove -y
        rm -rf /etc/nginx /var/www/html /etc/letsencrypt ~/.acme.sh /root/.acme.sh
        rm -f /usr/local/bin/black-ssl /usr/bin/black-ssl
        echo -e "${C_GREEN}✔ Cleaned. (Backups kept in $BACKUP_DIR)${C_RESET}"
        exit 0
    fi
}

# ============================================================
#  🎛️  MAIN MENU
# ============================================================
while true; do
    clear
    echo -e "${C_CYAN} ╭──────────────────────────────────────────────────╮"
    echo -e "  │   ${C_WHITE}✨ BLACK SSL MANAGER v2.0 ✨${C_CYAN}                  │"
    echo -e "  │   ${C_MAGENTA}With Backup, Telegram & Firewall${C_CYAN}            │"
    echo -e "  ╰──────────────────────────────────────────────────╯${C_RESET}"
    echo -e "  ${C_GREEN}1${C_RESET}  ➜  Install Nginx & Setup Domain"
    echo -e "  ${C_GREEN}2${C_RESET}  ➜  Add Reverse Proxy (Port ➔ Path)"
    echo -e "  ${C_GREEN}3${C_RESET}  ➜  Domain & SSL Manager"
    echo -e "  ${C_GREEN}4${C_RESET}  ➜  List All Proxies"
    echo -e "  ${C_GREEN}5${C_RESET}  ➜  Remove a Proxy Path"
    echo -e "  ${C_CYAN}─────────── ${C_WHITE}NEW FEATURES${C_CYAN} ───────────${C_RESET}"
    echo -e "  ${C_YELLOW}7${C_RESET}  ➜  Backup & Rollback Manager"
    echo -e "  ${C_YELLOW}8${C_RESET}  ➜  Live Log Viewer"
    echo -e "  ${C_YELLOW}9${C_RESET}  ➜  Firewall Manager (UFW)"
    echo -e "  ${C_YELLOW}10${C_RESET} ➜  Telegram Bot & SSL Alerts"
    echo -e "  ${C_YELLOW}11${C_RESET} ➜  Repair Nginx Configs (Fix duplicates)"
    echo -e "  ${C_CYAN}─────────────────────────────────────${C_RESET}"
    echo -e "  ${C_RED}6${C_RESET}  ➜  Danger: Deep Remove All"
    echo -e "  ${C_WHITE}0${C_RESET}  ➜  Exit"
    read -ep "  Select Option: " choice
    case $choice in
        1) install_nginx_ssl ;;
        2) add_proxy ;;
        3) manage_domains ;;
        4) list_proxies ;;
        5) remove_proxy ;;
        6) uninstall_all ;;
        7) restore_backup ;;
        8) live_logs ;;
        9) manage_firewall ;;
        10) setup_telegram ;;
        11) repair_configs ;;
        0) clear; exit 0 ;;
    esac
done
