#!/bin/bash
# reset-dhcp.sh – löscht nur settings und static-hosts*, dann startet firstrun.sh

BASE_DIR="/etc/1002xOPERATOR/dhcp"
FIRSTRUN="$BASE_DIR/firstrun.sh"
SETTINGS_DIR="$BASE_DIR/settings"
DHCP_STATIC="$DHCP_DIR/static-hosts*"
DHCP_DIR="/etc/dhcp"

echo "=== DHCP Reset Script ==="
echo "This will delete:"
echo " - $SETTINGS_DIR"
echo " - all $DHCP_DIR/static-hosts* files"
read -p "Type YES to confirm: " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
    echo "[INFO] Reset cancelled."
    exit 0
fi

echo "[INFO] Reset starting: $(date)"

# Lösche settings-Ordner
if [[ -d "$SETTINGS_DIR" ]]; then
    rm -rf "$SETTINGS_DIR"
    echo "[INFO] Deleted settings folder: $SETTINGS_DIR"
else
    echo "[INFO] Settings folder not found: $SETTINGS_DIR"
fi

# Lösche static-hosts* Dateien
for f in "$DHCP_DIR"/static-hosts*; do
    [[ -f "$f" ]] && rm -f "$f" && echo "[INFO] Deleted DHCP file: $f"
done

# Starte firstrun.sh
if [[ -f "$FIRSTRUN" ]]; then
    echo "[INFO] Starting firstrun.sh..."
    bash "$FIRSTRUN"
else
    echo "[WARN] firstrun.sh not found! Cannot start."
fi

echo "[INFO] DHCP Reset Script finished: $(date)"
