#!/bin/bash

# UFW Rule Manager - Edit rule
# Similar to samba/edit.sh

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
    whiptail --msgbox "No firewall rules to edit." 8 50
    exit 0
fi

# Build menu from rules file
RULES=()
INDEX=1
declare -A RULE_MAP
while read -r line; do
    [[ -z "$line" ]] && continue
    RULES+=("$INDEX" "$line")
    RULE_MAP[$INDEX]="$line"
    INDEX=$((INDEX+1))
done < "$RULES_FILE"

# Select rule to edit
SELECTED=$(whiptail --title "Edit Firewall Rule" --menu "Select rule to edit:" 20 70 10 "${RULES[@]}" 3>&1 1>&2 2>&3)
[[ -z "$SELECTED" ]] && exit

OLD_RULE="${RULE_MAP[$SELECTED]}"
IFS=' ' read -r OLD_PORT OLD_PROTO OLD_DIR OLD_SRC OLD_DST OLD_ACTION <<< "$OLD_RULE"

# Edit port
NEW_PORT=$(whiptail --inputbox "Edit port number:" 10 60 "$OLD_PORT" 3>&1 1>&2 2>&3) || exit
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
    whiptail --msgbox "Invalid port number. Must be 1-65535." 8 50
    exit 1
fi

# Edit protocol
NEW_PROTO=$(whiptail --title "Select Protocol" --menu "Choose protocol:" 12 50 3 \
    "tcp" "TCP" \
    "udp" "UDP" \
    "both" "TCP and UDP" 3>&1 1>&2 2>&3) || NEW_PROTO="$OLD_PROTO"

# Edit direction
NEW_DIR=$(whiptail --title "Select Direction" --menu "Choose rule direction:" 12 50 2 \
    "in" "Incoming (in)" \
    "out" "Outgoing (out)" 3>&1 1>&2 2>&3) || NEW_DIR="$OLD_DIR"

# Edit source
NEW_SRC=$(whiptail --inputbox "Edit source IP:" 10 60 "$OLD_SRC" 3>&1 1>&2 2>&3) || NEW_SRC="$OLD_SRC"
[ -z "$NEW_SRC" ] && NEW_SRC="any"

# Edit destination
NEW_DST=$(whiptail --inputbox "Edit destination IP:" 10 60 "$OLD_DST" 3>&1 1>&2 2>&3) || NEW_DST="$OLD_DST"
[ -z "$NEW_DST" ] && NEW_DST="any"

# Edit action
NEW_ACTION=$(whiptail --title "Select Action" --menu "Allow or deny traffic:" 12 50 2 \
    "allow" "Allow" \
    "deny" "Deny" 3>&1 1>&2 2>&3) || NEW_ACTION="$OLD_ACTION"

# Confirmation dialog
whiptail --title "Confirm Rule Edit" --yesno "Change rule from:\n\n$OLD_RULE\n\nTo:\n\n$NEW_PORT $NEW_PROTO $NEW_DIR $NEW_SRC $NEW_DST $NEW_ACTION" 14 60
[ $? -ne 0 ] && exit

# Remove old rule from UFW
if [ "$OLD_PROTO" = "both" ]; then
    sudo ufw delete $OLD_ACTION $OLD_PORT/tcp 2>/dev/null
    sudo ufw delete $OLD_ACTION $OLD_PORT/udp 2>/dev/null
else
    sudo ufw delete $OLD_ACTION $OLD_PORT/$OLD_PROTO 2>/dev/null
fi

# Update config file
NEW_RULE="$NEW_PORT $NEW_PROTO $NEW_DIR $NEW_SRC $NEW_DST $NEW_ACTION"
sed -i "${SELECTED}s/.*/\"$NEW_RULE\"/" "$RULES_FILE"
sed -i "s/\"\(.*\)\"/\1/" "$RULES_FILE"

# Add new rule to UFW
if [ "$NEW_PROTO" = "both" ]; then
    sudo ufw $NEW_ACTION $NEW_PORT/tcp 2>/dev/null
    sudo ufw $NEW_ACTION $NEW_PORT/udp 2>/dev/null
else
    sudo ufw $NEW_ACTION $NEW_PORT/$NEW_PROTO 2>/dev/null
fi

# Log action
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Edited rule: '$OLD_RULE' -> '$NEW_RULE'" >> "$UFW_CONFIG/ufw-actions.log"

whiptail --msgbox "Firewall rule updated." 8 50

# Reload firewall
"$BASE/reload.sh"
