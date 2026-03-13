#!/bin/bash
# ufw-menu.sh
# Whiptail-Menü für 1002xOPERATOR UFW Skripte (sinnvoll sortiert)

BASE_DIR="/etc/1002xOPERATOR/ufw"

log() { echo "[INFO] $1"; }

# Check if whiptail is installed
if ! command -v whiptail &>/dev/null; then
    echo "Please install whiptail first (apt install whiptail)"
    exit 1
fi

# Skripte und Beschreibung
declare -A SCRIPTS
SCRIPTS["check.sh"]="Show UFW status and diagnostics"
SCRIPTS["list.sh"]="List all firewall rules"
SCRIPTS["add.sh"]="Allow - Add and allow new rule"
SCRIPTS["block.sh"]="Block - Block port or IP address"
SCRIPTS["delete.sh"]="Delete - Remove firewall rule"
SCRIPTS["edit.sh"]="Edit - Modify existing rule"
SCRIPTS["policy.sh"]="Policies - Set default incoming/outgoing"
SCRIPTS["logging.sh"]="Logging - Configure logging settings"
SCRIPTS["reload.sh"]="Reload - Reload UFW configuration"

# Menüoptionen in gewünschter Reihenfolge
MENU_ORDER=("check.sh" "list.sh" "add.sh" "block.sh" "delete.sh" "edit.sh" "policy.sh" "logging.sh" "reload.sh")

# Build menu options
MENU_OPTIONS=()
for SCRIPT in "${MENU_ORDER[@]}"; do
    MENU_OPTIONS+=("$SCRIPT" "${SCRIPTS[$SCRIPT]}")
done

# Show Whiptail menu
CHOICE=$(whiptail --title "1002xOPERATOR UFW Firewall" \
    --menu "Select an action:" 24 80 11 \
    "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)

# Execute the selected script
if [[ -n "$CHOICE" ]]; then
    log "Running $CHOICE..."
    sudo "$BASE_DIR/$CHOICE"
else
    log "No script selected. Exiting."
    exit 0
fi
