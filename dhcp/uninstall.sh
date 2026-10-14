#!/bin/bash
set -uo pipefail

BASE_DIR="/etc/1002xOPERATOR/dhcp"
BACKUP_ROOT="/etc/1002xOPERATOR/backup"
SETTINGS_DIR="$BASE_DIR/settings"
DHCP_DIR="/etc/dhcp"
DHCPD_CONF="$DHCP_DIR/dhcpd.conf"
INTERFACES_FILE="/etc/network/interfaces"
ISC_DEFAULT="/etc/default/isc-dhcp-server"
SYSCTL_FILE="/etc/sysctl.d/99-1002xoperator.conf"
SERVICE="isc-dhcp-server"
ROUTE_MARK="soloroute.sh"
FAILOVER_UNIT="/etc/systemd/system/wan-failover.service"
WEBUI_PATTERN='/dhcp\.sh( |$)'

log()  { echo "[INFO] $1"; }
warn() { echo "[WARN] $1"; }
err()  { echo "[ERROR] $1" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Please run this script as root."
command -v whiptail >/dev/null || err "whiptail is not installed."

[[ -f $ISC_DEFAULT ]] || err "$ISC_DEFAULT not found."
LAN_INTERFACE=$(grep -E '^INTERFACESv4=' "$ISC_DEFAULT" | head -n1 | cut -d= -f2- | tr -d '"[:space:]')
[[ -n $LAN_INTERFACE ]] || err "No LAN interface defined in $ISC_DEFAULT"

service_active() { systemctl is-active --quiet "$SERVICE"; }

notify() {
    log "$1"
    whiptail --title "1002xOPERATOR DHCP Control" --msgbox "$1" 10 70
}

strip_interfaces() {
    awk -v ifc="$1" '
        BEGIN { mb = "# BEGIN 1002xOPERATOR LAN " ifc; me = "# END 1002xOPERATOR LAN " ifc }
        $0 == mb                             { inmark = 1; next }
        inmark                               { if ($0 == me) inmark = 0; next }
        $0 == "# Configuration for " ifc     { next }
        $0 ~ "^allow-hotplug[ \t]+" ifc "$"  { next }
        $0 ~ "^auto[ \t]+" ifc "$"           { next }
        $0 ~ "^iface[ \t]+" ifc "[ \t]"      { skip = 1; next }
        skip && /^[ \t]/                     { next }
        { skip = 0; print }
    ' "$INTERFACES_FILE"
}

toggle_service() {
    local verb
    if service_active; then verb="DEACTIVATE"; else verb="REACTIVATE"; fi
    if ! whiptail --title "Confirmation" --yesno "Are you sure you want to $verb the DHCP service?" 8 60; then
        log "Action cancelled."
        return
    fi

    if [[ $verb == "DEACTIVATE" ]]; then
        if systemctl stop "$SERVICE" && systemctl disable "$SERVICE" >/dev/null 2>&1; then
            notify "DHCP service stopped and disabled."
        else
            notify "Failed to stop the DHCP service. See: journalctl -u $SERVICE"
        fi
    else
        if systemctl enable "$SERVICE" >/dev/null 2>&1 && systemctl start "$SERVICE"; then
            notify "DHCP service enabled and started."
        else
            notify "Failed to start the DHCP service. See: journalctl -u $SERVICE"
        fi
    fi
}

stop_web_ui() {
    if pgrep -f "$WEBUI_PATTERN" >/dev/null 2>&1; then
        pkill -f "$WEBUI_PATTERN" 2>/dev/null || true
        sleep 1
        if pgrep -f "$WEBUI_PATTERN" >/dev/null 2>&1; then
            pkill -9 -f "$WEBUI_PATTERN" 2>/dev/null || true
        fi
        log "Stopped the DHCP web interface."
    else
        log "DHCP web interface is not running."
    fi
}

remove_firewall_rules() {
    local rule wan
    local -a fw_rules=()
    local -A wan_set=()

    mapfile -t fw_rules < <(iptables -S FORWARD 2>/dev/null | grep -E -- "-[io] $LAN_INTERFACE( |\$)")

    for rule in "${fw_rules[@]}"; do
        if [[ $rule =~ -i\ ([^[:space:]]+) && ${BASH_REMATCH[1]} != "$LAN_INTERFACE" ]]; then
            wan_set["${BASH_REMATCH[1]}"]=1
        fi
        if [[ $rule =~ -o\ ([^[:space:]]+) && ${BASH_REMATCH[1]} != "$LAN_INTERFACE" ]]; then
            wan_set["${BASH_REMATCH[1]}"]=1
        fi
    done

    for rule in "${fw_rules[@]}"; do
        log "Removing FORWARD rule: ${rule#-A }"
        iptables ${rule/-A /-D } 2>/dev/null || warn "Could not remove: $rule"
    done

    for wan in "${!wan_set[@]}"; do
        while iptables -t nat -C POSTROUTING -o "$wan" -j MASQUERADE 2>/dev/null; do
            iptables -t nat -D POSTROUTING -o "$wan" -j MASQUERADE
            log "Removed MASQUERADE rule for $wan"
        done
    done

    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || warn "Could not save firewall rules"
    fi
}

remove_hotspot_profiles() {
    local con
    command -v nmcli >/dev/null 2>&1 || return 0
    while IFS= read -r con; do
        [[ -n $con ]] || continue
        nmcli con down "$con" >/dev/null 2>&1 || true
        if nmcli con delete "$con" >/dev/null 2>&1; then
            log "Deleted access point profile: $con"
        fi
    done < <(nmcli -t -f NAME con show 2>/dev/null | grep -E '^LAN-')
}

remove_static_routes() {
    local dest iface _
    [[ -s $SETTINGS_DIR/static-routes.conf ]] || return 0
    while read -r dest iface _; do
        [[ -z $dest || $dest == \#* ]] && continue
        ip route del "$dest" dev "$iface" 2>/dev/null || true
    done < "$SETTINGS_DIR/static-routes.conf"
    log "Removed saved static routes from the kernel."
}

remove_failover() {
    systemctl stop wan-failover 2>/dev/null || true
    systemctl disable wan-failover >/dev/null 2>&1 || true
    if [[ -f $FAILOVER_UNIT ]]; then
        rm -f "$FAILOVER_UNIT"
        log "Removed wan-failover service"
    fi
    systemctl daemon-reload 2>/dev/null || true
}

remove_cron_jobs() {
    crontab -l 2>/dev/null | grep -vE "$ROUTE_MARK|1002xOPERATOR" | crontab - 2>/dev/null || true
    log "Removed 1002xOPERATOR cron jobs."
}

uninstall_operator() {
    local ans purge disable_fwd bak f tmp

    ans=$(whiptail --title "Uninstall DHCP Operator" --inputbox \
        "This removes the DHCP Operator setup: the DHCP service, the web interface, the LAN address and its stanza, the access point profile, NAT and forwarding rules, the sysctl drop-in, the WAN failover service, the static routes and their cron job, and the settings.\n\nA backup of the changed config files is kept in $BACKUP_ROOT.\n\nType UNINSTALL to continue:" \
        16 74 3>&1 1>&2 2>&3) || { log "Uninstall cancelled."; return; }
    if [[ $ans != "UNINSTALL" ]]; then
        log "Uninstall cancelled."
        return
    fi

    purge=0; disable_fwd=0
    if whiptail --title "Uninstall" --defaultno --yesno \
        "Purge the isc-dhcp-server package? Other packages such as NetworkManager and iptables-persistent are kept." 9 70; then
        purge=1
    fi
    if whiptail --title "Uninstall" --defaultno --yesno \
        "Disable IPv4 forwarding now? Choose No if this host forwards traffic for other reasons." 9 70; then
        disable_fwd=1
    fi

    bak="$BACKUP_ROOT/uninstall-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bak" || err "Cannot create backup directory $bak"
    for f in "$INTERFACES_FILE" "$DHCPD_CONF" "$ISC_DEFAULT" "$SYSCTL_FILE" "$SETTINGS_DIR/static-routes.conf"; do
        [[ -f $f ]] && cp "$f" "$bak/$(basename "$f")"
    done
    log "Backup of current configuration: $bak"

    stop_web_ui

    systemctl stop "$SERVICE" 2>/dev/null || true
    systemctl disable "$SERVICE" >/dev/null 2>&1 || true
    log "DHCP service stopped and disabled."

    remove_failover
    remove_static_routes
    remove_cron_jobs
    remove_firewall_rules

    if [[ -f $SYSCTL_FILE ]]; then
        rm -f "$SYSCTL_FILE"
        log "Removed $SYSCTL_FILE"
    fi
    if (( disable_fwd )); then
        sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 && log "IPv4 forwarding disabled."
    fi
    sysctl --system >/dev/null 2>&1 || warn "sysctl --system reported an error"

    remove_hotspot_profiles

    if [[ -f $INTERFACES_FILE ]]; then
        tmp=$(mktemp)
        strip_interfaces "$LAN_INTERFACE" > "$tmp"
        cat "$tmp" > "$INTERFACES_FILE"
        rm -f "$tmp"
        log "Removed $LAN_INTERFACE stanza from $INTERFACES_FILE"
    fi

    shopt -s nullglob
    for f in "$DHCP_DIR"/static-hosts* "$DHCP_DIR"/dhcpd.conf.*.bak; do
        rm -f -- "$f"
        log "Deleted $f"
    done
    shopt -u nullglob

    if [[ -f $DHCPD_CONF ]]; then
        rm -f "$DHCPD_CONF"
        log "Deleted $DHCPD_CONF (backup in $bak)"
    fi

    if [[ -f $ISC_DEFAULT ]]; then
        sed -i 's|^INTERFACESv4=.*|INTERFACESv4=""|' "$ISC_DEFAULT"
    fi

    rm -rf "$SETTINGS_DIR"
    log "Deleted $SETTINGS_DIR"

    if (( purge )); then
        if DEBIAN_FRONTEND=noninteractive apt-get purge -y isc-dhcp-server >/dev/null 2>&1; then
            log "Purged isc-dhcp-server"
        else
            warn "Could not purge isc-dhcp-server"
        fi
    fi

    notify "Uninstall finished. Backup: $bak
The LAN address on $LAN_INTERFACE stays active until reboot. The scripts in $BASE_DIR are kept."
}

while true; do
    if service_active; then DHCP_STATUS="running"; else DHCP_STATUS="stopped"; fi

    ACTION=$(whiptail --title "1002xOPERATOR DHCP Control" \
        --menu "Interface: $LAN_INTERFACE\nCurrent DHCP service status: $DHCP_STATUS\nSelect action:" \
        20 70 3 \
        "1" "Toggle DHCP service (deactivate/reactivate)" \
        "2" "Uninstall the DHCP Operator setup" \
        "3" "Exit" 3>&1 1>&2 2>&3) || break

    case "$ACTION" in
        1) toggle_service ;;
        2) uninstall_operator ;;
        3) break ;;
    esac
done

log "Exiting."
exit 0
