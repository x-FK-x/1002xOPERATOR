#!/bin/bash

# UFW Rule Manager - Add new rule
# Similar to samba/add.sh but for firewall rules

UFW_CONFIG="/etc/1002xOPERATOR/ufw/settings"
RULES_FILE="$UFW_CONFIG/ufw-rules.conf"
BASE="$UFW_CONFIG"

mkdir -p "$UFW_CONFIG"

# Check if whiptail is installed
if ! command -v whiptail &>/dev/null; then
    echo "Please install whiptail first (apt install whiptail)"
    exit 1
fi

# Input: Port number
PORT=$(whiptail --inputbox "Enter port number (e.g., 22, 80, 443):" 10 60 3>&1 1>&2 2>&3) || exit
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    whiptail --msgbox "Invalid port number. Must be 1-65535." 8 50
    exit 1
fi

# Select protocol
PROTOCOL=$(whiptail --title "Select Protocol" --menu "Choose protocol:" 12 50 3 \
    "tcp" "TCP" \
    "udp" "UDP" \
    "both" "TCP and UDP" 3>&1 1>&2 2>&3) || exit

# Select direction
DIRECTION=$(whiptail --title "Select Direction" --menu "Choose rule direction:" 12 50 2 \
    "in" "Incoming (in)" \
    "out" "Outgoing (out)" 3>&1 1>&2 2>&3) || exit

# Source/Destination IP (optional)
SOURCE=$(whiptail --inputbox "Source IP (optional, 'any' for all):" 10 60 "any" 3>&1 1>&2 2>&3) || SOURCE="any"
[ -z "$SOURCE" ] && SOURCE="any"

DEST=$(whiptail --inputbox "Destination IP (optional, 'any' for all):" 10 60 "any" 3>&1 1>&2 2>&3) || DEST="any"
[ -z "$DEST" ] && DEST="any"

# Select allow/deny
ACTION=$(whiptail --title "Select Action" --menu "Allow or deny traffic:" 12 50 2 \
    "allow" "Allow" \
    "deny" "Deny" 3>&1 1>&2 2>&3) || ACTION="allow"

# Confirmation dialog
whiptail --title "Confirm New Rule" --yesno "Add rule:\n\nPort: $PORT\nProtocol: $PROTOCOL\nDirection: $DIRECTION\nSource: $SOURCE\nDest: $DEST\nAction: $ACTION" 12 60
[ $? -ne 0 ] && exit

# Save rule to config file
echo "$PORT $PROTOCOL $DIRECTION $SOURCE $DEST $ACTION" >> "$RULES_FILE"

# Apply rule with UFW
if [ "$PROTOCOL" = "both" ]; then
    sudo ufw $ACTION $PORT/tcp 2>/dev/null
    sudo ufw $ACTION $PORT/udp 2>/dev/null
else
    sudo ufw $ACTION $PORT/$PROTOCOL 2>/dev/null
fi

# Log action
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Added rule: $PORT/$PROTOCOL $DIRECTION $SOURCE->$DEST $ACTION" >> "$UFW_CONFIG/ufw-actions.log"

whiptail --msgbox "Firewall rule created and applied:\n\nPort $PORT/$PROTOCOL ($DIRECTION) - $ACTION" 10 60
