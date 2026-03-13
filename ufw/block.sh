#!/bin/bash

BASE="/etc/1002xOPERATOR/ufw/settings"

mkdir -p "$BASE"

# Check if whiptail is installed
if ! command -v whiptail &>/dev/null; then
    echo "Please install whiptail first (apt install whiptail)"
    exit 1
fi

# Choose what to block
BLOCK_TYPE=$(whiptail --title "Block Rules" --menu "What do you want to block?" 12 50 3 \
    "port" "Block a specific port" \
    "ip" "Block an IP address" \
    "back" "Back to menu" 3>&1 1>&2 2>&3)

[[ -z "$BLOCK_TYPE" || "$BLOCK_TYPE" == "back" ]] && exit

case "$BLOCK_TYPE" in
    port)
        PORT=$(whiptail --inputbox "Enter port number (1-65535):" 10 60 3>&1 1>&2 2>&3) || exit
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            whiptail --msgbox "Invalid port number." 8 50
            exit 1
        fi
        
        PROTOCOL=$(whiptail --title "Select Protocol" --menu "Choose protocol:" 12 50 2 \
            "tcp" "TCP" \
            "udp" "UDP" 3>&1 1>&2 2>&3) || exit
        
        whiptail --yesno "Block $PORT/$PROTOCOL?" 8 50
        if [ $? -eq 0 ]; then
            sudo ufw deny "$PORT/$PROTOCOL" 2>/dev/null
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Blocked port: $PORT/$PROTOCOL" >> "$BASE/ufw-actions.log"
            whiptail --msgbox "✓ Blocked: $PORT/$PROTOCOL" 8 50
        fi
        ;;
    ip)
        IP=$(whiptail --inputbox "Enter IP address or subnet (e.g., 192.168.1.100 or 10.0.0.0/8):" 10 60 3>&1 1>&2 2>&3) || exit
        
        if ! [[ "$IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3} ]]; then
            whiptail --msgbox "Invalid IP address." 8 50
            exit 1
        fi
        
        whiptail --yesno "Block IP: $IP?" 8 50
        if [ $? -eq 0 ]; then
            sudo ufw deny from "$IP" 2>/dev/null
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Blocked IP: $IP" >> "$BASE/ufw-actions.log"
            whiptail --msgbox "✓ Blocked: $IP" 8 50
        fi
        ;;
esac
