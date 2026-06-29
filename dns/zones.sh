#!/bin/bash
# /etc/1002xOPERATOR/dns/zones.sh
# Manage dnsmasq custom zones:
#   address=/domain/ip  – resolve domain to IP
#   server=/domain/ns   – forward domain to specific nameserver
#   local=/domain/      – local-only domain, no upstream forward

ZONES_FILE="/etc/dnsmasq.d/1002x-custom-zones.conf"

log()   { echo "[INFO] $1"; }
error() { echo "[ERROR] $1"; exit 1; }

if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root."
fi

mkdir -p "$(dirname "$ZONES_FILE")"
[[ ! -f "$ZONES_FILE" ]] && echo "# 1002xOPERATOR – custom zones and forwards" > "$ZONES_FILE"

reload_dns() {
    systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq 2>/dev/null
}

backup() {
    cp "$ZONES_FILE" "${ZONES_FILE}.bak" 2>/dev/null
}

entry_count() {
    grep -vc '^#\|^$' "$ZONES_FILE" 2>/dev/null || echo 0
}

get_entries() {
    grep -v '^#\|^$' "$ZONES_FILE" 2>/dev/null
}

# =========================
# Show all zones
# =========================
show_zones() {
    local entries
    entries=$(get_entries)
    if [[ -z "$entries" ]]; then
        whiptail --msgbox "No custom zones configured." 8 55
        return
    fi

    local msg="Custom zone entries:\n\n"
    while IFS= read -r line; do
        local label
        [[ "$line" =~ ^address= ]] && label="[ADDRESS]"
        [[ "$line" =~ ^server=.+/.+/ ]] && label="[FORWARD]"
        [[ "$line" =~ ^local= ]] && label="[LOCAL  ]"
        [[ -z "$label" ]] && label="[CUSTOM ]"
        msg+="  $label  $line\n"
    done <<< "$entries"

    whiptail --title "Custom DNS Zones" --scrolltext --msgbox "$msg" 22 72
}

# =========================
# Add address= zone
# =========================
add_address() {
    local domain ip

    domain=$(whiptail --inputbox "Domain (e.g. nas.home.lan):" 8 60 3>&1 1>&2 2>&3) || return
    domain="${domain//[^a-zA-Z0-9._-]/}"
    [[ -z "$domain" ]] && { whiptail --msgbox "Invalid domain." 8 50; return; }

    ip=$(whiptail --inputbox "Target IP address:" 8 50 3>&1 1>&2 2>&3) || return
    ip="${ip//[^0-9.]/}"
    [[ -z "$ip" ]] && { whiptail --msgbox "Invalid IP address." 8 50; return; }

    if grep -q "^address=/$domain/" "$ZONES_FILE" 2>/dev/null; then
        whiptail --yesno "address=/$domain/ already exists. Overwrite?" 8 58 || return
        sed -i "/^address=\/$domain\//d" "$ZONES_FILE"
    fi

    backup
    echo "address=/$domain/$ip" >> "$ZONES_FILE"
    reload_dns
    log "Added: address=/$domain/$ip"
    whiptail --msgbox "Added: address=/$domain/$ip\n\nAll queries for $domain return $ip." 10 60
}

# =========================
# Add server= forward zone
# =========================
add_forward() {
    local domain ns

    domain=$(whiptail --inputbox "Domain to forward (e.g. company.internal):" 8 60 \
        3>&1 1>&2 2>&3) || return
    domain="${domain//[^a-zA-Z0-9._-]/}"
    [[ -z "$domain" ]] && { whiptail --msgbox "Invalid domain." 8 50; return; }

    ns=$(whiptail --inputbox "Nameserver IP to forward queries to:" 8 55 3>&1 1>&2 2>&3) || return
    ns="${ns//[^0-9.]/}"
    [[ -z "$ns" ]] && { whiptail --msgbox "Invalid nameserver IP." 8 50; return; }

    if grep -q "^server=/$domain/" "$ZONES_FILE" 2>/dev/null; then
        whiptail --yesno "Forward for $domain already exists. Overwrite?" 8 58 || return
        sed -i "/^server=\/$domain\//d" "$ZONES_FILE"
    fi

    backup
    echo "server=/$domain/$ns" >> "$ZONES_FILE"
    reload_dns
    log "Added: server=/$domain/$ns"
    whiptail --msgbox "Added: server=/$domain/$ns\n\nQueries for $domain forwarded to $ns." 10 60
}

