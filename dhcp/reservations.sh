#!/bin/bash
LOGFILE="/var/log/dhcp_reservations.log"
LEASE_FILE="/var/lib/dhcp/dhcpd.leases"
STATIC_CONF="/etc/dhcp/static-hosts.conf"
BACKUP_CONF="/etc/dhcp/static-hosts.bak"

echo "=== DHCP Reservations Script started === $(date)" | tee -a "$LOGFILE"

# Backup erstellen
if [[ -f "$STATIC_CONF" ]]; then
    cp "$STATIC_CONF" "$BACKUP_CONF"
    echo "[INFO] Backup created at $BACKUP_CONF" | tee -a "$LOGFILE"
fi

sanitize_hostname() {
    local hn="$1"
    hn="${hn//[^a-zA-Z0-9_-]/}"
    [[ -z "$hn" ]] && hn="host$RANDOM"
    echo "$hn"
}

# Leases auslesen
LEASES=()
if [[ -f "$LEASE_FILE" ]]; then
    while IFS= read -r line; do
        if [[ $line =~ ^lease\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            CUR_IP="${BASH_REMATCH[1]}"
        elif [[ $line =~ hardware\ ethernet\ ([a-fA-F0-9:]+) ]]; then
            CUR_MAC="${BASH_REMATCH[1]}"
        elif [[ $line =~ client-hostname\ \"([^\"]+)\" ]]; then
            CUR_HOST="${BASH_REMATCH[1]}"
        elif [[ $line =~ ^\} ]]; then
            if [[ -n "$CUR_MAC" && -n "$CUR_IP" ]]; then
                [[ -z "$CUR_HOST" ]] && CUR_HOST="$CUR_MAC"
                LEASES+=("$CUR_IP;$CUR_MAC;$CUR_HOST")
            fi
            CUR_IP=""; CUR_MAC=""; CUR_HOST=""
        fi
    done < "$LEASE_FILE"
    echo "[DEBUG] Total leases found: ${#LEASES[@]}" | tee -a "$LOGFILE"
else
    echo "[WARN] Lease file $LEASE_FILE not found!" | tee -a "$LOGFILE"
fi

ACTION=$(whiptail --title "DHCP Reservations" --menu "Choose action" 20 70 6 \
"1" "Show current reservations" \
"2" "Add reservation" \
"3" "Edit reservation" \
"4" "Delete reservation" \
"5" "Restore backup" 3>&1 1>&2 2>&3)

case "$ACTION" in
"1")
    if [[ -s "$STATIC_CONF" ]]; then
        whiptail --title "Current Reservations" --scrolltext --msgbox "$(cat "$STATIC_CONF")" 20 70
    else
        whiptail --title "Current Reservations" --msgbox "No reservations yet." 10 60
    fi
    ;;
"2")
    OPTIONS=()
    declare -A LEASE_MAP
    for L in "${LEASES[@]}"; do
        IFS=";" read -r IP MAC HOST <<< "$L"
        grep -q "$MAC" "$STATIC_CONF" 2>/dev/null && continue
        OPTIONS+=("$MAC" "$HOST ($IP)")
        LEASE_MAP["$MAC"]="$IP;$HOST"
    done
    if [[ ${#OPTIONS[@]} -eq 0 ]]; then
        whiptail --title "Add Reservation" --msgbox "No free leases available for reservation." 10 60
        exit 0
    fi
    SELECTED=$(whiptail --title "Add Reservation" --menu "Select lease to reserve" 20 70 10 "${OPTIONS[@]}" 3>&1 1>&2 2>&3)
    if [[ -n "$SELECTED" ]]; then
        IFS=";" read -r IP HOST <<< "${LEASE_MAP[$SELECTED]}"
        HOST=$(sanitize_hostname "$HOST")
        echo "host $HOST { hardware ethernet $SELECTED; fixed-address $IP; }" >> "$STATIC_CONF"
        echo "[INFO] Added reservation: $HOST $SELECTED $IP" | tee -a "$LOGFILE"
        whiptail --title "Add Reservation" --msgbox "Reservation added for $HOST ($IP)" 10 60
    fi
    ;;
"3")
    if [[ ! -f "$STATIC_CONF" || ! -s "$STATIC_CONF" ]]; then
        whiptail --title "Edit Reservation" --msgbox "No reservations to edit." 10 60
        exit 0
    fi
    MAP=()
    declare -A EDIT_MAP
    while read -r line; do
        [[ "$line" =~ host\ ([^[:space:]]+) ]] && HOST="${BASH_REMATCH[1]}"
        [[ "$line" =~ hardware\ ethernet\ ([^;]+) ]] && MAC="${BASH_REMATCH[1]}"
        [[ "$line" =~ fixed-address\ ([^;]+) ]] && IP="${BASH_REMATCH[1]}"
        if [[ -n "$HOST" && -n "$MAC" && -n "$IP" ]]; then
            MAP+=("$MAC" "$HOST ($IP)")
            EDIT_MAP["$MAC"]="$HOST;$IP"
            HOST=""; MAC=""; IP=""
        fi
    done < "$STATIC_CONF"
    SELECTED=$(whiptail --title "Edit Reservation" --menu "Select reservation to edit" 20 70 10 "${MAP[@]}" 3>&1 1>&2 2>&3)
    if [[ -n "$SELECTED" ]]; then
        sed -i "/hardware ethernet $SELECTED;/,+2d" "$STATIC_CONF"
        IFS=";" read -r HOST OLD_IP <<< "${EDIT_MAP[$SELECTED]}"
        NEW_IP=$(whiptail --inputbox "Enter new IP for $HOST ($OLD_IP):" 10 60 "$OLD_IP" 3>&1 1>&2 2>&3)
        HOST=$(sanitize_hostname "$HOST")
        echo "host $HOST { hardware ethernet $SELECTED; fixed-address $NEW_IP; }" >> "$STATIC_CONF"
        echo "[INFO] Edited reservation: $HOST $SELECTED $NEW_IP" | tee -a "$LOGFILE"
        whiptail --title "Edit Reservation" --msgbox "Reservation updated." 10 60
    fi
    ;;
"4")
    if [[ ! -f "$STATIC_CONF" || ! -s "$STATIC_CONF" ]]; then
        whiptail --title "Delete Reservation" --msgbox "No reservations to delete." 10 60
        exit 0
    fi
    MAP=()
    declare -A DEL_MAP
    while read -r line; do
        [[ "$line" =~ host\ ([^[:space:]]+) ]] && HOST="${BASH_REMATCH[1]}"
        [[ "$line" =~ hardware\ ethernet\ ([^;]+) ]] && MAC="${BASH_REMATCH[1]}"
        [[ "$line" =~ fixed-address\ ([^;]+) ]] && IP="${BASH_REMATCH[1]}"
        if [[ -n "$HOST" && -n "$MAC" && -n "$IP" ]]; then
            MAP+=("$MAC" "$HOST ($IP)")
            DEL_MAP["$MAC"]="$HOST;$IP"
            HOST=""; MAC=""; IP=""
        fi
    done < "$STATIC_CONF"
    SELECTED=$(whiptail --title "Delete Reservation" --menu "Select reservation to delete" 20 70 10 "${MAP[@]}" 3>&1 1>&2 2>&3)
    if [[ -n "$SELECTED" ]]; then
        sed -i "/hardware ethernet $SELECTED;/,+2d" "$STATIC_CONF"
        echo "[INFO] Deleted reservation for $SELECTED" | tee -a "$LOGFILE"
        whiptail --title "Delete Reservation" --msgbox "Reservation deleted for $SELECTED" 10 60
    fi
    ;;
"5")
    if [[ -f "$BACKUP_CONF" ]]; then
        cp "$BACKUP_CONF" "$STATIC_CONF"
        echo "[INFO] Backup restored from $BACKUP_CONF" | tee -a "$LOGFILE"
        whiptail --title "Restore Backup" --msgbox "Backup restored." 10 60
    else
        whiptail --title "Restore Backup" --msgbox "No backup available." 10 60
    fi
    ;;
esac

# Include nur wenn Datei existiert und nicht leer
if [[ -s "$STATIC_CONF" ]]; then
    if ! grep -q "include.*static-hosts.conf" /etc/dhcp/dhcpd.conf; then
        echo 'include "/etc/dhcp/static-hosts.conf";' >> /etc/dhcp/dhcpd.conf
        echo "[INFO] static-hosts.conf included in dhcpd.conf" | tee -a "$LOGFILE"
    fi
else
    sed -i '/include.*static-hosts.conf/d' /etc/dhcp/dhcpd.conf
    echo "[INFO] static-hosts.conf removed from dhcpd.conf (empty file)" | tee -a "$LOGFILE"
fi

systemctl restart isc-dhcp-server.service
echo "[INFO] DHCP server restarted." | tee -a "$LOGFILE"
echo "=== DHCP Reservations Script finished === $(date)" | tee -a "$LOGFILE"
