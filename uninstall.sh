#!/bin/bash
set -uo pipefail

ROOT_DIR="/etc/1002xOPERATOR"
ARCHIVE_DIR="/root"
SYSTEMD_DIR="/etc/systemd/system"
ISC_DEFAULT="/etc/default/isc-dhcp-server"
WEBUI_SCRIPTS='(portal|dhcp|samba|dns|ufw-webinterface)\.sh'
WEBUI_PORTS='8080|8081|8082|8083|8084'

log()  { echo "[INFO] $1"; }
warn() { echo "[WARN] $1"; }
err()  { echo "[ERROR] $1" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Please run this script as root."

if [[ ! -d $ROOT_DIR ]]; then
    log "$ROOT_DIR does not exist. Nothing to remove."
    exit 0
fi

LAN_INTERFACE=""
if [[ -f $ISC_DEFAULT ]]; then
    LAN_INTERFACE=$(grep -E '^INTERFACESv4=' "$ISC_DEFAULT" | head -n1 | cut -d= -f2- | tr -d '"[:space:]')
fi

echo "Contents of $ROOT_DIR:"
find "$ROOT_DIR" -maxdepth 3 | sed 's|^|  |'
echo
echo "Systemd units to be removed:"
shopt -s nullglob
UNITS=("$SYSTEMD_DIR"/1002x*.service)
shopt -u nullglob
if (( ${#UNITS[@]} == 0 )); then
    echo "  (none)"
else
    for u in "${UNITS[@]}"; do echo "  $u"; done
fi
echo
warn "This removes everything in $ROOT_DIR, including backups and all web interfaces stored there."
read -rp "Type REMOVE to delete $ROOT_DIR permanently: " ANSWER
if [[ $ANSWER != "REMOVE" ]]; then
    log "Cancelled."
    exit 0
fi

ARCHIVE="$ARCHIVE_DIR/1002xOPERATOR-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
if tar -czf "$ARCHIVE" -C / etc/1002xOPERATOR; then
    log "Archive of $ROOT_DIR saved to $ARCHIVE"
else
    err "Could not create archive, nothing was removed."
fi

shopt -s nullglob
for u in "$SYSTEMD_DIR"/1002x*.service; do
    name=$(basename "$u" .service)
    systemctl stop "$name" 2>/dev/null || true
    systemctl disable "$name" 2>/dev/null || true
    rm -f "$u"
    log "Removed unit $name"
done
shopt -u nullglob
systemctl daemon-reload

systemctl stop wan-failover 2>/dev/null || true
systemctl disable wan-failover 2>/dev/null || true
rm -f "$SYSTEMD_DIR/wan-failover.service"
systemctl daemon-reload

systemctl stop isc-dhcp-server 2>/dev/null || true
systemctl disable isc-dhcp-server 2>/dev/null || true
log "isc-dhcp-server stopped and disabled."

pkill -f "/$WEBUI_SCRIPTS( |\$)" 2>/dev/null || true
pkill -f "nc .*-p ($WEBUI_PORTS)( |\$)" 2>/dev/null || true
pkill -f "nc -l ($WEBUI_PORTS)( |\$)" 2>/dev/null || true
sleep 1
pkill -9 -f "/$WEBUI_SCRIPTS( |\$)" 2>/dev/null || true
log "Web interfaces stopped (if they were running)."

rm -rf "$ROOT_DIR"
log "Removed $ROOT_DIR"

echo
warn "The following OS-level configuration was NOT removed and remains on the system:"
echo "  - Live IPv4 address on the LAN interface${LAN_INTERFACE:+ ($LAN_INTERFACE)} (until reboot or: ip -4 addr flush dev $LAN_INTERFACE)"
echo "  - /etc/network/interfaces: LAN stanza written by firstrun.sh"
echo "  - /etc/dhcp/dhcpd.conf, /etc/dhcp/static-hosts*, /etc/dhcp/dhcpd.conf.*.bak"
echo "  - /etc/default/isc-dhcp-server (INTERFACESv4)"
echo "  - isc-dhcp-server service, still installed and disabled"
echo "  - /etc/sysctl.d/99-1002xoperator.conf and /etc/sysctl.conf (IP forwarding, rp_filter)"
echo "  - Live IP forwarding state (until reboot or: sysctl -w net.ipv4.ip_forward=0)"
echo "  - iptables NAT and FORWARD rules, and the saved rules in /etc/iptables/rules.v4"
echo "  - NetworkManager connections: LAN-* access point profiles and WAN WLAN profiles"
echo "  - Root crontab entries for soloroute.sh and dhcp-routes.sh"
echo "  - UFW rules and the default policy, including any rules added through the UFW web interface"
echo "  - Samba configuration in /etc/samba/smb.conf and shared directories"
echo "  - dnsmasq configuration, including /etc/dnsmasq.d/1002x-adblock.conf and local hosts or zones"
echo "  - Installed packages: isc-dhcp-server, network-manager, iptables-persistent, ifupdown, whiptail, ufw, samba, dnsmasq"
echo
warn "Review and clean these up manually if you want the system back to its original state."
log "Uninstall finished. Archive: $ARCHIVE"

exit 0
