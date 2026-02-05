#!/bin/bash

set -e

DHCP_CONFIG="/etc/default/isc-dhcp-server"

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
    if ip -o -4 addr show "$iface" &>/dev/null; then
        IP=$(ip -o -4 addr show "$iface" | awk '{print $4}')
        GW=$(ip route show dev "$iface" | awk '/default/ {print $3}')
        log "Detected WAN interface: $iface with IP $IP and Gateway $GW"
        ACTIVE_WAN+=("$iface")
    fi
done

log "Detected WAN interfaces: ${ACTIVE_WAN[*]}"

# -------------------------------------------------
# WAN routing sanity check (multi-WAN, device-based, persistent)
# -------------------------------------------------
# -------------------------
# Multi-WAN device-based routing
# -------------------------
if (( ${#ACTIVE_WAN[@]} > 1 )); then
warn "Multiple WAN interfaces detected: ${ACTIVE_WAN[*]}"

RP_ALL=$(/usr/sbin/sysctl -n net.ipv4.conf.all.rp_filter)
RP_DEF=$(/usr/sbin/sysctl -n net.ipv4.conf.default.rp_filter)
if [[ "$RP_ALL" -ne 0 || "$RP_DEF" -ne 0 ]]; then
    warn "rp_filter enabled – asymmetric routing likely"
fi
#----
warn "Multi-WAN without explicit priorities may break forwarding"

if ask "Configure WAN priority now?"; then
    SELECTED_WAN=()
    REMAINING_WAN=("${ACTIVE_WAN[@]}")

    # Interaktive Priorisierung
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

    mkdir -p /etc/1002xOPERATOR/dhcp/settings

    # Reihenfolge speichern fuer Cron-Skript
    PRIORITY_FILE="/etc/1002xOPERATOR/dhcp/settings/wan-priority.list"
    echo "${SELECTED_WAN[@]}" > "$PRIORITY_FILE"
    log "WAN priority saved to $PRIORITY_FILE"

    # Cron-Skript erstellen/aktualisieren
    DHCP_SCRIPT="/etc/1002xOPERATOR/dhcp/settings/dhcp-routes.sh"
   cat > "$DHCP_SCRIPT" <<'EOF'
#!/bin/bash
# Dynamic Multi-WAN route fixer / fully automatic

PRIORITY_FILE="/etc/1002xOPERATOR/dhcp/settings/wan-priority.list"

# 1. Determine interfaces to process
if [[ -f "$PRIORITY_FILE" ]]; then
    # Load interfaces from file, ignore comments and empty lines
    WAN_IFACES=($(grep -v '^#' "$PRIORITY_FILE"))
else
    WAN_IFACES=()
    # Fallback: Detect all UP interfaces except loopback
    for i in $(ip -o link show | awk -F': ' '{print $2}'); do
        [[ "$i" == lo* ]] && continue
        if ip link show "$i" | grep -q "state UP"; then
            WAN_IFACES+=("$i")
        fi
    done
fi

METRIC=100
for iface in "${WAN_IFACES[@]}"; do
    # Check if interface is physically UP
    if ! ip link show "$iface" | grep -q "state UP"; then
        continue
    fi

    # Dynamically determine the current Gateway for this interface
    GW=$(ip route show dev "$iface" | awk '/default/ {print $3}' | head -n1)
    
    # If no default gateway found, skip to next interface
    [[ -z "$GW" ]] && continue

    # 2. Fix: Remove ALL existing default routes for this specific interface
    # This cleans up routes without metrics and old DHCP-assigned routes
    while ip route show default dev "$iface" | grep -q "default"; do
        if ! ip route delete default dev "$iface" 2>/dev/null; then
            break # Prevent infinite loop if deletion fails
        fi
    done

    # 3. Apply: Set new default route with calculated metric
    # Using 'append' or 'add' ensures we don't conflict with existing system routes
    ip route add default via "$GW" dev "$iface" metric $METRIC 2>/dev/null || \
    ip route replace default via "$GW" dev "$iface" metric $METRIC

    # Increase metric for the next interface in the priority list
    METRIC=$((METRIC + 100))
done
EOF

    chmod +x "$DHCP_SCRIPT"
    log "Dynamic DHCP-route fixer created at $DHCP_SCRIPT"

    # Cronjob add or check
    (crontab -l 2>/dev/null | grep -q "$DHCP_SCRIPT") || \
    (crontab -l 2>/dev/null; echo "* * * * * $DHCP_SCRIPT") | crontab -
    log "Cronjob for DHCP route enforcement installed (every minute)"

else
    warn "WAN routing issues left unresolved"
fi

#----





fi
log "Multi-WAN configuration complete!"
# -------------------------------------------------
# Check IPv4 forwarding
# -------------------------------------------------
log "Checking IP forwarding status..."
if [[ "$(/usr/sbin/sysctl -n net.ipv4.ip_forward)" -eq 1 ]]; then
    log "IP forwarding is already enabled."
else
    log "IP forwarding is disabled. Enabling..."
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.conf
    sysctl -w net.ipv4.ip_forward=1
    sysctl --system
    log "IP forwarding enabled."
fi

# -------------------------------------------------
# Check RP filters
# -------------------------------------------------
if [[ "$(/usr/sbin/sysctl -n net.ipv4.conf.all.rp_filter)" -ne 0 ]]; then
    log "RP filter (all) is enabled. Disabling..."
    echo "net.ipv4.conf.all.rp_filter=0" >> /etc/sysctl.conf
    sysctl -w net.ipv4.conf.all.rp_filter=0
    log "RP filter (all) disabled."
else
    log "RP filter (all) already disabled."
fi

if [[ "$(/usr/sbin/sysctl -n net.ipv4.conf.default.rp_filter)" -ne 0 ]]; then
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

for iface in "${ACTIVE_WAN[@]}"; do
    # NAT
    if ! /usr/sbin/iptables -t nat -C POSTROUTING -o "$iface" -j MASQUERADE &>/dev/null; then
        log "NAT rule missing for $iface. Adding..."
        iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
        netfilter-persistent save
        log "NAT rule added for $iface."
    else
        log "NAT rule already exists for $iface."
    fi

    # Forward: LAN -> WAN
    if ! /usr/sbin/iptables -C FORWARD -i eno1 -o "$iface" -j ACCEPT &>/dev/null; then
        log "FORWARD rule LAN -> $iface missing. Adding..."
        iptables -A FORWARD -i eno1 -o "$iface" -j ACCEPT
        netfilter-persistent save
        log "FORWARD rule LAN -> $iface added."
    else
        log "FORWARD rule LAN -> $iface already exists."
    fi

    # Forward: WAN -> LAN (return traffic)
    if ! /usr/sbin/iptables -C FORWARD -i "$iface" -o eno1 -m state --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null; then
        log "FORWARD rule WAN -> LAN (RELATED,ESTABLISHED) missing. Adding..."
        iptables -A FORWARD -i "$iface" -o eno1 -m state --state RELATED,ESTABLISHED -j ACCEPT
        netfilter-persistent save
        log "FORWARD rule WAN -> LAN added."
    else
        log "FORWARD rule WAN -> LAN (RELATED,ESTABLISHED) already exists."
    fi
done




# -------------------------------------------------
# Optional UFW check (only if installed & active)
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
                log "Adjusting UFW for forwarding and NAT..."

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
    IP=$(ip -o -4 addr show "$iface" | awk '{print $4}')
    GW=$(ip route show dev "$iface" | awk '/default/ {print $3}')
    log "WAN interface $iface has IP: $IP"
    log "WAN Gateway for $iface: $GW"
done

log "Network and iptables configuration is complete and verified."
