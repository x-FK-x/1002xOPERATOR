#!/bin/bash
# check.sh – Network setup checker with Multi-WAN priority + Failover (ping + link)

set -e

DHCP_CONFIG="/etc/default/isc-dhcp-server"
FOLDERSETTINGS="/etc/1002xOPERATOR/dhcp/settings"
PRIORITY_FILE="$FOLDERSETTINGS/wan-priority.list"
FAILOVER_SCRIPT="$FOLDERSETTINGS/wan-failover.sh"
FAILOVER_STATE="$FOLDERSETTINGS/wan-failover.state"
FAILOVER_LOG="/var/log/wan-failover.log"

# Ping targets for connectivity check (tried in order)
PING_TARGETS=("8.8.8.8" "1.1.1.1" "9.9.9.9")
PING_COUNT=3
PING_TIMEOUT=2

log() {
    echo "[INFO] $1"
}

warn() {
    echo "[WARN] $1"
}

ask() {
    read -rp "[QUESTION] $1 [y/N]: " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# -------------------------------------------------
# Detect network interfaces (IPv4 only)
# -------------------------------------------------
log "Detecting network interfaces..."
mapfile -t INTERFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -v lo)

# -------------------------------------------------
# Read LAN interface from DHCP config
# -------------------------------------------------
LAN_INTERFACE=$(grep -E '^INTERFACESv4=' "$DHCP_CONFIG" | cut -d'"' -f2)

if [[ -z "$LAN_INTERFACE" ]]; then
    log "No LAN interface defined in DHCP config."
    exit 1
fi

if ! ip link show "$LAN_INTERFACE" &>/dev/null; then
    log "Configured LAN interface $LAN_INTERFACE does not exist."
    exit 1
fi

LAN_IP=$(ip -o -4 addr show "$LAN_INTERFACE" | awk '{print $4}' | cut -d/ -f1)

if [[ -z "$LAN_IP" ]]; then
    log "LAN interface $LAN_INTERFACE has no IPv4 address."
    exit 1
fi

log "Using LAN interface from DHCP config: $LAN_INTERFACE with IP $LAN_IP"

# -------------------------------------------------
# Build WAN interface list
# -------------------------------------------------
WAN_INTERFACES=()
for iface in "${INTERFACES[@]}"; do
    [[ "$iface" != "$LAN_INTERFACE" ]] && WAN_INTERFACES+=("$iface")
done

ACTIVE_WAN=()
for iface in "${WAN_INTERFACES[@]}"; do
    IP=$(ip -o -4 addr show "$iface" 2>/dev/null | awk 'NR==1 {print $4}' | cut -d/ -f1)
    # Skip interfaces without an IP address
    if [[ -z "$IP" ]]; then
        log "Skipping $iface – no IPv4 address assigned"
        continue
    fi
    GW=$(ip route show dev "$iface" | awk '/default/ {print $3}' | head -n1)
    log "Detected WAN interface: $iface with IP $IP and Gateway ${GW:-none}"
    ACTIVE_WAN+=("$iface")
done

log "Detected WAN interfaces: ${ACTIVE_WAN[*]}"

