#!/bin/bash
# /etc/1002xOPERATOR/menu.sh

MENU_DIR="/etc/1002xOPERATOR/menus"

log() { echo "[INFO] $1"; }

# === Define collections ===
declare -A COLLECTIONS
COLLECTIONS["dhcp.sh"]="DHCP Operator scripts and management tools"
COLLECTIONS["samba.sh"]="Samba Public Standalone Server"

# === Menu order ===
MENU_ORDER=("dhcp.sh" "samba.sh")

# === Build menu options ===
MENU_OPTIONS=()
for SCRIPT in "${MENU_ORDER[@]}"; do
    MENU_OPTIONS+=("$SCRIPT" "${COLLECTIONS[$SCRIPT]}")
done

# === Show Whiptail main menu ===
CHOICE=$(whiptail --title "1002xOPERATOR Main Menu" \
    --menu "Select a script collection to enter:" 15 70 5 \
    "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)

# === Execute the selected collection ===
if [[ -n "$CHOICE" ]]; then
    if [[ -x "$MENU_DIR/$CHOICE" ]]; then
        log "Entering $CHOICE..."
        bash "$MENU_DIR/$CHOICE"
    else
        log "Collection script $CHOICE not found or not executable."
        exit 1
    fi
else
    log "No collection selected. Exiting."
    exit 0
fi
