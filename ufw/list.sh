#!/bin/bash

# UFW Rule Manager - List all rules
# Similar to samba/list.sh

UFW_CONFIG="/etc/1002xOPERATOR/ufw/settings"
RULES_FILE="$UFW_CONFIG/ufw-rules.conf"

mkdir -p "$UFW_CONFIG"

# Check if whiptail is installed
if ! command -v whiptail &>/dev/null; then
    echo "Please install whiptail first (apt install whiptail)"
    exit 1
fi

echo "=== UFW Firewall Rules ==="
echo ""

# Print custom rules from config
if [[ -f "$RULES_FILE" && -s "$RULES_FILE" ]]; then
    echo "--- Custom Rules from Config ---"
    cat "$RULES_FILE"
    echo ""
fi

# Print active UFW rules
echo "--- Active UFW Rules ---"
sudo ufw status numbered 2>/dev/null || sudo ufw status 2>/dev/null

echo ""
echo "--- UFW Status ---"
sudo ufw status 2>/dev/null

# Show in whiptail if available
if command -v whiptail &>/dev/null; then
    RULES_OUTPUT=$(cat "$RULES_FILE" 2>/dev/null)
    UFW_OUTPUT=$(sudo ufw status numbered 2>/dev/null)
    
    whiptail --title "UFW Firewall Rules" --scrolltext --msgbox "Custom Rules:\n\n$RULES_OUTPUT\n\nActive UFW Rules:\n\n$UFW_OUTPUT" 25 80
fi
