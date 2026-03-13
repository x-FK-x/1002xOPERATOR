#!/bin/bash
# /etc/1002xOPERATOR/menus/menu.sh
# Main menu for 1002xOPERATOR collections

MENU_DIR="/etc/1002xOPERATOR/menus"
log() { echo "[INFO] $1"; }

# === Define collections ===
declare -A COLLECTIONS
COLLECTIONS["dhcp.sh"]="DHCP Operator scripts and management tools"
COLLECTIONS["samba.sh"]="Samba Public Standalone Server"
COLLECTIONS["ufw.sh"]="UFW Firewall – Security and network protection"
COLLECTIONS["webgui.sh"]="WebGUI – Portal, Network & Samba (Port 8080-8082)"

# === Menu order ===
MENU_ORDER=("dhcp.sh" "samba.sh" "ufw.sh" "webgui.sh")

# === Build menu options ===
MENU_OPTIONS=()
for SCRIPT in "${MENU_ORDER[@]}"; do
    MENU_OPTIONS+=("$SCRIPT" "${COLLECTIONS[$SCRIPT]}")
done

# === Show Whiptail main menu ===
CHOICE=$(whiptail --title "1002xOPERATOR Main Menu" \
    --menu "Select a script collection to enter:" 15 70 6 \
    "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)

# === Make all scripts executable recursively ===
find /etc/1002xOPERATOR -type f -name "*.sh" -exec chmod +x {} \;

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