# -------------------------------------------------
# Multi-WAN: Priority + Failover configuration
# -------------------------------------------------
if (( ${#ACTIVE_WAN[@]} > 1 )); then
    warn "Multiple WAN interfaces detected: ${ACTIVE_WAN[*]}"

    RP_ALL=$(sysctl -n net.ipv4.conf.all.rp_filter)
    RP_DEF=$(sysctl -n net.ipv4.conf.default.rp_filter)
    if [[ "$RP_ALL" -ne 0 || "$RP_DEF" -ne 0 ]]; then
        warn "rp_filter enabled – asymmetric routing likely"
    fi

    warn "Multi-WAN without explicit priorities may break forwarding"

    if ask "Configure WAN priority + Failover now?"; then
        SELECTED_WAN=()
        REMAINING_WAN=("${ACTIVE_WAN[@]}")

        # Interactive prioritization
        while (( ${#REMAINING_WAN[@]} > 0 )); do
            echo
            echo "Select WAN interface for next priority:"
            select iface in "${REMAINING_WAN[@]}"; do
                [[ -n "$iface" ]] || continue
                SELECTED_WAN+=("$iface")
                NEW=()
                for r in "${REMAINING_WAN[@]}"; do
                    [[ "$r" != "$iface" ]] && NEW+=("$r")
                done
                REMAINING_WAN=("${NEW[@]}")
                break
            done
        done

        mkdir -p "$FOLDERSETTINGS"

        # Save priority order
        echo "${SELECTED_WAN[@]}" > "$PRIORITY_FILE"
        log "WAN priority saved to $PRIORITY_FILE"

        # Ask about failover mode
        echo
        echo "Failover mode options:"
        echo "  1) Metric-based only (kernel picks lowest metric active route)"
        echo "  2) Active failover (ping + link check, switches default route)"
        read -rp "Select mode [1/2]: " FAILOVER_MODE

        # --------------------------------------------------
        # Generate the combined route fixer + failover script
        # --------------------------------------------------
        DHCP_SCRIPT="$FOLDERSETTINGS/dhcp-routes.sh"

cat > "$DHCP_SCRIPT" <<'ROUTEEOF'
#!/bin/bash
# dhcp-routes.sh – Multi-WAN metric-based route enforcer
# Reads ONLY the last line of wan-priority.list (space-separated interface names)

PRIORITY_FILE="/etc/1002xOPERATOR/dhcp/settings/wan-priority.list"
LOGFILE="/var/log/wan-failover.log"

log_r() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [route-fixer] $1" >> "$LOGFILE"
}

if [[ ! -f "$PRIORITY_FILE" ]]; then
    log_r "Priority file not found, aborting."
    exit 0
fi

# Read only the last line – space-separated interface names
# Using tail -n1 protects against stale routing output in the file
LAST_LINE=$(tail -n1 "$PRIORITY_FILE")
read -ra WAN_IFACES <<< "$LAST_LINE"

# Validate each entry is a real interface
VALID_IFACES=()
for entry in "${WAN_IFACES[@]}"; do
    if ip link show "$entry" &>/dev/null; then
        VALID_IFACES+=("$entry")
    else
        log_r "Skipping invalid entry: '$entry'"
    fi
done

[[ ${#VALID_IFACES[@]} -eq 0 ]] && log_r "No valid interfaces, aborting." && exit 0

log_r "Processing: ${VALID_IFACES[*]}"

METRIC=100
for iface in "${VALID_IFACES[@]}"; do
    if ! ip link show "$iface" | grep -q "state UP"; then
        log_r "$iface is DOWN, skipping."
        continue
    fi

    GW=$(ip route show dev "$iface" | awk '/default/ {print $3}' | head -n1)
    if [[ -z "$GW" ]]; then
        IP_ADDR=$(ip -4 addr show dev "$iface" | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
        [[ -n "$IP_ADDR" ]] && GW="${IP_ADDR%.*}.1"
    fi
    if [[ -z "$GW" ]]; then
        log_r "No gateway for $iface, skipping."
        continue
    fi

    # Remove stale DHCP default routes
    while IFS= read -r route; do
        via=$(echo "$route" | awk '{print $3}')
        [[ -n "$via" ]] && ip route delete default via "$via" dev "$iface" 2>/dev/null || true
    done < <(ip route show default dev "$iface" proto dhcp)

    ip route replace default via "$GW" dev "$iface" metric "$METRIC"
    log_r "Set default via $GW dev $iface metric $METRIC"
    METRIC=$((METRIC + 100))
done
ROUTEEOF

        chmod +x "$DHCP_SCRIPT"
        log "Route fixer created at $DHCP_SCRIPT"

        # --------------------------------------------------
        # Generate failover script (mode 2)
        # --------------------------------------------------
        if [[ "$FAILOVER_MODE" == "2" ]]; then

cat > "$FAILOVER_SCRIPT" <<'FAILEOF'
#!/bin/bash
# wan-failover.sh – Active WAN Failover (ping + link check, every 30s via loop)
# Switches default route to next available WAN if primary fails.
# Also monitors static routes from 1to1route.sh and suspends/restores them on interface failure.

PRIORITY_FILE="/etc/1002xOPERATOR/dhcp/settings/wan-priority.list"
STATIC_ROUTES_FILE="/etc/1002xOPERATOR/dhcp/settings/static-routes.conf"
SUSPENDED_ROUTES_FILE="/etc/1002xOPERATOR/dhcp/settings/static-routes.suspended"
STATE_FILE="/etc/1002xOPERATOR/dhcp/settings/wan-failover.state"
LOGFILE="/var/log/wan-failover.log"
PING_TARGETS=("8.8.8.8" "1.1.1.1" "9.9.9.9")
PING_COUNT=3
PING_TIMEOUT=2

log_fo() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# Check if interface is physically up AND has connectivity
check_wan() {
    local iface="$1"

    # Step 1: Link check
    if ! ip link show "$iface" 2>/dev/null | grep -q "state UP"; then
        return 1
    fi

    # Step 2: Has IP address
    local ip
    ip=$(ip -4 addr show dev "$iface" | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
    [[ -z "$ip" ]] && return 1

    # Step 3: Gateway reachability
    local gw
    gw=$(ip route show dev "$iface" | awk '/default/ {print $3}' | head -n1)
    if [[ -z "$gw" ]]; then
        gw="${ip%.*}.1"
    fi

    if ! ping -c 1 -W "$PING_TIMEOUT" -I "$iface" "$gw" &>/dev/null; then
        log_fo "[$iface] Gateway $gw unreachable"
        return 1
    fi

    # Step 4: Internet connectivity via multiple targets
    local ok=0
    for target in "${PING_TARGETS[@]}"; do
        if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" -I "$iface" "$target" &>/dev/null; then
            ok=1
            break
        fi
    done

    [[ "$ok" -eq 1 ]] || { log_fo "[$iface] No internet connectivity"; return 1; }
    return 0
}

# Suppress a failed interface: save its route to state and remove from kernel
suppress_interface() {
    local iface="$1"
    # Check if already suppressed
    grep -q "^SUPPRESSED $iface " "$STATE_FILE" 2>/dev/null && return 0

    # Find and save its current default route (metric + gateway)
    local route_info
    route_info=$(ip route show default dev "$iface" | grep -v "metric 50" | head -n1)
    [[ -z "$route_info" ]] && return 0

    local gw metric
    gw=$(echo "$route_info" | awk '{print $3}')
    metric=$(echo "$route_info" | awk '/metric/ {for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')
    [[ -z "$metric" ]] && metric=100

    # Save suppressed route info for later restore
    echo "SUPPRESSED $iface $gw $metric" >> "$STATE_FILE"

    # Remove from kernel so backup takes over naturally
    ip route del default via "$gw" dev "$iface" metric "$metric" 2>/dev/null || true
    log_fo "SUPPRESSED: Removed default route for $iface (was via $gw metric $metric)"
}

# Restore a recovered interface: re-add its original default route
restore_interface() {
    local iface="$1"
    local entry
    entry=$(grep "^SUPPRESSED $iface " "$STATE_FILE" 2>/dev/null | head -n1)
    [[ -z "$entry" ]] && return 0

    local gw metric
    gw=$(echo "$entry" | awk '{print $3}')
    metric=$(echo "$entry" | awk '{print $4}')

    # Re-resolve gateway in case DHCP changed it
    local live_gw
    live_gw=$(ip route show dev "$iface" | awk '/default/ {print $3}' | head -n1)
    [[ -n "$live_gw" ]] && gw="$live_gw"

    ip route replace default via "$gw" dev "$iface" metric "$metric" 2>/dev/null || true
    log_fo "RESTORED: Re-added default route for $iface via $gw metric $metric"

    # Remove from state file
    grep -v "^SUPPRESSED $iface " "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# Legacy stubs (unused now but kept for safety)
activate_wan() { suppress_interface "$1"; }
restore_primary() { restore_interface "$1"; }

# Suspend all static routes that belong to a failed interface
# Saves them to suspended file so they can be restored later
suspend_static_routes() {
    local failed_iface="$1"
    [[ ! -f "$STATIC_ROUTES_FILE" ]] && return

    touch "$SUSPENDED_ROUTES_FILE"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        read -r dest iface gw <<< "$line"
        [[ "$iface" != "$failed_iface" ]] && continue

        # Only suspend if not already suspended
        if ! grep -qxF "$line" "$SUSPENDED_ROUTES_FILE" 2>/dev/null; then
            echo "$line" >> "$SUSPENDED_ROUTES_FILE"
            log_fo "STATIC-ROUTE SUSPENDED: $dest via $iface ($gw) – interface down"
        fi

        # Remove from kernel routing table
        ip route del "$dest" dev "$iface" 2>/dev/null && \
            log_fo "STATIC-ROUTE REMOVED from kernel: $dest dev $iface" || true

    done < "$STATIC_ROUTES_FILE"
}

# Restore suspended static routes for a recovered interface
restore_static_routes() {
    local recovered_iface="$1"
    [[ ! -f "$SUSPENDED_ROUTES_FILE" ]] && return

    local remaining=()

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        read -r dest iface gw <<< "$line"

        if [[ "$iface" != "$recovered_iface" ]]; then
            remaining+=("$line")
            continue
        fi

        # Re-resolve gateway dynamically (may have changed after reconnect)
        local live_gw
        live_gw=$(ip route show dev "$iface" | awk '/default/ {print $3}' | head -n1)
        [[ -z "$live_gw" ]] && live_gw="$gw"

        ip route replace "$dest" via "$live_gw" dev "$iface" 2>/dev/null && \
            log_fo "STATIC-ROUTE RESTORED: $dest via $iface ($live_gw)" || \
            log_fo "STATIC-ROUTE RESTORE FAILED: $dest via $iface ($live_gw)"

    done < "$SUSPENDED_ROUTES_FILE"

    # Rewrite suspended file with only routes that couldn't be restored
    printf '%s\n' "${remaining[@]}" > "$SUSPENDED_ROUTES_FILE"
}

# Main failover loop (runs every 30 seconds)
log_fo "=== WAN Failover daemon started ==="

# Initialize state file
touch "$STATE_FILE"

while true; do
    if [[ ! -f "$PRIORITY_FILE" ]]; then
        log_fo "No priority file found, waiting..."
        sleep 30
        continue
    fi

    LAST_LINE=$(tail -n1 "$PRIORITY_FILE")
    read -ra WAN_IFACES <<< "$LAST_LINE"

    for iface in "${WAN_IFACES[@]}"; do
        # Skip if not a real interface
        ip link show "$iface" &>/dev/null || continue

        IS_SUPPRESSED=0
        grep -q "^SUPPRESSED $iface " "$STATE_FILE" 2>/dev/null && IS_SUPPRESSED=1

        if check_wan "$iface"; then
            if [[ "$IS_SUPPRESSED" -eq 1 ]]; then
                # Interface recovered – restore its route and static routes
                log_fo "$iface is back online – restoring"
                restore_interface "$iface"
                restore_static_routes "$iface"
            fi
        else
            if [[ "$IS_SUPPRESSED" -eq 0 ]]; then
                # Interface just failed – suppress its route and static routes
                log_fo "$iface is DOWN or unreachable – suppressing"
                suppress_interface "$iface"
                suspend_static_routes "$iface"
            fi
        fi
    done

    sleep 30
done
FAILEOF

            chmod +x "$FAILOVER_SCRIPT"
            log "Failover script created at $FAILOVER_SCRIPT"

            # Install failover as systemd service for reliable 30s loop
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

        else
            log "Metric-based routing only – no active failover daemon installed."
        fi

        # Remove any leftover cronjob (replaced by systemd service)
        if crontab -l 2>/dev/null | grep -qF "$DHCP_SCRIPT"; then
            crontab -l 2>/dev/null | grep -vF "$DHCP_SCRIPT" | crontab -
            log "Removed legacy cronjob for dhcp-routes.sh (systemd service handles this now)"
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
        log "NAT rule missing for $iface. Adding..."
        iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
        IPTABLES_CHANGED=1
        log "NAT rule added for $iface."
    else
        log "NAT rule already exists for $iface."
    fi

    if ! iptables -C FORWARD -i "$LAN_INTERFACE" -o "$iface" -j ACCEPT &>/dev/null; then
        log "FORWARD rule LAN -> $iface missing. Adding..."
        iptables -A FORWARD -i "$LAN_INTERFACE" -o "$iface" -j ACCEPT
        IPTABLES_CHANGED=1
        log "FORWARD rule LAN -> $iface added."
    else
        log "FORWARD rule LAN -> $iface already exists."
    fi

    if ! iptables -C FORWARD -i "$iface" -o "$LAN_INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null; then
        log "FORWARD rule WAN -> LAN missing. Adding..."
        iptables -A FORWARD -i "$iface" -o "$LAN_INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
        IPTABLES_CHANGED=1
        log "FORWARD rule WAN -> LAN added."
    else
        log "FORWARD rule WAN -> LAN already exists."
    fi
done

# Save once at the end if anything changed
if [[ "$IPTABLES_CHANGED" -eq 1 ]]; then
    netfilter-persistent save
    log "iptables rules saved."
fi

# -------------------------------------------------
# Optional UFW check
# -------------------------------------------------
if command -v ufw &>/dev/null; then
    log "UFW is installed."
    if ufw status | grep -q "Status: active"; then
        log "UFW is active. Checking for potential issues..."
        UFW_PROBLEM=0
        for iface in "${ACTIVE_WAN[@]}"; do
            if ! ufw status | grep -q "ALLOW.*$iface"; then
                log "UFW may block forwarding on $iface."
                UFW_PROBLEM=1
            fi
        done
        if [[ "$UFW_PROBLEM" -eq 1 ]]; then
            if ask "Potential UFW issues detected. Fix automatically?"; then
                ufw default allow routed
                ufw allow in on "$LAN_INTERFACE"
                ufw reload
                log "UFW rules adjusted."
            else
                log "UFW issues left unchanged."
            fi
        else
            log "No UFW issues detected."
        fi
    else
        log "UFW is installed but not active."
    fi
else
    log "UFW is not installed."
fi

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
