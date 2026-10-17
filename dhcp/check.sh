#!/bin/bash
set -e

DHCP_CONFIG="/etc/default/isc-dhcp-server"
FOLDERSETTINGS="/etc/1002xOPERATOR/dhcp/settings"
PRIORITY_FILE="$FOLDERSETTINGS/wan-priority.list"
FAILOVER_SCRIPT="$FOLDERSETTINGS/wan-failover.sh"
FAILOVER_STATE="$FOLDERSETTINGS/wan-failover.state"
FAILOVER_LOG="/var/log/wan-failover.log"

PING_TARGETS=("8.8.8.8" "1.1.1.1" "9.9.9.9")
PING_COUNT=4
PING_TIMEOUT=10

log()  { echo "[INFO] $1"; }
warn() { echo "[WARN] $1"; }
ask()  { read -rp "[QUESTION] $1 [y/N]: " reply; [[ "$reply" =~ ^[Yy]$ ]]; }

# -------------------------------------------------
# CLEANUP: reset all previous configuration
# -------------------------------------------------
log "Cleaning up previous configuration..."

systemctl stop wan-failover 2>/dev/null || true
systemctl disable wan-failover 2>/dev/null || true
rm -f /etc/systemd/system/wan-failover.service
systemctl daemon-reload 2>/dev/null || true

rm -f "$FOLDERSETTINGS/dhcp-routes.sh"
rm -f "$FOLDERSETTINGS/wan-failover.sh"
rm -f "$FOLDERSETTINGS"/fail-*.cnt 2>/dev/null || true

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
    if [[ -z "$IP" ]]; then log "Skipping $iface, no IPv4 address assigned"; continue; fi
    GW=$(ip route show dev "$iface" | awk '/default/ {print $3}' | head -n1)
    log "Detected WAN interface: $iface with IP $IP and Gateway ${GW:-none}"
    ACTIVE_WAN+=("$iface")
done
log "Detected WAN interfaces: ${ACTIVE_WAN[*]}"

