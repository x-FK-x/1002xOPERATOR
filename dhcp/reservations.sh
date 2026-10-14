#!/bin/bash
# reservations.sh – DHCP static host reservation manager
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "[ERROR] Must be run as root."; exit 1; }
command -v whiptail &>/dev/null || { echo "[ERROR] whiptail is not installed."; exit 1; }

LOGFILE="/var/log/dhcp_reservations.log"
LEASE_FILE="/var/lib/dhcp/dhcpd.leases"
DHCPD_CONF="/etc/dhcp/dhcpd.conf"
STATIC_CONF="/etc/dhcp/static-hosts.conf"
BACKUP_KEEP=10
SERVICE="isc-dhcp-server.service"
INCLUDE_LINE="include \"$STATIC_CONF\";"

# Matches one reservation line as written by this script
RESERVATION_RE='^host ([^[:space:]]+) \{ hardware ethernet ([^;]+); fixed-address ([^;]+); \}$'

declare -A LEASE_MAP=()
MENU_ITEMS=()
BK_STATIC=""
BK_DHCPD=""

log() { echo "$1" | tee -a "$LOGFILE"; }

valid_ipv4() {
    local ip=$1 o
    [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

valid_hostname() {
    [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

sanitize_hostname() {
    local hn="${1//[^a-zA-Z0-9-]/}"
    [[ -z $hn ]] && hn="host$RANDOM"
    echo "$hn"
}

# ask_value PROMPT DEFAULT VALIDATOR – repeats until valid, returns 1 on cancel/empty
ask_value() {
    local value
    while true; do
        value=$(whiptail --inputbox "$1" 10 60 "$2" 3>&1 1>&2 2>&3) || return 1
        value=${value// /}
        [[ -z $value ]] && return 1
        if "$3" "$value"; then
            echo "$value"
            return 0
        fi
        whiptail --msgbox "Invalid value: $value" 8 60
    done
}

# Reads leases; last lease per MAC wins
load_leases() {
    LEASE_MAP=()
    if [[ ! -f $LEASE_FILE ]]; then
        log "[WARN] Lease file $LEASE_FILE not found!"
        return 0
    fi
    local line CUR_IP="" CUR_MAC="" CUR_HOST=""
    while IFS= read -r line; do
        if [[ $line =~ ^lease\ ([0-9.]+) ]]; then
            CUR_IP="${BASH_REMATCH[1]}"; CUR_MAC=""; CUR_HOST=""
        elif [[ $line =~ hardware\ ethernet\ ([a-fA-F0-9:]+) ]]; then
            CUR_MAC="${BASH_REMATCH[1],,}"
        elif [[ $line =~ client-hostname\ \"([^\"]+)\" ]]; then
            CUR_HOST="${BASH_REMATCH[1]}"
        elif [[ $line =~ ^\} ]]; then
            if [[ -n $CUR_MAC && -n $CUR_IP ]]; then
                LEASE_MAP["$CUR_MAC"]="$CUR_IP;${CUR_HOST:-$CUR_MAC}"
            fi
            CUR_IP=""; CUR_MAC=""; CUR_HOST=""
        fi
    done < "$LEASE_FILE"
    log "[DEBUG] Unique MACs in lease file: ${#LEASE_MAP[@]}"
}

# Prints "MAC HOST IP" for every reservation
read_reservations() {
    [[ -s $STATIC_CONF ]] || return 0
    local line
    while IFS= read -r line; do
        if [[ $line =~ $RESERVATION_RE ]]; then
            echo "${BASH_REMATCH[2]} ${BASH_REMATCH[1]} ${BASH_REMATCH[3]}"
        fi
    done < "$STATIC_CONF"
    return 0
}

# Fills MENU_ITEMS with MAC / "HOST (IP)" pairs
reservation_menu_items() {
    MENU_ITEMS=()
    local mac host ip
    while read -r mac host ip; do
        MENU_ITEMS+=("$mac" "$host ($ip)")
    done < <(read_reservations)
}

# Backup of both files before a change; keeps the newest BACKUP_KEEP
make_backup() {
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    BK_STATIC="/etc/dhcp/static-hosts.$ts.bak"
    BK_DHCPD="/etc/dhcp/dhcpd.conf.$ts.bak"
    cp "$STATIC_CONF" "$BK_STATIC"
    cp "$DHCPD_CONF" "$BK_DHCPD"
    log "[INFO] Backup created: $BK_STATIC"
    ls -1t /etc/dhcp/static-hosts.*.bak 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | xargs -r rm -f
    ls -1t /etc/dhcp/dhcpd.conf.*.bak 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | xargs -r rm -f
}

latest_backup() {
    ls -1t /etc/dhcp/static-hosts.*.bak 2>/dev/null | head -n1
}

rollback() {
    cp "$BK_STATIC" "$STATIC_CONF"
    cp "$BK_DHCPD" "$DHCPD_CONF"
    log "[WARN] Changes rolled back to backup."
}

# Adds or removes the include line depending on whether reservations exist
sync_include() {
    local tmp
    if [[ -s $STATIC_CONF ]]; then
        if ! grep -qF "$INCLUDE_LINE" "$DHCPD_CONF"; then
            echo "$INCLUDE_LINE" >> "$DHCPD_CONF"
            log "[INFO] static-hosts.conf included in dhcpd.conf"
        fi
    else
        tmp=$(mktemp)
        grep -vF "$INCLUDE_LINE" "$DHCPD_CONF" > "$tmp" || true
        cat "$tmp" > "$DHCPD_CONF"
        rm -f "$tmp"
        log "[INFO] static-hosts.conf removed from dhcpd.conf (empty file)"
    fi
}

# Validates the config before restarting; rolls back on any failure
apply_changes() {
    sync_include
    if ! dhcpd -t -cf "$DHCPD_CONF" >> "$LOGFILE" 2>&1; then
        log "[ERROR] dhcpd configuration test failed. Rolling back, service not restarted."
        rollback
        return 1
    fi
    if ! systemctl restart "$SERVICE"; then
        log "[ERROR] Restart failed. Rolling back and restarting with previous config."
        rollback
        systemctl restart "$SERVICE" || true
        return 1
    fi
    log "[INFO] DHCP server restarted."
    return 0
}

commit_or_report() {
    if apply_changes; then
        whiptail --title "DHCP Reservations" --msgbox "$1" 10 60
    else
        whiptail --title "DHCP Reservations" --msgbox "Change was rolled back. See $LOGFILE for details." 10 60
        exit 1
    fi
}

touch "$STATIC_CONF"
log "=== DHCP Reservations Script started === $(date)"

ACTION=$(whiptail --title "DHCP Reservations" --menu "Choose action" 20 70 6 \
"1" "Show current reservations" \
"2" "Add reservation" \
"3" "Edit reservation" \
"4" "Delete reservation" \
"5" "Restore backup" 3>&1 1>&2 2>&3) || exit 0

case "$ACTION" in
"1")
    if [[ -s $STATIC_CONF ]]; then
        whiptail --title "Current Reservations" --scrolltext --msgbox "$(cat "$STATIC_CONF")" 20 70
    else
        whiptail --title "Current Reservations" --msgbox "No reservations yet." 10 60
    fi
    ;;

"2")
    load_leases
    OPTIONS=()
    for MAC in "${!LEASE_MAP[@]}"; do
        grep -qiF "hardware ethernet $MAC;" "$STATIC_CONF" && continue
        IFS=';' read -r IP HOST <<< "${LEASE_MAP[$MAC]}"
        OPTIONS+=("$MAC" "$HOST ($IP)")
    done
    if (( ${#OPTIONS[@]} == 0 )); then
        whiptail --title "Add Reservation" --msgbox "No free leases available for reservation." 10 60
        exit 0
    fi
    SELECTED=$(whiptail --title "Add Reservation" --menu "Select lease to reserve" 20 70 10 "${OPTIONS[@]}" 3>&1 1>&2 2>&3) || exit 0
    IFS=';' read -r IP HOST <<< "${LEASE_MAP[$SELECTED]}"

    if grep -qF "fixed-address $IP;" "$STATIC_CONF"; then
        whiptail --title "Add Reservation" --msgbox "IP $IP is already reserved." 10 60
        exit 0
    fi

    HOST=$(sanitize_hostname "$HOST")
    HOST=$(ask_value "Hostname for $SELECTED ($IP):" "$HOST" valid_hostname) || exit 0
    if grep -qE "^host $HOST \{" "$STATIC_CONF"; then
        whiptail --title "Add Reservation" --msgbox "Hostname '$HOST' already exists." 10 60
        exit 0
    fi

    make_backup
    echo "host $HOST { hardware ethernet $SELECTED; fixed-address $IP; }" >> "$STATIC_CONF"
    log "[INFO] Added reservation: $HOST $SELECTED $IP"
    commit_or_report "Reservation added for $HOST ($IP)"
    ;;

"3")
    reservation_menu_items
    if (( ${#MENU_ITEMS[@]} == 0 )); then
        whiptail --title "Edit Reservation" --msgbox "No reservations to edit." 10 60
        exit 0
    fi
    SELECTED=$(whiptail --title "Edit Reservation" --menu "Select reservation to edit" 20 70 10 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3) || exit 0

    LINE=$(grep -F "hardware ethernet $SELECTED;" "$STATIC_CONF" | head -n1)
    if [[ ! $LINE =~ $RESERVATION_RE ]]; then
        whiptail --title "Edit Reservation" --msgbox "Could not parse the selected entry." 10 60
        exit 1
    fi
    HOST=${BASH_REMATCH[1]}
    OLD_IP=${BASH_REMATCH[3]}

    # Ask for the new IP first, so a cancel leaves the file untouched
    NEW_IP=$(ask_value "Enter new IP for $HOST ($OLD_IP):" "$OLD_IP" valid_ipv4) || exit 0
    if [[ $NEW_IP != "$OLD_IP" ]] && grep -qF "fixed-address $NEW_IP;" "$STATIC_CONF"; then
        whiptail --title "Edit Reservation" --msgbox "IP $NEW_IP is already reserved." 10 60
        exit 0
    fi

    make_backup
    sed -i "/hardware ethernet ${SELECTED};/d" "$STATIC_CONF"
    echo "host $HOST { hardware ethernet $SELECTED; fixed-address $NEW_IP; }" >> "$STATIC_CONF"
    log "[INFO] Edited reservation: $HOST $SELECTED $NEW_IP"
    commit_or_report "Reservation updated."
    ;;

"4")
    reservation_menu_items
    if (( ${#MENU_ITEMS[@]} == 0 )); then
        whiptail --title "Delete Reservation" --msgbox "No reservations to delete." 10 60
        exit 0
    fi
    SELECTED=$(whiptail --title "Delete Reservation" --menu "Select reservation to delete" 20 70 10 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3) || exit 0

    make_backup
    sed -i "/hardware ethernet ${SELECTED};/d" "$STATIC_CONF"
    log "[INFO] Deleted reservation for $SELECTED"
    commit_or_report "Reservation deleted for $SELECTED"
    ;;

"5")
    # Pick the source before making a new backup, otherwise the new backup would be selected
    SRC=$(latest_backup)
    if [[ -z $SRC ]]; then
        whiptail --title "Restore Backup" --msgbox "No backup available." 10 60
        exit 0
    fi
    make_backup
    cp "$SRC" "$STATIC_CONF"
    log "[INFO] Backup restored from $SRC"
    commit_or_report "Backup restored from $(basename "$SRC")."
    ;;
esac

log "=== DHCP Reservations Script finished === $(date)"
