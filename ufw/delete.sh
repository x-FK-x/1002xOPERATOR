#!/bin/bash

# UFW Rule Manager - Delete rule
# Similar to samba/delete.sh

UFW_CONFIG="/etc/1002xOPERATOR/ufw/settings"
RULES_FILE="$UFW_CONFIG/ufw-rules.conf"
BASE="$UFW_CONFIG"

mkdir -p "$UFW_CONFIG"

# Check if whiptail is installed
if ! command -v whiptail &>/dev/null; then
    echo "Please install whiptail first (apt install whiptail)"
    exit 1
fi

# Check if rules file exists and has content
if [[ ! -f "$RULES_FILE" || ! -s "$RULES_FILE" ]]; then
    whiptail --msgbox "No firewall rules to delete." 8 50
    exit 0
fi

# Build menu from rules file
RULES=()
INDEX=1
while read -r line; do
    [[ -z "$line" ]] && continue
    RULES+=("$INDEX" "$line")
    INDEX=$((INDEX+1))
done < "$RULES_FILE"

# Select rule to delete
SELECTED=$(whiptail --title "Delete Firewall Rule" --menu "Select rule to delete:" 20 70 10 "${RULES[@]}" 3>&1 1>&2 2>&3)
[[ -z "$SELECTED" ]] && exit

# Get the rule
DEL_LINE=$(sed -n "${SELECTED}p" "$RULES_FILE")
IFS=' ' read -r PORT PROTO DIR SRC DST ACTION <<< "$DEL_LINE"

# Confirmation
whiptail --yesno "Delete rule:\n\n$DEL_LINE" 10 60
[ $? -ne 0 ] && exit

# Remove from config
sed -i "${SELECTED}d" "$RULES_FILE"

# Remove from UFW
if [ "$PROTO" = "both" ]; then
    sudo ufw delete $ACTION $PORT/tcp 2>/dev/null
    sudo ufw delete $ACTION $PORT/udp 2>/dev/null
else
    sudo ufw delete $ACTION $PORT/$PROTO 2>/dev/null
fi

# Log action
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deleted rule: $DEL_LINE" >> "$UFW_CONFIG/ufw-actions.log"

whiptail --msgbox "Firewall rule deleted:\n\n$DEL_LINE" 10 60

# Reload firewall
"$BASE/reload.sh"
