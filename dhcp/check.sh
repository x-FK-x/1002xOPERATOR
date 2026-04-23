#!/bin/bash
# check.sh – Network setup checker with Multi-WAN priority + Failover (ping + link)

set -e

DHCP_CONFIG="/etc/default/isc-dhcp-server"
FOLDERSETTINGS="/etc/1002xOPERATOR/dhcp/settings"
PRIORITY_FILE="$FOLDERSETTINGS/wan-priority.list"
FAILOVER_SCRIPT="$FOLDERSETTINGS/wan-failover.sh"
FAILOVER_STATE="$FOLDERSETTINGS/wan-failover.state"
FAILOVER_LOG="/var/log/wan-failover.log"

PING_TARGETS=("8.8.8.8" "1.1.1.1" "9.9.9.9")
PING_COUNT=3
PING_TIMEOUT=2

log()  { echo "[INFO] $1"; }
warn() { echo "[WARN] $1"; }
ask()  { read -rp "[QUESTION] $1 [y/N]: " reply; [[ "$reply" =~ ^[Yy]$ ]]; }

# -------------------------------------------------
# CLEANUP – reset all previous configuration
# -------------------------------------------------
log "Cleaning up previous configuration..."

# Stop and disable failover daemon
systemctl stop wan-failover 2>/dev/null || true
systemctl disable wan-failover 2>/dev/null || true
rm -f /etc/systemd/system/wan-failover.service
systemctl daemon-reload 2>/dev/null || true

# Remove generated scripts so they get regenerated fresh
rm -f "$FOLDERSETTINGS/dhcp-routes.sh"
rm -f "$FOLDERSETTINGS/wan-failover.sh"

log "Cleanup complete."

log "Detecting network interfaces..."
mapfile -t INTERFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -v lo)

LAN_INTERFACE=$(grep -E '^INTERFACESv4=' "$DHCP_CONFIG" | cut -d'"' -f2)
[[ -z "$LAN_INTERFACE" ]] && { log "No LAN interface defined in DHCP config."; exit 1; }
! ip link show "$LAN_INTERFACE" &>/dev/null && { log "LAN interface $LAN_INTERFACE does not exist."; exit 1; }
LAN_IP=$(ip -o -4 addr show "$LAN_INTERFACE" | awk '{print $4}' | cut -d/ -f1)
[[ -z "$LAN_IP" ]] && { log "LAN interface $LAN_INTERFACE has no IPv4 address."; exit 1; }
log "Using LAN interface from DHCP config: $LAN_INTERFACE with IP $LAN_IP"

WAN_INTERFACES=()
for iface in "${INTERFACES[@]}"; do
    [[ "$iface" != "$LAN_INTERFACE" ]] && WAN_INTERFACES+=("$iface")
done

ACTIVE_WAN=()
for iface in "${WAN_INTERFACES[@]}"; do
    IP=$(ip -o -4 addr show "$iface" 2>/dev/null | awk 'NR==1 {print $4}' | cut -d/ -f1)
    if [[ -z "$IP" ]]; then log "Skipping $iface – no IPv4 address assigned"; continue; fi
    GW=$(ip route show dev "$iface" | awk '/default/ {print $3}' | head -n1)
    log "Detected WAN interface: $iface with IP $IP and Gateway ${GW:-none}"
    ACTIVE_WAN+=("$iface")
done
log "Detected WAN interfaces: ${ACTIVE_WAN[*]}"

