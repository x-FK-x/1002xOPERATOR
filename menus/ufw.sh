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
SCRIPTS["add.sh"]="Add new firewall rule"
SCRIPTS["edit.sh"]="Edit existing rule"
SCRIPTS["delete.sh"]="Delete firewall rule"
SCRIPTS["policy.sh"]="Set default policies (DENY/ALLOW)"
SCRIPTS["logging.sh"]="Configure logging settings"
SCRIPTS["reload.sh"]="Reload UFW configuration"

# Menüoptionen in gewünschter Reihenfolge
MENU_ORDER=("check.sh" "list.sh" "add.sh" "edit.sh" "delete.sh" "policy.sh" "logging.sh" "reload.sh")

# Build menu options
MENU_OPTIONS=()
for SCRIPT in "${MENU_ORDER[@]}"; do
    MENU_OPTIONS+=("$SCRIPT" "${SCRIPTS[$SCRIPT]}")
done

# Show Whiptail menu
CHOICE=$(whiptail --title "1002xOPERATOR UFW Firewall" \
    --menu "Select an action:" 22 80 10 \
    "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)

# Execute the selected script
if [[ -n "$CHOICE" ]]; then
    log "Running $CHOICE..."
    sudo "$BASE_DIR/$CHOICE"
else
    log "No script selected. Exiting."
    exit 0
fi
