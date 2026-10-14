#!/bin/bash
# reset-dhcp.sh – deletes the settings folder and static-hosts* files, then runs firstrun.sh
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "[ERROR] Must be run as root."; exit 1; }

BASE_DIR="/etc/1002xOPERATOR/dhcp"
FIRSTRUN="$BASE_DIR/firstrun.sh"
SETTINGS_DIR="$BASE_DIR/settings"
DHCP_DIR="/etc/dhcp"
DHCPD_CONF="$DHCP_DIR/dhcpd.conf"
STATIC_INCLUDE_RE='^[[:space:]]*include[[:space:]]+"/etc/dhcp/static-hosts\.conf";'

echo "=== DHCP Reset Script ==="
echo "This will delete:"
echo " - $SETTINGS_DIR (incl. saved routes)"
echo " - all $DHCP_DIR/static-hosts* files"
echo " - the static-hosts include line in $DHCPD_CONF"
echo " - the soloroute.sh cronjob"
read -r -p "Type YES to confirm: " CONFIRM

if [[ $CONFIRM != "YES" ]]; then
    echo "[INFO] Reset cancelled."
    exit 0
fi

echo "[INFO] Reset starting: $(date)"

# Settings folder
if [[ -d $SETTINGS_DIR ]]; then
    rm -rf "$SETTINGS_DIR"
    echo "[INFO] Deleted settings folder: $SETTINGS_DIR"
else
    echo "[INFO] Settings folder not found: $SETTINGS_DIR"
fi

# static-hosts* files (also covers the timestamped reservation backups)
shopt -s nullglob
for f in "$DHCP_DIR"/static-hosts*; do
    if [[ -f $f ]]; then
        rm -f "$f"
        echo "[INFO] Deleted DHCP file: $f"
    fi
done
shopt -u nullglob

# Remove the include, otherwise dhcpd fails on the missing file
if [[ -f $DHCPD_CONF ]]; then
    tmp=$(mktemp)
    grep -vE "$STATIC_INCLUDE_RE" "$DHCPD_CONF" > "$tmp" || true
    cat "$tmp" > "$DHCPD_CONF"
    rm -f "$tmp"
    echo "[INFO] Removed static-hosts include from $DHCPD_CONF"
fi

# Remove the soloroute cronjob, its script was just deleted
crontab -l 2>/dev/null | grep -v -F "soloroute.sh" | crontab - || true
echo "[INFO] Removed soloroute.sh cronjob (if present)"

# Start firstrun.sh
if [[ -f $FIRSTRUN ]]; then
    echo "[INFO] Starting firstrun.sh..."
    bash "$FIRSTRUN"
else
    echo "[WARN] firstrun.sh not found! Cannot start."
fi

echo "[INFO] DHCP Reset Script finished: $(date)"