if (( ${#ACTIVE_WAN[@]} > 1 )); then
    warn "Multiple WAN interfaces detected: ${ACTIVE_WAN[*]}"
    RP_ALL=$(sysctl -n net.ipv4.conf.all.rp_filter)
    RP_DEF=$(sysctl -n net.ipv4.conf.default.rp_filter)
    [[ "$RP_ALL" -ne 0 || "$RP_DEF" -ne 0 ]] && warn "rp_filter enabled – asymmetric routing likely"
    warn "Multi-WAN without explicit priorities may break forwarding"

    if ask "Configure WAN priority + Failover now?"; then
        SELECTED_WAN=()
        REMAINING_WAN=("${ACTIVE_WAN[@]}")
        while (( ${#REMAINING_WAN[@]} > 0 )); do
            echo; echo "Select WAN interface for next priority:"
            select iface in "${REMAINING_WAN[@]}"; do
                [[ -n "$iface" ]] || continue
                SELECTED_WAN+=("$iface")
                NEW=()
                for r in "${REMAINING_WAN[@]}"; do [[ "$r" != "$iface" ]] && NEW+=("$r"); done
                REMAINING_WAN=("${NEW[@]}")
                break
            done
        done

        mkdir -p "$FOLDERSETTINGS"
        echo "${SELECTED_WAN[@]}" > "$PRIORITY_FILE"
        log "WAN priority saved to $PRIORITY_FILE"

        echo
        echo "Failover mode options:"
        echo "  1) Active failover – ping + link check, switches default route [recommended]"
        echo "  2) Metric-based only – kernel picks lowest metric active route"
        read -rp "Select mode [1/2] (default: 1): " FAILOVER_MODE_INPUT
        case "$FAILOVER_MODE_INPUT" in
            2) FAILOVER_MODE="1" ;;
            *) FAILOVER_MODE="2" ;;
        esac

        DHCP_SCRIPT="$FOLDERSETTINGS/dhcp-routes.sh"
cat > "$DHCP_SCRIPT" <<'ROUTEEOF'
#!/bin/bash
PRIORITY_FILE="/etc/1002xOPERATOR/dhcp/settings/wan-priority.list"
LOGFILE="/var/log/wan-failover.log"
log_r() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [route-fixer] $1" | tee -a "$LOGFILE"; }
[[ ! -f "$PRIORITY_FILE" ]] && log_r "Priority file not found." && exit 0
LAST_LINE=$(tail -n1 "$PRIORITY_FILE")
read -ra WAN_IFACES <<< "$LAST_LINE"
VALID_IFACES=()
for entry in "${WAN_IFACES[@]}"; do
    ip link show "$entry" &>/dev/null && VALID_IFACES+=("$entry") || log_r "Skipping invalid: '$entry'"
done
[[ ${#VALID_IFACES[@]} -eq 0 ]] && log_r "No valid interfaces." && exit 0
log_r "Processing: ${VALID_IFACES[*]}"
STATE_FILE="/etc/1002xOPERATOR/dhcp/settings/wan-failover.state"
METRIC=100
for iface in "${VALID_IFACES[@]}"; do
    ip link show "$iface" | grep -q "state UP" || { log_r "$iface DOWN, skipping."; continue; }
    # Skip suppressed interfaces – failover daemon manages their routes
    grep -q "^SUPPRESSED $iface " "$STATE_FILE" 2>/dev/null && { log_r "$iface suppressed, skipping route fix."; METRIC=$((METRIC + 100)); continue; }
    GW=$(ip route show dev "$iface" | awk '/default/ {print $3}' | head -n1)
    if [[ -z "$GW" ]]; then
        # Try DHCP lease file for real gateway
        IP_ADDR=$(ip -4 addr show dev "$iface" | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
        # Try NetworkManager
        GW=$(nmcli -g IP4.GATEWAY device show "$iface" 2>/dev/null | head -n1)
        # Try reading from ip route table (any route, not just default)
        [[ -z "$GW" ]] && GW=$(ip route show dev "$iface" | awk '/via/ {print $3}' | head -n1)
    fi
    [[ -z "$GW" ]] && log_r "No gateway found for $iface – skipping (no .1 fallback to avoid wrong gateway)." && continue
    # Remove ALL default routes for this interface (DHCP proto or any duplicate)
    while IFS= read -r route; do
        via=$(echo "$route" | awk '{print $3}')
        mt=$(echo "$route" | awk '/metric/{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')
        [[ -z "$via" ]] && continue
        [[ "$via" == "$GW" && "${mt:-0}" == "$METRIC" ]] && continue
        ip route delete default via "$via" dev "$iface" ${mt:+metric $mt} 2>/dev/null && \
            log_r "Removed duplicate default via $via dev $iface ${mt:+metric $mt}" || true
    done < <(ip route show default dev "$iface")
    ip route replace default via "$GW" dev "$iface" metric "$METRIC"
    log_r "Set default via $GW dev $iface metric $METRIC"
    # Remove ALL remaining default routes for this interface that are not our clean one
    while IFS= read -r route; do
        via=$(echo "$route" | awk '{print $3}')
        mt=$(echo "$route" | awk '/metric/{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')
        [[ -z "$via" ]] && continue
        [[ "$via" == "$GW" && "${mt:-0}" == "$METRIC" ]] && continue
        ip route delete default via "$via" dev "$iface" ${mt:+metric $mt} 2>/dev/null && \
            log_r "Removed stale default via $via dev $iface ${mt:+metric $mt}" || true
    done < <(ip route show default dev "$iface")
    METRIC=$((METRIC + 100))
done
ROUTEEOF
        chmod +x "$DHCP_SCRIPT"
        log "Route fixer created at $DHCP_SCRIPT"

        if [[ "$FAILOVER_MODE" == "2" ]]; then
cat > "$FAILOVER_SCRIPT" <<'FAILEOF'
#!/bin/bash
# wan-failover.sh – Active WAN Failover (ifdown/ifup + ping check, every 30s)
# Fährt ausgefallene Interfaces per ifdown herunter und versucht alle 30s
# per ifup + Ping-Test sie wieder online zu bringen.

PRIORITY_FILE="/etc/1002xOPERATOR/dhcp/settings/wan-priority.list"
STATIC_ROUTES_FILE="/etc/1002xOPERATOR/dhcp/settings/static-routes.conf"
SUSPENDED_ROUTES_FILE="/etc/1002xOPERATOR/dhcp/settings/static-routes.suspended"
STATE_FILE="/etc/1002xOPERATOR/dhcp/settings/wan-failover.state"
LOGFILE="/var/log/wan-failover.log"
PING_TARGETS=("8.8.8.8" "1.1.1.1" "9.9.9.9")
PING_COUNT=3
PING_TIMEOUT=2

log_fo() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"; }

# ------------------------------------------------------------------
# check_wan – Gibt 0 zurück wenn Interface online und Ping erfolgreich
# ------------------------------------------------------------------
check_wan() {
    local iface="$1"
    ip link show "$iface" 2>/dev/null | grep -q "state UP" || return 1
    local ip
    ip=$(ip -4 addr show dev "$iface" | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
    [[ -z "$ip" ]] && return 1
    local gw
    gw=$(ip route show dev "$iface" | awk '/default/ {print $3}' | head -n1)
    # Kein Gateway in der Routingtabelle → gespeicherten Gateway aus State verwenden
    [[ -z "$gw" ]] && gw=$(grep "^SUPPRESSED $iface " "$STATE_FILE" 2>/dev/null | awk '{print $3}' | head -n1)
    # Kein .1-Fallback – falscher Gateway ist schlimmer als kein Check
    [[ -z "$gw" ]] && { log_fo "[$iface] No gateway found, skipping check"; return 1; }
    ping -c 1 -W "$PING_TIMEOUT" -I "$iface" "$gw" &>/dev/null || { log_fo "[$iface] Gateway $gw unreachable"; return 1; }
    local ok=0
    for target in "${PING_TARGETS[@]}"; do
        ping -c "$PING_COUNT" -W "$PING_TIMEOUT" -I "$iface" "$target" &>/dev/null && ok=1 && break
    done
    [[ "$ok" -eq 1 ]] || { log_fo "[$iface] No internet connectivity"; return 1; }
    return 0
}

# ------------------------------------------------------------------
# suppress_interface – Interface per ifdown herunterfahren + State merken
# ------------------------------------------------------------------
suppress_interface() {
    local iface="$1"
    # Bereits unterdrückt → nichts tun
    grep -q "^SUPPRESSED $iface " "$STATE_FILE" 2>/dev/null && return 0

    local route_info gw metric
    route_info=$(ip route show default dev "$iface" | head -n1)
    gw=$(echo "$route_info" | awk '{print $3}')
    metric=$(echo "$route_info" | awk '/metric/ {for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')
    [[ -z "$metric" ]] && metric=100

    # State VOR ifdown speichern – danach sind IP/Route weg
    echo "SUPPRESSED $iface $gw $metric" >> "$STATE_FILE"
    log_fo "SUPPRESS: Fahre $iface per ifdown herunter (war via $gw metric $metric)"

    # Interface sauber herunterfahren
    ifdown "$iface" 2>/dev/null \
        && log_fo "SUPPRESS: ifdown $iface erfolgreich" \
        || {
            log_fo "SUPPRESS: ifdown $iface fehlgeschlagen – entferne Route manuell"
            ip route del default via "$gw" dev "$iface" metric "$metric" 2>/dev/null || true
        }
}

# ------------------------------------------------------------------
# restore_interface – Interface per ifup starten, Ping prüfen, Route setzen
# ------------------------------------------------------------------
restore_interface() {
    local iface="$1"
    local entry
    entry=$(grep "^SUPPRESSED $iface " "$STATE_FILE" 2>/dev/null | head -n1)
    [[ -z "$entry" ]] && return 0

    local saved_gw saved_metric
    saved_gw=$(echo "$entry"     | awk '{print $3}')
    saved_metric=$(echo "$entry" | awk '{print $4}')

    log_fo "RESTORE: Starte $iface per ifup neu..."
    ifup "$iface" 2>/dev/null \
        && log_fo "RESTORE: ifup $iface erfolgreich" \
        || log_fo "RESTORE: ifup $iface fehlgeschlagen – versuche Route manuell"

    # Warten bis DHCP-Zuweisung / Link-Negotiation abgeschlossen ist
    sleep 4

    # Prüfen ob Interface eine IP bekommen hat
    local live_ip
    live_ip=$(ip -4 addr show dev "$iface" | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
    if [[ -z "$live_ip" ]]; then
        log_fo "RESTORE: $iface hat nach ifup keine IP – bleibt suppressed"
        return 1
    fi

    # Aktuellen Gateway bevorzugen, Fallback auf gespeicherten
    local live_gw
    live_gw=$(ip route show dev "$iface" | awk '/default/ {print $3}' | head -n1)
    local gw="${live_gw:-$saved_gw}"

    # Default-Route sicherstellen
    if [[ -n "$gw" ]]; then
        ip route replace default via "$gw" dev "$iface" metric "$saved_metric" 2>/dev/null \
            && log_fo "RESTORE: Default-Route via $gw dev $iface metric $saved_metric gesetzt" \
            || log_fo "RESTORE: Route konnte nicht gesetzt werden (via $gw dev $iface)"
    else
        log_fo "RESTORE: Kein Gateway verfügbar für $iface nach ifup"
        return 1
    fi

    # Ping-Test – erst bei Erfolg aus dem State entfernen
    if check_wan "$iface"; then
        log_fo "RESTORE: $iface Ping erfolgreich – Interface ist wieder online"
        grep -v "^SUPPRESSED $iface " "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
        return 0
    else
        log_fo "RESTORE: $iface nach ifup immer noch nicht erreichbar – bleibt suppressed"
        # Route wieder entfernen, damit kein Traffic über totes Interface läuft
        ip route del default via "$gw" dev "$iface" metric "$saved_metric" 2>/dev/null || true
        return 1
    fi
}

# ------------------------------------------------------------------
# suspend_static_routes / restore_static_routes
# ------------------------------------------------------------------
suspend_static_routes() {
    local failed_iface="$1"
    [[ ! -f "$STATIC_ROUTES_FILE" ]] && return
    touch "$SUSPENDED_ROUTES_FILE"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        read -r dest iface gw <<< "$line"
        [[ "$iface" != "$failed_iface" ]] && continue
        grep -qxF "$line" "$SUSPENDED_ROUTES_FILE" 2>/dev/null \
            || { echo "$line" >> "$SUSPENDED_ROUTES_FILE"; log_fo "STATIC-ROUTE SUSPENDED: $dest via $iface ($gw)"; }
        ip route del "$dest" dev "$iface" 2>/dev/null && log_fo "STATIC-ROUTE REMOVED: $dest dev $iface" || true
    done < "$STATIC_ROUTES_FILE"
}

restore_static_routes() {
    local recovered_iface="$1"
    [[ ! -f "$SUSPENDED_ROUTES_FILE" ]] && return
    local remaining=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        read -r dest iface gw <<< "$line"
        if [[ "$iface" != "$recovered_iface" ]]; then remaining+=("$line"); continue; fi
        local live_gw
        live_gw=$(ip route show dev "$iface" | awk '/default/ {print $3}' | head -n1)
        [[ -z "$live_gw" ]] && live_gw="$gw"
        ip route replace "$dest" via "$live_gw" dev "$iface" 2>/dev/null && \
            log_fo "STATIC-ROUTE RESTORED: $dest via $iface ($live_gw)" || \
            log_fo "STATIC-ROUTE RESTORE FAILED: $dest via $iface ($live_gw)"
    done < "$SUSPENDED_ROUTES_FILE"
    if [[ ${#remaining[@]} -gt 0 ]]; then
        printf '%s\n' "${remaining[@]}" > "$SUSPENDED_ROUTES_FILE"
    else
        truncate -s 0 "$SUSPENDED_ROUTES_FILE"
    fi
}

# ------------------------------------------------------------------
# ensure_iptables – NAT & FORWARD Regeln sicherstellen
# ------------------------------------------------------------------
ensure_iptables() {
    local lan_if
    lan_if=$(grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server 2>/dev/null | cut -d'"' -f2)
    [[ -z "$lan_if" ]] && return
    local wan_list
    [[ -f "$PRIORITY_FILE" ]] && wan_list=$(tail -n1 "$PRIORITY_FILE") || return
    local changed=0
    for iface in $wan_list; do
        ip link show "$iface" &>/dev/null || continue
        if ! iptables -t nat -C POSTROUTING -o "$iface" -j MASQUERADE &>/dev/null; then
            iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
            log_fo "[iptables] RESTORED: NAT MASQUERADE rule for $iface"
            changed=1
        fi
        if ! iptables -C FORWARD -i "$lan_if" -o "$iface" -j ACCEPT &>/dev/null; then
            iptables -A FORWARD -i "$lan_if" -o "$iface" -j ACCEPT
            log_fo "[iptables] RESTORED: FORWARD $lan_if -> $iface"
            changed=1
        fi
        if ! iptables -C FORWARD -i "$iface" -o "$lan_if" -m state --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null; then
            iptables -A FORWARD -i "$iface" -o "$lan_if" -m state --state RELATED,ESTABLISHED -j ACCEPT
            log_fo "[iptables] RESTORED: FORWARD $iface -> $lan_if (RELATED,ESTABLISHED)"
            changed=1
        fi
    done
    [[ "$changed" -eq 0 ]] && log_fo "[iptables] All rules OK"
}

# ------------------------------------------------------------------
# Startup
# ------------------------------------------------------------------
log_fo "=== WAN Failover daemon started ==="
touch "$STATE_FILE"
ensure_iptables

DHCP_ROUTES_SCRIPT="/etc/1002xOPERATOR/dhcp/settings/dhcp-routes.sh"
SOLO_ROUTES_SCRIPT="/etc/1002xOPERATOR/dhcp/settings/soloroute.sh"
[[ -x "$DHCP_ROUTES_SCRIPT" ]] && bash "$DHCP_ROUTES_SCRIPT"
[[ -x "$SOLO_ROUTES_SCRIPT" ]] && bash "$SOLO_ROUTES_SCRIPT"

# ------------------------------------------------------------------
# Hauptschleife
# ------------------------------------------------------------------
while true; do
    if [[ ! -f "$PRIORITY_FILE" ]]; then
        log_fo "No priority file found, waiting..."
        sleep 30
        continue
    fi

    LAST_LINE=$(tail -n1 "$PRIORITY_FILE")
    read -ra WAN_IFACES <<< "$LAST_LINE"

    for iface in "${WAN_IFACES[@]}"; do
        ip link show "$iface" &>/dev/null || continue

        IS_SUPPRESSED=0
        grep -q "^SUPPRESSED $iface " "$STATE_FILE" 2>/dev/null && IS_SUPPRESSED=1

        if [[ "$IS_SUPPRESSED" -eq 1 ]]; then
            # Unterdrücktes Interface: immer per ifup neu starten und Ping testen
            log_fo "[$iface] ist suppressed – versuche ifup + Ping-Test..."
            restore_interface "$iface" && restore_static_routes "$iface"
        else
            # Normaler Betrieb: Check ob Interface noch erreichbar ist
            if ! check_wan "$iface"; then
                log_fo "$iface ist DOWN oder nicht erreichbar – unterdrücke per ifdown"
                suppress_interface "$iface"
                suspend_static_routes "$iface"
            fi
        fi
    done

    # Route-Fixer nach jedem Durchlauf ausführen (bereinigt DHCP-doppelte Routen)
    [[ -x "$DHCP_ROUTES_SCRIPT" ]] && bash "$DHCP_ROUTES_SCRIPT"
    [[ -x "$SOLO_ROUTES_SCRIPT" ]] && bash "$SOLO_ROUTES_SCRIPT"
    ensure_iptables
    sleep 30
done
FAILEOF

            chmod +x "$FAILOVER_SCRIPT"
            log "Failover script created at $FAILOVER_SCRIPT"

            SERVICE_FILE="/etc/systemd/system/wan-failover.service"
cat > "$SERVICE_FILE" <<SVCEOF
[Unit]
Description=WAN Failover Daemon
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash $FAILOVER_SCRIPT
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
            systemctl daemon-reload
            systemctl enable wan-failover.service
            systemctl restart wan-failover.service
            log "Failover daemon installed and started as systemd service: wan-failover.service"
            log "View logs with: journalctl -u wan-failover -f  or  tail -f $FAILOVER_LOG"
            log "Waiting for daemon to initialize..."
            sleep 3
            journalctl -u wan-failover -n 20 --no-pager
        else
            log "Metric-based routing only – no active failover daemon installed."
        fi

        # Remove any leftover cronjob (replaced by systemd service)
        if crontab -l 2>/dev/null | grep -qF "$DHCP_SCRIPT"; then
            crontab -l 2>/dev/null | grep -vF "$DHCP_SCRIPT" | crontab -
            log "Removed legacy cronjob for dhcp-routes.sh"
        fi
    else
        warn "WAN routing issues left unresolved"
    fi
fi

log "Multi-WAN configuration complete!"

# -------------------------------------------------
# Check IPv4 forwarding
# -------------------------------------------------
log "Checking IP forwarding status..."
if [[ "$(sysctl -n net.ipv4.ip_forward)" -eq 1 ]]; then
    log "IP forwarding is already enabled."
else
    log "IP forwarding is disabled. Enabling..."
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -w net.ipv4.ip_forward=1
    sysctl --system
    log "IP forwarding enabled."
fi

# -------------------------------------------------
# Check RP filters
# -------------------------------------------------
if [[ "$(sysctl -n net.ipv4.conf.all.rp_filter)" -ne 0 ]]; then
    log "RP filter (all) is enabled. Disabling..."
    echo "net.ipv4.conf.all.rp_filter=0" >> /etc/sysctl.conf
    sysctl -w net.ipv4.conf.all.rp_filter=0
    log "RP filter (all) disabled."
else
    log "RP filter (all) already disabled."
fi

if [[ "$(sysctl -n net.ipv4.conf.default.rp_filter)" -ne 0 ]]; then
    log "RP filter (default) is enabled. Disabling..."
    echo "net.ipv4.conf.default.rp_filter=0" >> /etc/sysctl.conf
    sysctl -w net.ipv4.conf.default.rp_filter=0
    log "RP filter (default) disabled."
else
    log "RP filter (default) already disabled."
fi

# -------------------------------------------------
# Check NAT & FORWARD rules (IPv4 only)
# -------------------------------------------------
log "Checking iptables for NAT & FORWARD rules..."
IPTABLES_CHANGED=0
for iface in "${ACTIVE_WAN[@]}"; do
    if ! iptables -t nat -C POSTROUTING -o "$iface" -j MASQUERADE &>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
        IPTABLES_CHANGED=1; log "NAT rule added for $iface."
    else log "NAT rule already exists for $iface."; fi

    if ! iptables -C FORWARD -i "$LAN_INTERFACE" -o "$iface" -j ACCEPT &>/dev/null; then
        iptables -A FORWARD -i "$LAN_INTERFACE" -o "$iface" -j ACCEPT
        IPTABLES_CHANGED=1; log "FORWARD rule LAN -> $iface added."
    else log "FORWARD rule LAN -> $iface already exists."; fi

    if ! iptables -C FORWARD -i "$iface" -o "$LAN_INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null; then
        iptables -A FORWARD -i "$iface" -o "$LAN_INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
        IPTABLES_CHANGED=1; log "FORWARD rule WAN -> LAN added for $iface."
    else log "FORWARD rule WAN -> LAN already exists for $iface."; fi
done

if [[ "$IPTABLES_CHANGED" -eq 1 ]]; then
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save && log "iptables rules saved via netfilter-persistent."
    elif command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null && \
            log "iptables rules saved to /etc/iptables/rules.v4" || \
            log "iptables rules applied (no persistent save available)."
    else
        log "iptables rules applied (no persistent save tool found)."
    fi
fi

# -------------------------------------------------
# Optional UFW check
# -------------------------------------------------
if command -v ufw &>/dev/null; then
    log "UFW is installed."
    if ufw status | grep -q "Status: active"; then
        UFW_PROBLEM=0
        for iface in "${ACTIVE_WAN[@]}"; do
            ufw status | grep -q "ALLOW.*$iface" || { log "UFW may block forwarding on $iface."; UFW_PROBLEM=1; }
        done
        if [[ "$UFW_PROBLEM" -eq 1 ]]; then
            if ask "Potential UFW issues detected. Fix automatically?"; then
                ufw default allow routed
                ufw allow in on "$LAN_INTERFACE"
                ufw reload
                log "UFW rules adjusted."
            else log "UFW issues left unchanged."; fi
        else log "No UFW issues detected."; fi
    else log "UFW is installed but not active."; fi
else log "UFW is not installed."; fi

# -------------------------------------------------
# Final verification
# -------------------------------------------------
log "Verifying LAN configuration..."
log "LAN interface $LAN_INTERFACE has IP: $LAN_IP"
log "Verifying WAN configuration..."
for iface in "${ACTIVE_WAN[@]}"; do
    IP=$(ip -o -4 addr show "$iface" | awk 'NR==1 {print $4}' | cut -d/ -f1)
    GW=$(ip route show dev "$iface" | awk '/default/ {print $3}' | head -n1)
    log "WAN interface $iface – IP: $IP  Gateway: ${GW:-none}"
done
log "Network and iptables configuration is complete and verified."
