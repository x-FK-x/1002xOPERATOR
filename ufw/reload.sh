#!/bin/bash

# UFW Firewall Manager - Reload configuration
# Similar to samba/reload.sh

UFW_CONFIG="/etc/1002xOPERATOR/ufw/settings"
LOGFILE="$UFW_CONFIG/ufw-actions.log"

mkdir -p "$UFW_CONFIG"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Reloading UFW configuration..." | tee -a "$LOGFILE"

# Check if UFW is installed
if ! command -v ufw &>/dev/null; then
    echo "[ERROR] UFW is not installed. Install with: sudo apt install ufw" | tee -a "$LOGFILE"
    exit 1
fi

# Validate UFW syntax (dry run)
echo "[INFO] Validating UFW rules..." | tee -a "$LOGFILE"
sudo ufw show added 2>&1 | grep -q "ERROR" && {
    echo "[ERROR] UFW configuration error detected!" | tee -a "$LOGFILE"
    exit 1
}

# Reload UFW
echo "[INFO] Reloading UFW..." | tee -a "$LOGFILE"
sudo ufw reload 2>/dev/null

# Check if UFW is enabled
if ! sudo ufw status | grep -q "Status: active"; then
    echo "[WARN] UFW is not active. Enabling UFW..." | tee -a "$LOGFILE"
    sudo ufw --force enable 2>/dev/null
fi

# Verify status
if sudo ufw status | grep -q "Status: active"; then
    echo "[SUCCESS] UFW is active and rules reloaded." | tee -a "$LOGFILE"
else
    echo "[ERROR] Failed to reload UFW!" | tee -a "$LOGFILE"
    exit 1
fi

# Display current status
echo "" | tee -a "$LOGFILE"
echo "=== Current UFW Status ===" | tee -a "$LOGFILE"
sudo ufw status | tee -a "$LOGFILE"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] UFW reload completed." | tee -a "$LOGFILE"