# =========================
# Add local= zone
# =========================
add_local() {
    local domain

    domain=$(whiptail --inputbox "Local-only domain (e.g. home.lan or .lan):" 8 60 \
        3>&1 1>&2 2>&3) || return
    domain="${domain//[^a-zA-Z0-9._-]/}"
    [[ -z "$domain" ]] && { whiptail --msgbox "Invalid domain." 8 50; return; }

    if grep -q "^local=/$domain/" "$ZONES_FILE" 2>/dev/null; then
        whiptail --msgbox "local=/$domain/ already exists." 8 50
        return
    fi

    backup
    echo "local=/$domain/" >> "$ZONES_FILE"
    reload_dns
    log "Added: local=/$domain/"
    whiptail --msgbox "Added: local=/$domain/\n\nQueries for $domain will NOT be forwarded upstream." 10 62
}

# =========================
# Delete zone entry
# =========================
delete_zone() {
    local entries=()
    local idx=1

    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        entries+=("$idx" "$line")
        idx=$((idx+1))
    done < "$ZONES_FILE"

    if [[ ${#entries[@]} -eq 0 ]]; then
        whiptail --msgbox "No entries to delete." 8 50
        return
    fi

    local choice
    choice=$(whiptail --title "Delete Zone Entry" \
        --menu "Select entry to delete:" 20 72 10 \
        "${entries[@]}" 3>&1 1>&2 2>&3) || return

    local line_content
    line_content=$(get_entries | sed -n "${choice}p")

    whiptail --yesno "Delete entry:\n$line_content" 9 62 || return

    backup
    local escaped
    escaped=$(echo "$line_content" | sed 's/[.*[\^$/]/\\&/g')
    sed -i "/^${escaped}$/d" "$ZONES_FILE"

    reload_dns
    log "Deleted: $line_content"
    whiptail --msgbox "Entry deleted." 8 50
}

# =========================
# Edit raw
# =========================
edit_raw() {
    local tmpfile
    tmpfile=$(mktemp)
    cp "$ZONES_FILE" "$tmpfile"

    if command -v nano &>/dev/null; then
        nano "$tmpfile"
    elif command -v vi &>/dev/null; then
        vi "$tmpfile"
    else
        whiptail --msgbox "No text editor found (nano/vi)." 8 50
        rm -f "$tmpfile"
        return
    fi

    whiptail --yesno "Save changes and reload dnsmasq?" 8 50 || { rm -f "$tmpfile"; return; }

    backup
    cp "$tmpfile" "$ZONES_FILE"
    rm -f "$tmpfile"
    reload_dns
    log "Raw zones edit saved."
    whiptail --msgbox "Zones file saved and dnsmasq reloaded." 8 55
}

# =========================
# Main loop
# =========================
while true; do
    count=$(entry_count)

    CHOICE=$(whiptail --title "1002xOPERATOR – DNS Zones [$count entries]" \
        --menu "Select action:" 18 65 7 \
        "show"    "Show all zone entries" \
        "address" "Add address= zone  (domain → IP)" \
        "forward" "Add server= forward (domain → nameserver)" \
        "local"   "Add local= zone    (no upstream forward)" \
        "delete"  "Delete a zone entry" \
        "raw"     "Edit file directly (nano/vi)" \
        "exit"    "Back to menu" \
        3>&1 1>&2 2>&3)

    [[ $? -ne 0 || "$CHOICE" == "exit" ]] && exit 0

    case "$CHOICE" in
        show)    show_zones ;;
        address) add_address ;;
        forward) add_forward ;;
        local)   add_local ;;
        delete)  delete_zone ;;
        raw)     edit_raw ;;
    esac
done
