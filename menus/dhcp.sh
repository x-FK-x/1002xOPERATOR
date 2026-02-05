#!/bin/bash
# dhcp-scripts-menu.sh
# Whiptail-Menü für 1002xOPERATOR DHCP Skripte (sinnvoll sortiert)

BASE_DIR="/etc/1002xOPERATOR/dhcp"

log() { echo "[INFO] $1"; }

# Skripte und Beschreibung
declare -A SCRIPTS
SCRIPTS["firstrun.sh"]="Initial setup script for DHCP Operator"
SCRIPTS["check.sh"]="System and DHCP service checks"
SCRIPTS["dnssettings.sh"]="Configure DNS server and domain"
SCRIPTS["reservations.sh"]="Manage DHCP reservations (add/edit/show/delete)"
SCRIPTS["1to1route.sh"]="Manage static routes and gateway failover"
SCRIPTS["newbegin.sh"]="Reset or reinitialize DHCP Operator configuration"
SCRIPTS["uninstall.sh"]="Remove all DHCP Operator components"

# Menüoptionen in gewünschter Reihenfolge
MENU_ORDER=("firstrun.sh" "check.sh" "dnssettings.sh" "reservations.sh" "1to1route.sh" "newbegin.sh" "uninstall.sh")

# Build menu options
MENU_OPTIONS=()
for SCRIPT in "${MENU_ORDER[@]}"; do
    MENU_OPTIONS+=("$SCRIPT" "${SCRIPTS[$SCRIPT]}")
done

# Show Whiptail menu
CHOICE=$(whiptail --title "1002xOPERATOR DHCP Scripts" \
    --menu "Select a script to run:" 22 80 10 \
    "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)

# Execute the selected script
if [[ -n "$CHOICE" ]]; then
    log "Running $CHOICE..."
    bash "$BASE_DIR/$CHOICE"
else
    log "No script selected. Exiting."
    exit 0
fi
