#!/bin/bash

# UFW Policy Manager - Set default policies
# Allows setting DEFAULT_INCOMING, DEFAULT_OUTGOING, DEFAULT_ROUTED

UFW_CONFIG="/etc/1002xOPERATOR/ufw/settings"
POLICY_FILE="$UFW_CONFIG/ufw-policy.conf"
LOGFILE="$UFW_CONFIG/ufw-actions.log"

mkdir -p "$UFW_CONFIG"

# Check if whiptail is installed
if ! command -v whiptail &>/dev/null; then
    echo "Please install whiptail first (apt install whiptail)"
    exit 1
fi

# Read current policies
if [[ -f "$POLICY_FILE" ]]; then
    source "$POLICY_FILE"
fi

# Default values if not set
DEFAULT_INCOMING="${DEFAULT_INCOMING:-DENY}"
DEFAULT_OUTGOING="${DEFAULT_OUTGOING:-ALLOW}"
DEFAULT_ROUTED="${DEFAULT_ROUTED:-DENY}"

while true; do
    CHOICE=$(whiptail --title "UFW Policy Manager" --menu "Set default policies:" 15 60 4 \
        1 "Incoming: $DEFAULT_INCOMING" \
        2 "Outgoing: $DEFAULT_OUTGOING" \
        3 "Routed: $DEFAULT_ROUTED" \
        4 "Exit" 3>&1 1>&2 2>&3)
    
    case "$CHOICE" in
        1)
            NEW_INCOMING=$(whiptail --title "Default Incoming Policy" --menu "Choose policy:" 12 50 3 \
                "DENY" "Block by default" \
                "ALLOW" "Allow by default" \
                "REJECT" "Reject by default" 3>&1 1>&2 2>&3)
            if [[ -n "$NEW_INCOMING" ]]; then
                DEFAULT_INCOMING="$NEW_INCOMING"
                sudo ufw default $NEW_INCOMING incoming 2>/dev/null
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Set default incoming policy to $NEW_INCOMING" >> "$LOGFILE"
                whiptail --msgbox "Default incoming policy set to: $NEW_INCOMING" 8 50
            fi
            ;;
        2)
            NEW_OUTGOING=$(whiptail --title "Default Outgoing Policy" --menu "Choose policy:" 12 50 3 \
                "DENY" "Block by default" \
                "ALLOW" "Allow by default" \
                "REJECT" "Reject by default" 3>&1 1>&2 2>&3)
            if [[ -n "$NEW_OUTGOING" ]]; then
                DEFAULT_OUTGOING="$NEW_OUTGOING"
                sudo ufw default $NEW_OUTGOING outgoing 2>/dev/null
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Set default outgoing policy to $NEW_OUTGOING" >> "$LOGFILE"
                whiptail --msgbox "Default outgoing policy set to: $NEW_OUTGOING" 8 50
            fi
            ;;
        3)
            NEW_ROUTED=$(whiptail --title "Default Routed Policy" --menu "Choose policy:" 12 50 3 \
                "DENY" "Block by default" \
                "ALLOW" "Allow by default" \
                "REJECT" "Reject by default" 3>&1 1>&2 2>&3)
            if [[ -n "$NEW_ROUTED" ]]; then
                DEFAULT_ROUTED="$NEW_ROUTED"
                sudo ufw default $NEW_ROUTED routed 2>/dev/null
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Set default routed policy to $NEW_ROUTED" >> "$LOGFILE"
                whiptail --msgbox "Default routed policy set to: $NEW_ROUTED" 8 50
            fi
            ;;
        4)
            break
            ;;
    esac
done

# Save policies to config file
cat > "$POLICY_FILE" <<EOF
# UFW Default Policies
# Generated: $(date)

DEFAULT_INCOMING=$DEFAULT_INCOMING
DEFAULT_OUTGOING=$DEFAULT_OUTGOING
DEFAULT_ROUTED=$DEFAULT_ROUTED
EOF

echo "[$(date '+%Y-%m-%d %H:%M:%S')] UFW policy configuration saved." >> "$LOGFILE"
