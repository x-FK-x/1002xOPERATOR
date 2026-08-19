#!/bin/bash
# /etc/1002xOPERATOR/menus/dns.sh
# Whiptail menu for 1002xOPERATOR DNS scripts

BASE_DIR="/etc/1002xOPERATOR/dns"

log() { echo "[INFO] $1"; }

declare -A SCRIPTS
SCRIPTS["firstrun.sh"]="Initial setup – install and configure dnsmasq (+ adblock)"
SCRIPTS["check.sh"]="Status checks, service control and diagnostics"
SCRIPTS["upstream.sh"]="Manage upstream DNS servers"
SCRIPTS["hosts.sh"]="Manage local host entries (address=)"
SCRIPTS["zones.sh"]="Manage custom zones and domain forwards"
SCRIPTS["adblock.sh"]="DNS Adblock – blocklists, whitelist, sinkhole"
SCRIPTS["uninstall.sh"]="Remove 1002xOPERATOR DNS configuration"

MENU_ORDER=(
    "firstrun.sh"
    "check.sh"
    "upstream.sh"
    "hosts.sh"
    "zones.sh"
    "adblock.sh"
    "uninstall.sh"
)

MENU_OPTIONS=()
for SCRIPT in "${MENU_ORDER[@]}"; do
    MENU_OPTIONS+=("$SCRIPT" "${SCRIPTS[$SCRIPT]}")
done

CHOICE=$(whiptail --title "1002xOPERATOR DNS Scripts" \
    --menu "Select a script to run:" 22 72 9 \
    "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)

if [[ -n "$CHOICE" ]]; then
    log "Running $CHOICE..."
    bash "$BASE_DIR/$CHOICE"
else
    log "No script selected. Exiting."
    exit 0
fi
