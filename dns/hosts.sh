#!/bin/bash
# /etc/1002xOPERATOR/dns/hosts.sh
# Manage local DNS host entries (dnsmasq address= directives)

HOSTS_FILE="/etc/dnsmasq.d/1002x-local-hosts.conf"

log()   { echo "[INFO] $1"; }
error() { echo "[ERROR] $1"; exit 1; }

if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root."
fi

mkdir -p "$(dirname "$HOSTS_FILE")"
[[ ! -f "$HOSTS_FILE" ]] && echo "# 1002xOPERATOR – local host entries" > "$HOSTS_FILE"

reload_dns() {
    systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq 2>/dev/null
}

backup() {
    cp "$HOSTS_FILE" "${HOSTS_FILE}.bak" 2>/dev/null
}

entry_count() {
    grep -vc '^#\|^$' "$HOSTS_FILE" 2>/dev/null || echo 0
}

# =========================
# Show all entries
# =========================
show_hosts() {
    local entries
    entries=$(grep -v '^#\|^$' "$HOSTS_FILE" 2>/dev/null)
    if [[ -z "$entries" ]]; then
        whiptail --msgbox "No local host entries configured." 8 55
        return
    fi
    whiptail --title "Local Host Entries" --scrolltext --msgbox "$entries" 22 70
}

# =========================
# Add host entry
# =========================
add_host() {
    local hostname ip

    hostname=$(whiptail --inputbox "Hostname or domain (e.g. printer.home.lan):" 8 60 \
        3>&1 1>&2 2>&3) || return
    hostname="${hostname//[^a-zA-Z0-9._-]/}"
    [[ -z "$hostname" ]] && { whiptail --msgbox "Invalid hostname." 8 50; return; }

    ip=$(whiptail --inputbox "IP address for $hostname:" 8 55 3>&1 1>&2 2>&3) || return
    ip="${ip//[^0-9.]/}"
    [[ -z "$ip" ]] && { whiptail --msgbox "Invalid IP address." 8 50; return; }

    if grep -q "^address=/$hostname/" "$HOSTS_FILE" 2>/dev/null; then
        whiptail --yesno "$hostname already exists. Overwrite?" 8 52 || return
        sed -i "/^address=\/$hostname\//d" "$HOSTS_FILE"
    fi

    local add_ptr=0
    whiptail --yesno "Also add reverse PTR record (IP → hostname)?" 8 55 && add_ptr=1

    backup
    echo "address=/$hostname/$ip" >> "$HOSTS_FILE"

    if [[ "$add_ptr" -eq 1 ]]; then
        local reversed
        reversed=$(echo "$ip" | awk -F. '{print $4"."$3"."$2"."$1}')
        echo "ptr-record=${reversed}.in-addr.arpa,$hostname" >> "$HOSTS_FILE"
        whiptail --msgbox "Added:\n  address=/$hostname/$ip\n  PTR $reversed → $hostname" 10 60
    else
        whiptail --msgbox "Added: address=/$hostname/$ip" 8 55
    fi

    reload_dns
    log "Added: $hostname → $ip"
}

# =========================
# Delete host entry
# =========================
delete_host() {
    local entries=()
    local idx=1

    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        entries+=("$idx" "$line")
        idx=$((idx+1))
    done < "$HOSTS_FILE"

    if [[ ${#entries[@]} -eq 0 ]]; then
        whiptail --msgbox "No entries to delete." 8 50
        return
    fi

    local choice
    choice=$(whiptail --title "Delete Host Entry" \
        --menu "Select entry to delete:" 20 72 10 \
        "${entries[@]}" 3>&1 1>&2 2>&3) || return

    local line_content
    line_content=$(grep -v '^#\|^$' "$HOSTS_FILE" | sed -n "${choice}p")

    whiptail --yesno "Delete entry:\n$line_content" 9 60 || return

    backup
    local real_line
    real_line=$(grep -n "^$(echo "$line_content" | sed 's/[.*[\^$]/\\&/g')$" "$HOSTS_FILE" | head -1 | cut -d: -f1)
    [[ -n "$real_line" ]] && sed -i "${real_line}d" "$HOSTS_FILE"

    reload_dns
    log "Deleted: $line_content"
    whiptail --msgbox "Entry deleted." 8 50
}

# =========================
# Edit file directly
# =========================
edit_raw() {
    local tmpfile
    tmpfile=$(mktemp)
    cp "$HOSTS_FILE" "$tmpfile"

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
    cp "$tmpfile" "$HOSTS_FILE"
    rm -f "$tmpfile"
    reload_dns
    log "Raw edit saved."
    whiptail --msgbox "Hosts file saved and dnsmasq reloaded." 8 55
}

# =========================
# Lookup test
# =========================
test_lookup() {
    local hostname
    hostname=$(whiptail --inputbox "Enter hostname to test:" 8 55 3>&1 1>&2 2>&3) || return
    hostname="${hostname//[^a-zA-Z0-9._-]/}"
    [[ -z "$hostname" ]] && return

    local result
    result=$(dig +short +time=3 "$hostname" @127.0.0.1 2>/dev/null \
          || nslookup "$hostname" 127.0.0.1 2>/dev/null \
          || echo "(dig/nslookup not available)")

    whiptail --title "Lookup: $hostname" --msgbox "Result:\n\n$result" 12 55
}

# =========================
# Main loop
# =========================
while true; do
    count=$(entry_count)

    CHOICE=$(whiptail --title "1002xOPERATOR – Local Hosts [$count entries]" \
        --menu "Select action:" 16 60 6 \
        "show"   "Show all host entries" \
        "add"    "Add host entry (with optional PTR)" \
        "delete" "Delete host entry" \
        "raw"    "Edit file directly (nano/vi)" \
        "test"   "Test hostname lookup" \
        "exit"   "Back to menu" \
        3>&1 1>&2 2>&3)

    [[ $? -ne 0 || "$CHOICE" == "exit" ]] && exit 0

    case "$CHOICE" in
        show)   show_hosts ;;
        add)    add_host ;;
        delete) delete_host ;;
        raw)    edit_raw ;;
        test)   test_lookup ;;
    esac
done
