#!/bin/bash
# /etc/1002xOPERATOR/dns/uninstall.sh
# Remove 1002xOPERATOR DNS configuration
# dnsmasq itself is NOT uninstalled

BASE_DIR="/etc/1002xOPERATOR/dns"
DNSMASQ_D="/etc/dnsmasq.d"
DNSMASQ_CONF="/etc/dnsmasq.conf"

log()   { echo "[INFO] $1"; }
error() { echo "[ERROR] $1"; exit 1; }

if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root."
fi

whiptail --yesno \
"Remove 1002xOPERATOR DNS configuration?

This will remove:
  - $DNSMASQ_D/1002x-local-hosts.conf
  - $DNSMASQ_D/1002x-custom-zones.conf
  - $DNSMASQ_D/1002x-adblock.conf
  - server= entries from dnsmasq.conf
  - $BASE_DIR/blocklists/
  - $BASE_DIR/whitelist.txt

dnsmasq itself will NOT be uninstalled.
A backup will be saved before removal." \
20 65 || exit 0

# =========================
# Backup
# =========================
BACKUP_DIR="$BASE_DIR/backup.$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

[[ -f "$DNSMASQ_D/1002x-local-hosts.conf" ]]  && cp "$DNSMASQ_D/1002x-local-hosts.conf"  "$BACKUP_DIR/"
[[ -f "$DNSMASQ_D/1002x-custom-zones.conf" ]]  && cp "$DNSMASQ_D/1002x-custom-zones.conf" "$BACKUP_DIR/"
[[ -f "$DNSMASQ_D/1002x-adblock.conf" ]]       && cp "$DNSMASQ_D/1002x-adblock.conf"      "$BACKUP_DIR/"
[[ -f "$DNSMASQ_CONF" ]]                        && cp "$DNSMASQ_CONF"                       "$BACKUP_DIR/"
[[ -f "$BASE_DIR/whitelist.txt" ]]              && cp "$BASE_DIR/whitelist.txt"             "$BACKUP_DIR/"

log "Backup saved to $BACKUP_DIR"

# =========================
# Remove config files
# =========================
rm -f "$DNSMASQ_D/1002x-local-hosts.conf"
rm -f "$DNSMASQ_D/1002x-custom-zones.conf"
rm -f "$DNSMASQ_D/1002x-adblock.conf"
rm -rf "$BASE_DIR/blocklists"
rm -f "$BASE_DIR/whitelist.txt"
log "Removed 1002x config files."

# =========================
# Remove server= lines from dnsmasq.conf
# =========================
if [[ -f "$DNSMASQ_CONF" ]]; then
    sed -i '/^server=[0-9]/d' "$DNSMASQ_CONF"
    log "Removed upstream server entries from dnsmasq.conf."
fi

# =========================
# Reload dnsmasq
# =========================
systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq 2>/dev/null
log "dnsmasq reloaded."

whiptail --msgbox \
"1002xOPERATOR DNS config removed.

Backup saved to:
$BACKUP_DIR

dnsmasq is still installed and running." 14 62
