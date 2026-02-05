#!/bin/bash
# dhcp-dns-manager.sh – interactive DHCP DNS manager with confirmation dialogs

DHCP_CONF="/etc/dhcp/dhcpd.conf"
TMP_CONF="/tmp/dhcpd.conf.tmp"
BACKUP_CONF="/etc/1002xOPERATOR/dhcp/settings/dhcpd.conf.bak"

mkdir -p /etc/1002xOPERATOR/dhcp/settings

# Prüfen ob whiptail installiert ist
if ! command -v whiptail &>/dev/null; then
    echo "[ERROR] whiptail is not installed."
    exit 1
fi

# Backup-Funktion
backup_conf() {
    [[ -f "$BACKUP_CONF" ]] && echo "[INFO] Removing old backup."
    [[ -f "$BACKUP_CONF" ]] && rm -f "$BACKUP_CONF"
    cp "$DHCP_CONF" "$BACKUP_CONF"
    echo "[INFO] Backup created at $BACKUP_CONF"
}

# Restore-Funktion
restore_conf() {
    if [[ -f "$BACKUP_CONF" ]]; then
        cp "$BACKUP_CONF" "$DHCP_CONF"
        echo "[INFO] Backup restored from $BACKUP_CONF"
        if systemctl is-active --quiet isc-dhcp-server; then
            systemctl restart isc-dhcp-server
            echo "[INFO] DHCP server restarted"
        fi
    else
        echo "[WARN] No backup found"
    fi
}

# Aktuelle Einstellungen auslesen
read_current_settings() {
    CURRENT_DNS=$(awk '/option domain-name-servers/ {gsub(/.*option domain-name-servers /,""); gsub(/;/,""); print $0}' "$DHCP_CONF")
    CURRENT_DOMAIN=$(awk '/option domain-name/ {gsub(/.*option domain-name /,""); gsub(/;/,""); gsub(/"/,""); print $0}' "$DHCP_CONF")
}

while true; do
    read_current_settings
    CHOICE=$(whiptail --title "DHCP DNS Manager" --menu "Select action:" 20 70 6 \
    1 "Show current DNS settings" \
    2 "Edit DNS servers" \
    3 "Edit DNS domain" \
    4 "Restore last backup" \
    5 "Exit" 3>&1 1>&2 2>&3)

    case "$CHOICE" in
    1)
        whiptail --title "Current DHCP DNS Settings" --msgbox "DNS Servers: $CURRENT_DNS\nDNS Domain: $CURRENT_DOMAIN" 12 60
        ;;
    2)
        NEW_DNS=$(whiptail --inputbox "Enter new DNS servers (comma separated, e.g. 8.8.8.8,8.8.4.4):" 10 60 "$CURRENT_DNS" 3>&1 1>&2 2>&3)
        [[ -z "$NEW_DNS" ]] && continue
        if whiptail --title "Confirm DNS change" --yesno "Do you want to set DNS servers to: $NEW_DNS ?" 10 60; then
            backup_conf
            awk -v dns="$NEW_DNS" '/option domain-name-servers/ {sub(/;.*/,";"); print "    option domain-name-servers " dns ";"; next} {print}' "$DHCP_CONF" > "$TMP_CONF"
            mv "$TMP_CONF" "$DHCP_CONF"
            echo "[INFO] DNS servers updated to $NEW_DNS"
            read -p "Press Enter to continue..."
        else
            echo "[CANCELED] DNS change aborted"
            read -p "Press Enter to continue..."
        fi
        ;;
    3)
        NEW_DOMAIN=$(whiptail --inputbox "Enter new DNS domain:" 10 60 "$CURRENT_DOMAIN" 3>&1 1>&2 2>&3)
        [[ -z "$NEW_DOMAIN" ]] && continue
        if whiptail --title "Confirm Domain change" --yesno "Do you want to set DNS domain to: $NEW_DOMAIN ?" 10 60; then
            backup_conf
            awk -v domain="$NEW_DOMAIN" '/option domain-name/ {sub(/;.*/,";"); print "    option domain-name \"" domain "\";"; next} {print}' "$DHCP_CONF" > "$TMP_CONF"
            mv "$TMP_CONF" "$DHCP_CONF"
            echo "[INFO] DNS domain updated to $NEW_DOMAIN"
            read -p "Press Enter to continue..."
        else
            echo "[CANCELED] Domain change aborted"
            read -p "Press Enter to continue..."
        fi
        ;;
    4)
        if whiptail --title "Confirm Restore" --yesno "Do you want to restore the last backup?" 10 60; then
            restore_conf
            read -p "Press Enter to continue..."
        else
            echo "[CANCELED] Restore aborted"
            read -p "Press Enter to continue..."
        fi
        ;;
    5)
        exit 0
        ;;
    esac

    # DHCP-Server prüfen und ggf. neustarten
    if systemctl is-active --quiet isc-dhcp-server; then
        systemctl restart isc-dhcp-server
        echo "[INFO] DHCP server restarted"
    fi
done