if (( ${#ACTIVE_WAN[@]} > 1 )); then
    warn "Multiple WAN interfaces detected: ${ACTIVE_WAN[*]}"
    RP_ALL=$(sysctl -n net.ipv4.conf.all.rp_filter)
    RP_DEF=$(sysctl -n net.ipv4.conf.default.rp_filter)
    [[ "$RP_ALL" -ne 0 || "$RP_DEF" -ne 0 ]] && warn "rp_filter enabled, asymmetric routing likely"
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
        echo "  1) Active failover ping + link check, switches default route [recommended]"
        echo "  2) Metric-based only, kernel picks lowest metric active route"
        read -rp "Select mode [1/2] (default: 1): " FAILOVER_MODE_INPUT
        case "$FAILOVER_MODE_INPUT" in
            2) FAILOVER_MODE="1" ;;
            *) FAILOVER_MODE="2" ;;
        esac

        DHCP_SCRIPT="$FOLDERSETTINGS/dhcp-routes.sh"
cat > "$DHCP_SCRIPT" <<'ROUTEEOF'
#!/bin/bash
PRIORITY_FILE="/etc/1002xOPERATOR/dhcp/settings/wan-priority.list"
STATE_FILE="/etc/1002xOPERATOR/dhcp/settings/wan-failover.state"
LOGFILE="/var/log/wan-failover.log"
log_r() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [route-fixer] $1" | tee -a "$LOGFILE"; }
[[ ! -f "$PRIORITY_FILE" ]] && log_r "Priority file not found." && exit 0
LAST_LINE=$(tail -n1 "$PRIORITY_FILE")
read -ra WAN_IFACES <<< "$LAST_LINE"
[[ ${#WAN_IFACES[@]} -eq 0 ]] && log_r "No valid interfaces." && exit 0
log_r "Processing: ${WAN_IFACES[*]}"

METRIC=100
for iface in "${WAN_IFACES[@]}"; do
    CUR_METRIC=$METRIC
    METRIC=$((METRIC + 100))

    ip link show "$iface" &>/dev/null || { log_r "Skipping invalid: '$iface'"; continue; }
    grep -q "^SUPPRESSED $iface " "$STATE_FILE" 2>/dev/null && { log_r "$iface suppressed, skipping."; continue; }
    ip link show "$iface" | grep -q "state UP" || { log_r "$iface DOWN, skipping."; continue; }

    GW=$(ip route show dev "$iface" | awk '/default/ {print $3}' | head -n1)
    if [[ -z "$GW" ]]; then
        GW=$(nmcli -g IP4.GATEWAY device show "$iface" 2>/dev/null | head -n1)
        [[ -z "$GW" ]] && GW=$(ip route show dev "$iface" | awk '/via/ {print $3}' | head -n1)
    fi
    [[ -z "$GW" ]] && { log_r "No gateway found for $iface, skipping."; continue; }

    # Remove every default route on this interface, then set the one with the fixed metric
    while ip route show default dev "$iface" | grep -q .; do
        ip route del default dev "$iface" 2>/dev/null || break
    done
    ip route replace default via "$GW" dev "$iface" metric "$CUR_METRIC"
    log_r "Set default via $GW dev $iface metric $CUR_METRIC"
done
ROUTEEOF
        chmod +x "$DHCP_SCRIPT"
        log "Route fixer created at $DHCP_SCRIPT"

        if [[ "$FAILOVER_MODE" == "2" ]]; then
cat > "$FAILOVER_SCRIPT" <<'FAILEOF'
#!/bin/bash
# wan-failover.sh: Active WAN Failover (ifdown/ifup + ping check, every 30s)

PRIORITY_FILE="/etc/1002xOPERATOR/dhcp/settings/wan-priority.list"
STATIC_ROUTES_FILE="/etc/1002xOPERATOR/dhcp/settings/static-routes.conf"
SUSPENDED_ROUTES_FILE="/etc/1002xOPERATOR/dhcp/settings/static-routes.suspended"
STATE_FILE="/etc/1002xOPERATOR/dhcp/settings/wan-failover.state"
FAIL_DIR="/etc/1002xOPERATOR/dhcp/settings"
LOGFILE="/var/log/wan-failover.log"
PING_TARGETS=("8.8.8.8" "1.1.1.1" "9.9.9.9")
PING_COUNT=4
PING_TIMEOUT=10
FAIL_THRESHOLD=3

TEST_TABLE_BASE=1000

log_fo() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"; }

_iface_table_id() {
    local iface="$1"
    local idx=0
    if [[ -f "$PRIORITY_FILE" ]]; then
        local list
        read -ra list < <(tail -n1 "$PRIORITY_FILE")
        for i in "${!list[@]}"; do
            [[ "${list[$i]}" == "$iface" ]] && idx=$i && break
        done
    fi
    echo $((TEST_TABLE_BASE + idx))
}

_TEST_wan_via_temp_rule() {
    local iface="$1"
    local gw="$2"
    local tid
    tid=$(_iface_table_id "$iface")

    local src_ip
    src_ip=$(ip -4 addr show dev "$iface" | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
    [[ -z "$src_ip" ]] && { log_fo "TEST [$iface] NO src-IP for temp-rule"; return 1; }

    ip rule del from "$src_ip" table "$tid" 2>/dev/null || true
    ip route flush table "$tid" 2>/dev/null || true

    ip route add default via "$gw" dev "$iface" table "$tid" 2>/dev/null \
        || { log_fo "TEST [$iface] ip route add table $tid failed"; return 1; }
    ip rule add from "$src_ip" table "$tid" priority "$((tid * 10))" 2>/dev/null \
        || { ip route flush table "$tid" 2>/dev/null; log_fo "TEST [$iface] ip rule add failed"; return 1; }

    log_fo "TEST [$iface] Temp-Policy active: src=$src_ip table $tid via $gw"

    local result=1

    if ping -c 2 -W "$PING_TIMEOUT" -I "$iface" "$gw" &>/dev/null; then
        log_fo "TEST [$iface] Gateway $gw is reachable, Interface is online"
        result=0
    else
        log_fo "TEST [$iface] Gateway $gw is not reachable, Interface stays suppressed"
    fi

    ip rule del from "$src_ip" table "$tid" priority "$((tid * 10))" 2>/dev/null \
        && log_fo "TEST [$iface] ip rule removed" \
        || log_fo "TEST [$iface] WARNING: ip rule could not be removed"
    ip route flush table "$tid" 2>/dev/null \
        && log_fo "TEST [$iface] Temp-Route removed" \
        || log_fo "TEST [$iface] WARNING: Temp-Route could not be removed"

    return $result
}

check_wan() {
    local iface="$1"
    ip link show "$iface" 2>/dev/null | grep -q "state UP" || return 1
    local ip
    ip=$(ip -4 addr show dev "$iface" | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
    [[ -z "$ip" ]] && return 1
    local gw
    gw=$(ip route show dev "$iface" | awk '/default/ {print $3}' | head -n1)
    [[ -z "$gw" ]] && gw=$(grep "^SUPPRESSED $iface " "$STATE_FILE" 2>/dev/null | awk '{print $3}' | head -n1)
    [[ -z "$gw" ]] && { log_fo "[$iface] No gateway for check_wan"; return 1; }
    ping -c 3 -W "$PING_TIMEOUT" -I "$iface" "$gw" &>/dev/null || { log_fo "[$iface] Gateway $gw not reachable"; return 1; }
    local ok=0
    for target in "${PING_TARGETS[@]}"; do
        ping -c "$PING_COUNT" -W "$PING_TIMEOUT" -I "$iface" "$target" &>/dev/null && ok=1 && break
    done
    [[ "$ok" -eq 1 ]] || { log_fo "[$iface] No internet activity"; return 1; }
    return 0
}

suppress_interface() {
    local iface="$1"
    grep -q "^SUPPRESSED $iface " "$STATE_FILE" 2>/dev/null && return 0

    local route_info gw metric
    route_info=$(ip route show default dev "$iface" | head -n1)
    gw=$(echo "$route_info" | awk '{print $3}')
    metric=$(echo "$route_info" | awk '/metric/ {for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')
    [[ -z "$metric" ]] && metric=100

    echo "SUPPRESSED $iface $gw $metric" >> "$STATE_FILE"
    log_fo "SUPPRESS: Stop $iface via ifdown (was via $gw metric $metric)"

    ifdown "$iface" 2>/dev/null \
        && log_fo "SUPPRESS: ifdown $iface successfully" \
        || log_fo "SUPPRESS: ifdown $iface failed, route left unchanged"
}

restore_interface() {
    local iface="$1"
    local entry
    entry=$(grep "^SUPPRESSED $iface " "$STATE_FILE" 2>/dev/null | head -n1)
    [[ -z "$entry" ]] && return 0

    local saved_gw saved_metric
    saved_gw=$(echo "$entry"     | awk '{print $3}')
    saved_metric=$(echo "$entry" | awk '{print $4}')

    log_fo "RESTORE: Restart $iface via ifup..."
    ifup "$iface" 2>/dev/null \
        && log_fo "RESTORE: ifup $iface successfully" \
        || log_fo "RESTORE: ifup $iface failed, try to test anyway"

    sleep 4

    local live_ip
    live_ip=$(ip -4 addr show dev "$iface" | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
    if [[ -z "$live_ip" ]]; then
        log_fo "RESTORE: $iface has no IP after ifup, stays suppressed (no route add)"
        return 1
    fi

    local live_gw
    live_gw=$(ip route show dev "$iface" | awk '/default/ {print $3}' | head -n1)
    local gw="${live_gw:-$saved_gw}"

    if [[ -z "$gw" ]]; then
        log_fo "RESTORE: No gateway for $iface, stays suppressed (no route add)"
        return 1
    fi

    local cooldown_entry next_allowed current_cooldown now
    cooldown_entry=$(grep "^COOLDOWN $iface " "$STATE_FILE" 2>/dev/null | head -n1)
    now=$(date +%s)

    if [[ -n "$cooldown_entry" ]]; then
        next_allowed=$(echo "$cooldown_entry" | awk '{print $3}')
        current_cooldown=$(echo "$cooldown_entry" | awk '{print $4}')
        if (( now < next_allowed )); then
            local remaining=$(( next_allowed - now ))
            log_fo "RESTORE: [$iface] Cooldown active - ${remaining}s remaining until next test"
            return 1
        fi
        log_fo "RESTORE: [$iface] Cooldown expired (was ${current_cooldown}s), starting TEST ping..."
    else
        current_cooldown=0
    fi

    log_fo "RESTORE: Start TEST ping for $iface via $gw (NO global default route)"
    if ! _TEST_wan_via_temp_rule "$iface" "$gw"; then
        log_fo "RESTORE: $iface TEST failed, no default route added, stays suppressed"

        if (( current_cooldown == 0 )); then
            current_cooldown=30
        else
            current_cooldown=$(( current_cooldown * 2 ))
        fi
        (( current_cooldown > 4800 )) && current_cooldown=4800
        local next_ts=$(( now + current_cooldown ))

        grep -v "^COOLDOWN $iface " "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
        echo "COOLDOWN $iface $next_ts $current_cooldown" >> "${STATE_FILE}.tmp"
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
        log_fo "RESTORE: [$iface] Cooldown set to ${current_cooldown}s (next attempt at: $(date -d @$next_ts '+%H:%M:%S'))"
        return 1
    fi

    grep -v "^COOLDOWN $iface " "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
    log_fo "RESTORE: [$iface] TEST successful, cooldown reset"

    log_fo "RESTORE: TEST successful, adding default route via $gw dev $iface metric $saved_metric"
    ip route replace default via "$gw" dev "$iface" metric "$saved_metric" 2>/dev/null \
        && log_fo "RESTORE: Default route set" \
        || log_fo "RESTORE: WARNING: default route could not be set (via $gw dev $iface metric $saved_metric)"

    grep -v "^SUPPRESSED $iface " "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
    log_fo "RESTORE: $iface successfully restored and removed from state"
    return 0
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
# ensure_iptables: make sure NAT and FORWARD rules exist
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
[[ -x "$SOLO_ROUTES_SCRIPT" ]]  && bash "$SOLO_ROUTES_SCRIPT"

# ------------------------------------------------------------------
# Main loop
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
        FAIL_FILE="$FAIL_DIR/fail-$iface.cnt"

        if [[ "$IS_SUPPRESSED" -eq 1 ]]; then
            log_fo "[$iface] is suppressed, trying ifup + TEST ping..."
            restore_interface "$iface" && restore_static_routes "$iface"
        else
            if ! check_wan "$iface"; then
                n=$(( $(cat "$FAIL_FILE" 2>/dev/null || echo 0) + 1 ))
                echo "$n" > "$FAIL_FILE"
                log_fo "[$iface] check failed ($n/$FAIL_THRESHOLD)"
                if (( n >= FAIL_THRESHOLD )); then
                    log_fo "$iface: $n consecutive failures, suppressing"
                    suppress_interface "$iface"
                    suspend_static_routes "$iface"
                    rm -f "$FAIL_FILE"
                fi
            else
                rm -f "$FAIL_FILE"
            fi
        fi
    done

    [[ -x "$DHCP_ROUTES_SCRIPT" ]] && bash "$DHCP_ROUTES_SCRIPT"
    [[ -x "$SOLO_ROUTES_SCRIPT" ]]  && bash "$SOLO_ROUTES_SCRIPT"
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
            log "Metric-based routing only, no active failover daemon installed."
        fi

        # Remove any leftover cronjob
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

        UFW_VERBOSE=$(ufw status verbose 2>/dev/null)
        if ! echo "$UFW_VERBOSE" | grep -q "Default:.*allow.*routed"; then
            log "UFW: Default routed policy is not 'allow', forwarding may be blocked."
            UFW_PROBLEM=1
        else
            log "UFW: Default routed policy is already 'allow'."
        fi

        if ! echo "$UFW_VERBOSE" | grep -q "on $LAN_INTERFACE"; then
            log "UFW: No ALLOW IN rule for LAN interface $LAN_INTERFACE."
            UFW_PROBLEM=1
        else
            log "UFW: ALLOW IN rule for $LAN_INTERFACE already exists."
        fi

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
    log "WAN interface $iface IP: $IP  Gateway: ${GW:-none}"
done
log "Network and iptables configuration is complete and verified."
