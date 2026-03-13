#!/bin/bash

BASE="/etc/1002xOPERATOR/ufw/settings"
RULES_FILE="$BASE/ufw-rules.conf"

mkdir -p "$BASE"

# Check if whiptail is installed
if ! command -v whiptail &>/dev/null; then
    echo "Please install whiptail first (apt install whiptail)"
    exit 1
fi

# Get active UFW rules
RULES=()
INDEX=1
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Skip header and separator lines
    [[ "$line" =~ ^To || "$line" =~ ^-- || "$line" =~ ^Status ]] && continue
    
    RULES+=("$INDEX" "$line")
    INDEX=$((INDEX+1))
done < <(sudo ufw status 2>/dev/null)

if [[ ${#RULES[@]} -eq 0 ]]; then
    whiptail --msgbox "No active UFW rules to delete." 8 50
    exit 0
fi

# Select rule to delete
SELECTED=$(whiptail --title "Delete UFW Rule" --menu "Select rule to delete:" 20 70 10 "${RULES[@]}" 3>&1 1>&2 2>&3)
[[ -z "$SELECTED" ]] && exit

# Get the rule
DEL_LINE="${RULES[$((SELECTED*2-1))]}"

# Confirmation
whiptail --yesno "Delete rule:\n\n$DEL_LINE" 10 60
[ $? -ne 0 ] && exit

# Parse and delete
local port=$(echo "$DEL_LINE" | awk '{print $1}')
local action=$(echo "$DEL_LINE" | awk '{print $2}')

# Remove from UFW (try both allow and deny)
sudo ufw delete allow "$port" 2>/dev/null || sudo ufw delete deny "$port" 2>/dev/null

whiptail --msgbox "Rule deleted:\n\n$DEL_LINE" 10 60
