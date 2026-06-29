#!/bin/bash
# /etc/1002xOPERATOR/dns/upstream.sh
# Manage dnsmasq upstream DNS servers

DNSMASQ_CONF="/etc/dnsmasq.conf"

log()   { echo "[INFO] $1"; }
error() { echo "[ERROR] $1"; exit 1; }

if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root."
fi

# =========================
# Helpers
# =========================
get_servers() {
    grep -E '^server=[0-9]' "$DNSMASQ_CONF" 2>/dev/null | sed 's/^server=//'
}

backup_conf() {
    cp "$DNSMASQ_CONF" "${DNSMASQ_CONF}.bak" 2>/dev/null
}

reload_dns() {
    systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq 2>/dev/null
}

resolve_name() {
    case "$1" in
        1.1.1.1)         echo "Cloudflare Primary" ;;
        1.0.0.1)         echo "Cloudflare Secondary" ;;
        8.8.8.8)         echo "Google Primary" ;;
        8.8.4.4)         echo "Google Secondary" ;;
        9.9.9.9)         echo "Quad9 Primary" ;;
        149.112.112.112) echo "Quad9 Secondary" ;;
        208.67.222.222)  echo "OpenDNS Primary" ;;
        208.67.220.220)  echo "OpenDNS Secondary" ;;
        127.0.0.1)       echo "Localhost" ;;
        *)               echo "Custom" ;;
    esac
}

# =========================
# Show current servers
# =========================
show_servers() {
    local servers
    servers=$(get_servers)
    if [[ -z "$servers" ]]; then
        whiptail --msgbox "No upstream servers configured.\ndnsmasq will use /etc/resolv.conf." 9 55
        return
    fi

    local msg="Current upstream DNS servers:\n\n"
    while IFS= read -r s; do
        msg+="  $s    ($(resolve_name "$s"))\n"
    done <<< "$servers"

    whiptail --title "Upstream DNS Servers" --msgbox "$msg" 16 58
}

# =========================
# Add server
# =========================
add_server() {
    local choice
    choice=$(whiptail --title "Add Upstream DNS" \
        --menu "Select a server to add:" 17 58 7 \
        "1.1.1.1"         "Cloudflare Primary" \
        "1.0.0.1"         "Cloudflare Secondary" \
        "8.8.8.8"         "Google Primary" \
        "8.8.4.4"         "Google Secondary" \
        "9.9.9.9"         "Quad9 Primary" \
        "208.67.222.222"  "OpenDNS Primary" \
        "custom"          "Enter IP manually" \
        3>&1 1>&2 2>&3) || return

    if [[ "$choice" == "custom" ]]; then
        choice=$(whiptail --inputbox "Enter DNS server IP:" 8 50 3>&1 1>&2 2>&3) || return
        choice="${choice//[^0-9.]/}"
    fi

    [[ -z "$choice" ]] && return

    if grep -q "^server=$choice$" "$DNSMASQ_CONF" 2>/dev/null; then
        whiptail --msgbox "Server $choice is already configured." 8 50
        return
    fi

    backup_conf
    echo "server=$choice" >> "$DNSMASQ_CONF"
    reload_dns
    log "Added upstream: $choice"
    whiptail --msgbox "Upstream server $choice added." 8 50
}

# =========================
# Delete server
# =========================
delete_server() {
    local servers
    servers=$(get_servers)
    if [[ -z "$servers" ]]; then
        whiptail --msgbox "No upstream servers configured." 8 50
        return
    fi

    local menu_opts=()
    while IFS= read -r s; do
        menu_opts+=("$s" "$(resolve_name "$s")")
    done <<< "$servers"

    local choice
    choice=$(whiptail --title "Delete Upstream Server" \
        --menu "Select server to remove:" 15 55 6 \
        "${menu_opts[@]}" 3>&1 1>&2 2>&3) || return

    whiptail --yesno "Remove upstream server $choice?" 8 50 || return

    backup_conf
    sed -i "/^server=${choice//./\\.}$/d" "$DNSMASQ_CONF"
    reload_dns
    log "Removed upstream: $choice"
    whiptail --msgbox "Server $choice removed." 8 50
}

# =========================
# Replace all with preset
# =========================
replace_all() {
    local preset
    preset=$(whiptail --title "Replace All Upstream Servers" \
        --menu "Select preset to apply:" 14 55 5 \
        "cloudflare" "1.1.1.1 + 1.0.0.1" \
        "google"     "8.8.8.8 + 8.8.4.4" \
        "quad9"      "9.9.9.9 + 149.112.112.112" \
        "opendns"    "208.67.222.222 + 208.67.220.220" \
        "clear"      "Remove all upstream servers" \
        3>&1 1>&2 2>&3) || return

    whiptail --yesno "Replace ALL current upstream servers with '$preset'?" 8 58 || return

    backup_conf
    sed -i '/^server=[0-9]/d' "$DNSMASQ_CONF"

    case "$preset" in
        cloudflare) printf 'server=1.1.1.1\nserver=1.0.0.1\n' >> "$DNSMASQ_CONF" ;;
        google)     printf 'server=8.8.8.8\nserver=8.8.4.4\n' >> "$DNSMASQ_CONF" ;;
        quad9)      printf 'server=9.9.9.9\nserver=149.112.112.112\n' >> "$DNSMASQ_CONF" ;;
        opendns)    printf 'server=208.67.222.222\nserver=208.67.220.220\n' >> "$DNSMASQ_CONF" ;;
        clear)      log "All upstream servers removed." ;;
    esac

    reload_dns
    whiptail --msgbox "Upstream servers updated: $preset" 8 50
}

# =========================
# Test DNS resolution
# =========================
test_dns() {
    local domain
    domain=$(whiptail --inputbox "Enter domain to resolve:" 8 50 "google.com" 3>&1 1>&2 2>&3) || return
    domain="${domain//[^a-zA-Z0-9._-]/}"
    [[ -z "$domain" ]] && return

    local result
    result=$(dig +short +time=3 "$domain" @127.0.0.1 2>/dev/null \
          || nslookup "$domain" 127.0.0.1 2>/dev/null \
          || echo "(dig/nslookup not available)")

    whiptail --title "DNS Test: $domain" --msgbox "Result:\n\n$result" 14 58
}

# =========================
# Main loop
# =========================
while true; do
    server_count=$(get_servers | grep -c . || echo 0)

    CHOICE=$(whiptail --title "1002xOPERATOR – Upstream DNS [$server_count servers]" \
        --menu "Select action:" 16 58 6 \
        "show"    "Show current upstream servers" \
        "add"     "Add upstream server" \
        "delete"  "Remove upstream server" \
        "replace" "Replace all with preset" \
        "test"    "Test DNS resolution" \
        "exit"    "Back to menu" \
        3>&1 1>&2 2>&3)

    [[ $? -ne 0 || "$CHOICE" == "exit" ]] && exit 0

    case "$CHOICE" in
        show)    show_servers ;;
        add)     add_server ;;
        delete)  delete_server ;;
        replace) replace_all ;;
        test)    test_dns ;;
    esac
done
