#!/bin/bash
# dhcp-operator-control.sh
# Interaktiv: Toggle DHCP Service oder Löschen mit Statusanzeige und Bestätigung

BASE_DIR="/etc/1002xOPERATOR/dhcp"
DHCP_DIR="/etc/dhcp"
INTERFACES_FILE="/etc/network/interfaces"
ROOT_CRON="/var/spool/cron/crontabs/root"
ISC_DEFAULT="/etc/default/isc-dhcp-server"

log() { echo "[INFO] $1"; }
err() { echo "[ERROR] $1"; exit 1; }

# LAN Interface aus isc-dhcp-server Default-Datei ziehen
if [[ -f "$ISC_DEFAULT" ]]; then
    LAN_INTERFACE="$(grep -E '^INTERFACESv4=' "$ISC_DEFAULT" | cut -d'=' -f2 | tr -d '"')"
fi
[[ -z "$LAN_INTERFACE" ]] && err "No LAN interface defined in $ISC_DEFAULT"

while true; do
    # DHCP-Status live abfragen
    if systemctl is-active --quiet isc-dhcp-server; then
        DHCP_STATUS="running"
    else
        DHCP_STATUS="stopped"
    fi

    # Hauptmenü mit Statusanzeige
    ACTION=$(whiptail --title "1002xOPERATOR DHCP Control" \
        --menu "Current DHCP service status: $DHCP_STATUS\nSelect action:" 20 70 3 \
        "1" "Toggle DHCP service (Deactivate/Reactivate)" \
        "2" "Delete all DHCP Operator data" \
        "3" "Exit" 3>&1 1>&2 2>&3)

    case "$ACTION" in
        1)
            if systemctl is-active --quiet isc-dhcp-server; then
                whiptail --title "Confirmation" --yesno "Are you sure you want to DEACTIVATE the DHCP service?" 8 60
                if [[ $? -eq 0 ]]; then
                    systemctl stop isc-dhcp-server
                    log "DHCP service stopped."
                else
                    log "Deactivation cancelled."
                fi
            else
                whiptail --title "Confirmation" --yesno "Are you sure you want to REACTIVATE the DHCP service?" 8 60
                if [[ $? -eq 0 ]]; then
                    systemctl start isc-dhcp-server
                    log "DHCP service started."
                else
                    log "Reactivation cancelled."
                fi
            fi
            ;;
        2)
            whiptail --title "Confirmation" --yesno "This will DELETE all DHCP Operator data permanently. Continue?" 10 60
            if [[ $? -eq 0 ]]; then
                rm -rf "$BASE_DIR/settings"
                rm -f "$DHCP_DIR/static-hosts.conf" "$DHCP_DIR/static-hosts.bak"
                [[ -f "$ROOT_CRON" ]] && sed -i '/1002xOPERATOR/d' "$ROOT_CRON"
                sed -i "/allow-hotplug $LAN_INTERFACE/d" "$INTERFACES_FILE"
                sed -i "/iface $LAN_INTERFACE inet static/,+4d" "$INTERFACES_FILE"
                systemctl stop isc-dhcp-server
                log "All DHCP Operator data deleted permanently and DHCP service stopped."
            else
                log "Deletion cancelled."
            fi
            ;;
        3|*)
            log "Exiting."
            exit 0
            ;;
    esac
done
