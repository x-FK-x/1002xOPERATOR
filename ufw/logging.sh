#!/bin/bash

# UFW Logging Manager - Configure logging settings
# Similar to DHCP dnssettings.sh but for UFW logging

UFW_CONFIG="/etc/1002xOPERATOR/ufw/settings"
LOGGING_FILE="$UFW_CONFIG/ufw-logging.conf"
LOGFILE="$UFW_CONFIG/ufw-actions.log"
UFW_LOG="/var/log/ufw.log"

mkdir -p "$UFW_CONFIG"

# Check if whiptail is installed
if ! command -v whiptail &>/dev/null; then
    echo "Please install whiptail first (apt install whiptail)"
    exit 1
fi

# Read current logging settings
if [[ -f "$LOGGING_FILE" ]]; then
    source "$LOGGING_FILE"
fi

# Default values if not set
LOGLEVEL="${LOGLEVEL:-medium}"

# Backup function
backup_ufw_config() {
    if [[ -f /etc/ufw/ufw.conf ]]; then
        cp /etc/ufw/ufw.conf "/etc/1002xOPERATOR/ufw/settings/ufw.conf.bak"
        echo "[INFO] Backup created at /etc/1002xOPERATOR/ufw/settings/ufw.conf.bak" | tee -a "$LOGFILE"
    fi
}

# Restore function
restore_ufw_config() {
    if [[ -f "/etc/1002xOPERATOR/ufw/settings/ufw.conf.bak" ]]; then
        sudo cp "/etc/1002xOPERATOR/ufw/settings/ufw.conf.bak" /etc/ufw/ufw.conf
        echo "[INFO] Backup restored from /etc/1002xOPERATOR/ufw/settings/ufw.conf.bak" | tee -a "$LOGFILE"
        sudo systemctl restart ufw
    else
        echo "[WARN] No backup found" | tee -a "$LOGFILE"
    fi
}

while true; do
    CHOICE=$(whiptail --title "UFW Logging Manager" --menu "Select action:" 18 70 7 \
        1 "Show current logging level" \
        2 "Set logging level" \
        3 "View UFW log" \
        4 "Clear UFW log" \
        5 "Restore backup" \
        6 "Export log" \
        7 "Exit" 3>&1 1>&2 2>&3)

    case "$CHOICE" in
        1)
            CURRENT_LEVEL=$(sudo ufw logging 2>&1 | grep -oP "(?<=level: )\w+" || echo "unknown")
            whiptail --title "Current Logging Level" --msgbox "Current UFW logging level: $CURRENT_LEVEL" 8 50
            ;;
        2)
            NEW_LEVEL=$(whiptail --title "Set Logging Level" --menu "Choose logging level:" 15 50 6 \
                "off" "No logging" \
                "low" "Log blocked packets only" \
                "medium" "Log blocked packets and invalid packets" \
                "high" "Log all packets" \
                "full" "Full logging with rate limiting" 3>&1 1>&2 2>&3)
            
            if [[ -n "$NEW_LEVEL" ]]; then
                backup_ufw_config
                sudo ufw logging $NEW_LEVEL 2>/dev/null
                LOGLEVEL="$NEW_LEVEL"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] UFW logging level changed to $NEW_LEVEL" >> "$LOGFILE"
                whiptail --msgbox "Logging level changed to: $NEW_LEVEL" 8 50
            fi
            ;;
        3)
            if [[ -f "$UFW_LOG" ]]; then
                LOG_DISPLAY=$(tail -n 30 "$UFW_LOG" 2>/dev/null)
                whiptail --title "UFW Log (Last 30 entries)" --scrolltext --msgbox "$LOG_DISPLAY" 25 100
            else
                whiptail --msgbox "UFW log file not found:\n$UFW_LOG" 8 50
            fi
            ;;
        4)
            if whiptail --title "Clear Log" --yesno "Are you sure you want to clear the UFW log?" 8 50; then
                sudo truncate -s 0 "$UFW_LOG" 2>/dev/null
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] UFW log cleared by user" >> "$LOGFILE"
                whiptail --msgbox "UFW log cleared." 8 50
            fi
            ;;
        5)
            if whiptail --title "Restore Backup" --yesno "Restore UFW configuration from backup?" 8 50; then
                restore_ufw_config
                whiptail --msgbox "UFW configuration restored from backup." 8 50
            fi
            ;;
        6)
            EXPORT_FILE="/tmp/ufw-log-$(date +%Y%m%d-%H%M%S).txt"
            if [[ -f "$UFW_LOG" ]]; then
                sudo cp "$UFW_LOG" "$EXPORT_FILE"
                sudo chmod 644 "$EXPORT_FILE"
                whiptail --msgbox "UFW log exported to:\n$EXPORT_FILE" 8 60
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] UFW log exported to $EXPORT_FILE" >> "$LOGFILE"
            else
                whiptail --msgbox "No UFW log file to export." 8 50
            fi
            ;;
        7)
            break
            ;;
    esac
done

# Save logging settings to config file
cat > "$LOGGING_FILE" <<EOF
# UFW Logging Configuration
# Generated: $(date)

LOGLEVEL=$LOGLEVEL
LOG_FILE=$UFW_LOG
EOF

echo "[$(date '+%Y-%m-%d %H:%M:%S')] UFW logging configuration saved." >> "$LOGFILE"
