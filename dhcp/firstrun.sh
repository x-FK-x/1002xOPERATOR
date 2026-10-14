#!/bin/bash
set -uo pipefail

SYSCTL_DROPIN="/etc/sysctl.d/99-1002xoperator.conf"
BACKUP_DIR=""

log()  { echo "[INFO] $1"; }
warn() { echo "[WARN] $1"; }

error() {
    echo "[ERROR] $1" >&2
    if [[ -n $BACKUP_DIR && -d $BACKUP_DIR ]]; then
        warn "Restoring configuration files from $BACKUP_DIR"
        [[ -f $BACKUP_DIR/interfaces ]] && cp "$BACKUP_DIR/interfaces" /etc/network/interfaces
        [[ -f $BACKUP_DIR/dhcpd.conf ]] && cp "$BACKUP_DIR/dhcpd.conf" /etc/dhcp/dhcpd.conf
        [[ -f $BACKUP_DIR/isc-dhcp-server ]] && cp "$BACKUP_DIR/isc-dhcp-server" /etc/default/isc-dhcp-server
        if [[ -f $BACKUP_DIR/99-1002xoperator.conf.absent ]]; then
            rm -f "$SYSCTL_DROPIN"
        elif [[ -f $BACKUP_DIR/99-1002xoperator.conf ]]; then
            cp "$BACKUP_DIR/99-1002xoperator.conf" "$SYSCTL_DROPIN"
        fi
        warn "Live IP addresses and firewall rules are not reverted automatically."
    fi
    exit 1
}

[[ $EUID -eq 0 ]] || { echo "[ERROR] Please run this script as root." >&2; exit 1; }

BACKUP_DIR="/etc/1002xOPERATOR/backup/firstrun-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR" || error "Cannot create backup directory $BACKUP_DIR"
for f in /etc/network/interfaces /etc/dhcp/dhcpd.conf /etc/default/isc-dhcp-server /etc/sysctl.conf; do
    [[ -f $f ]] && cp "$f" "$BACKUP_DIR/$(basename "$f")"
done
if [[ -f $SYSCTL_DROPIN ]]; then
    cp "$SYSCTL_DROPIN" "$BACKUP_DIR/99-1002xoperator.conf"
else
    touch "$BACKUP_DIR/99-1002xoperator.conf.absent"
fi
log "Backup of current configuration: $BACKUP_DIR"

valid_ipv4() {
    local ip=$1 o
    [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

valid_dns_list() {
    local ip
    local -a ips
    IFS=',' read -ra ips <<< "$1"
    (( ${#ips[@]} > 0 )) || return 1
    for ip in "${ips[@]}"; do
        valid_ipv4 "$ip" || return 1
    done
    return 0
}

ip2int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

int2ip() {
    echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"
}

iface_ipv4()    { ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4}' | head -n1; }
gateway_for()   { ip -4 route show default dev "$1" 2>/dev/null | awk '{print $3; exit}'; }
iface_is_wlan() { [[ $1 =~ ^wl ]]; }

strip_iface_config() {
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
    ' /etc/network/interfaces
}

export DEBIAN_FRONTEND=noninteractive
NEED_PKGS=()
command -v nmcli                >/dev/null || NEED_PKGS+=(network-manager)
command -v whiptail             >/dev/null || NEED_PKGS+=(whiptail)
command -v dhcpd                >/dev/null || NEED_PKGS+=(isc-dhcp-server)
command -v netfilter-persistent >/dev/null || NEED_PKGS+=(iptables-persistent)
command -v ifup                 >/dev/null || NEED_PKGS+=(ifupdown)

if (( ${#NEED_PKGS[@]} > 0 )); then
    log "Installing missing packages: ${NEED_PKGS[*]}"
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
    apt-get update -y || error "apt-get update failed"
    apt-get install -y "${NEED_PKGS[@]}" || error "Package installation failed"
fi

systemctl enable --now NetworkManager >/dev/null 2>&1 || error "Could not start NetworkManager"

log "Detecting network interfaces..."
mapfile -t INTERFACES < <(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -vx 'lo')
(( ${#INTERFACES[@]} >= 2 )) || error "At least two network interfaces are required."

echo "Available interfaces:"
for i in "${!INTERFACES[@]}"; do
    printf "  [%d] %s\n" "$i" "${INTERFACES[$i]}"
done
echo
while true; do
    read -rp "Select the LAN interface by number: " LAN_INDEX
    if [[ $LAN_INDEX =~ ^[0-9]+$ ]] && (( LAN_INDEX < ${#INTERFACES[@]} )); then
        break
    fi
    warn "Invalid selection."
done
LAN_IF="${INTERFACES[$LAN_INDEX]}"

WAN_IFS=()
for i in "${!INTERFACES[@]}"; do
    (( i != LAN_INDEX )) && WAN_IFS+=("${INTERFACES[$i]}")
done
log "LAN interface: $LAN_IF"
log "WAN interfaces: ${WAN_IFS[*]}"

for IF in "$LAN_IF" "${WAN_IFS[@]}"; do
    ip link set "$IF" up
done

configure_wlan_client() {
    local ssid hidden pw
    local -a hidden_opt=()
    warn "WAN WLAN $1 has no IPv4 address. Starting WLAN client setup."
    nmcli device wifi rescan ifname "$1" >/dev/null 2>&1 || true
    nmcli -f SSID,SIGNAL,SECURITY device wifi list ifname "$1" 2>/dev/null || true
    echo
    read -rp "SSID for WAN WLAN $1: " ssid
    [[ -n $ssid ]] || error "No SSID entered for $1."
    read -rp "Is the SSID hidden? [y/N]: " hidden
    [[ $hidden =~ ^[yY]$ ]] && hidden_opt=(hidden yes)
    read -rsp "Password for '$ssid': " pw
    echo
    nmcli device wifi connect "$ssid" password "$pw" "${hidden_opt[@]}" ifname "$1" \
        || error "Could not connect $1 to '$ssid'."
}

wait_for_wan() {
    local i
    for i in $(seq 1 30); do
        if [[ -n $(iface_ipv4 "$1") && -n $(gateway_for "$1") ]]; then
            log "WAN $1: address $(iface_ipv4 "$1"), gateway $(gateway_for "$1")"
            return 0
        fi
        sleep 1
    done
    error "WAN interface $1 has no IPv4 address or default gateway after 30 seconds."
}

for WAN in "${WAN_IFS[@]}"; do
    if [[ -z $(iface_ipv4 "$WAN") ]] && iface_is_wlan "$WAN"; then
        configure_wlan_client "$WAN"
    fi
    wait_for_wan "$WAN"
done

while true; do
    SUBNET_INPUT=$(whiptail --title "LAN Subnet" --inputbox \
        "Enter the subnet (e.g. 192.168.1.0/24 or 10.2.0.0/16). Allowed: /8 to /30" \
        9 70 "192.168.1.0/24" 3>&1 1>&2 2>&3) || error "No subnet entered."
    SUBNET_INPUT=${SUBNET_INPUT// /}
    if [[ $SUBNET_INPUT =~ ^([0-9.]+)/([0-9]{1,2})$ ]]; then
        SUB_BASE=${BASH_REMATCH[1]}
        SUB_CIDR=$((10#${BASH_REMATCH[2]}))
        if valid_ipv4 "$SUB_BASE" && (( SUB_CIDR >= 8 && SUB_CIDR <= 30 )); then
            break
        fi
    fi
    whiptail --msgbox "Invalid subnet: $SUBNET_INPUT" 8 60
done

MASK=$(( (0xFFFFFFFF << (32 - SUB_CIDR)) & 0xFFFFFFFF ))
NET=$(( $(ip2int "$SUB_BASE") & MASK ))
BCAST=$(( NET | (~MASK & 0xFFFFFFFF) ))
LAN_SUBNET=$(int2ip "$NET")
LAN_NETMASK=$(int2ip "$MASK")
log "LAN subnet: $LAN_SUBNET/$SUB_CIDR (netmask $LAN_NETMASK)"

while true; do
    LAN_IP=$(whiptail --title "LAN IP Address" --inputbox \
        "Enter the IP address for the LAN ($LAN_IF):" 8 60 "$(int2ip $((NET + 1)))" \
        3>&1 1>&2 2>&3) || error "No LAN IP entered."
    LAN_IP=${LAN_IP// /}
    if valid_ipv4 "$LAN_IP"; then
        LAN_INT=$(ip2int "$LAN_IP")
        if (( (LAN_INT & MASK) == NET && LAN_INT != NET && LAN_INT != BCAST )); then
            break
        fi
    fi
    whiptail --msgbox "Invalid LAN IP for $LAN_SUBNET/$SUB_CIDR (not the network or broadcast address)." 8 70
done

DEF_START=$(( LAN_INT + 1 ))
DEF_END=$(( LAN_INT + 50 ))
(( DEF_END > BCAST - 1 )) && DEF_END=$(( BCAST - 1 ))

while true; do
    RANGE_INPUT=$(whiptail --title "DHCP Range" --inputbox \
        "Enter the DHCP range START-END (must be inside $LAN_SUBNET/$SUB_CIDR and must not contain $LAN_IP):" \
        9 70 "$(int2ip $DEF_START)-$(int2ip $DEF_END)" 3>&1 1>&2 2>&3) || error "No DHCP range entered."
    RANGE_INPUT=${RANGE_INPUT// /}
    if [[ $RANGE_INPUT =~ ^([0-9.]+)-([0-9.]+)$ ]]; then
        RS=${BASH_REMATCH[1]}
        RE=${BASH_REMATCH[2]}
        if valid_ipv4 "$RS" && valid_ipv4 "$RE"; then
            S=$(ip2int "$RS")
            E=$(ip2int "$RE")
            if (( (S & MASK) == NET && (E & MASK) == NET && S > NET && E < BCAST && S <= E )) \
               && (( LAN_INT < S || LAN_INT > E )); then
                break
            fi
        fi
    fi
    whiptail --msgbox "Invalid DHCP range. Both addresses must be inside $LAN_SUBNET/$SUB_CIDR, start must not exceed end, and the range must not contain $LAN_IP." 10 70
done
DHCP_START=$RS
DHCP_END=$RE
log "DHCP range: $DHCP_START - $DHCP_END"

while true; do
    DNS_SERVERS=$(whiptail --title "DNS Servers" --inputbox \
        "Enter DNS servers, comma separated (e.g. 8.8.8.8,8.8.4.4):" 8 60 "8.8.8.8,8.8.4.4" \
        3>&1 1>&2 2>&3) || error "No DNS servers entered."
    DNS_SERVERS=${DNS_SERVERS// /}
    valid_dns_list "$DNS_SERVERS" && break
    whiptail --msgbox "Invalid DNS list. Use comma separated IPv4 addresses." 8 60
done
DNS_SERVERS=${DNS_SERVERS//,/, }

configure_lan_ethernet() {
    local tmp
    whiptail --title "Apply LAN configuration" --yesno \
        "The LAN address $LAN_IP/$SUB_CIDR will be set on $LAN_IF now. Connections through $LAN_IF will drop briefly. Continue?" \
        10 70 || error "Cancelled by user."

    tmp=$(mktemp)
    {
        strip_iface_config "$LAN_IF"
        cat <<EOF

# BEGIN 1002xOPERATOR LAN $LAN_IF
auto $LAN_IF
iface $LAN_IF inet static
    address $LAN_IP
    netmask $LAN_NETMASK
# END 1002xOPERATOR LAN $LAN_IF
EOF
    } > "$tmp"
    cat "$tmp" > /etc/network/interfaces
    rm -f "$tmp"
    log "Saved LAN configuration to /etc/network/interfaces"

    ip -4 addr flush dev "$LAN_IF"
    ip addr add "$LAN_IP/$SUB_CIDR" dev "$LAN_IF" || error "Failed to set $LAN_IP on $LAN_IF"
    ip link set "$LAN_IF" up
    log "LAN interface $LAN_IF configured with $LAN_IP/$SUB_CIDR"
}

configure_lan_hotspot() {
    local ssid pw con tmp
    log "LAN interface $LAN_IF is WLAN. Creating access point via NetworkManager."
    read -rp "SSID for LAN WLAN: " ssid
    [[ -n $ssid ]] || error "SSID missing for LAN WLAN."
    read -rsp "Password for LAN WLAN (8-63 characters): " pw
    echo
    (( ${#pw} >= 8 && ${#pw} <= 63 )) || error "WPA2 password must be 8 to 63 characters."

    con="LAN-$ssid"
    nmcli con delete "$con" >/dev/null 2>&1 || true
    nmcli dev wifi hotspot ifname "$LAN_IF" con-name "$con" ssid "$ssid" password "$pw" \
        || error "Failed to create the access point."

    nmcli con modify "$con" ipv4.method manual ipv4.addresses "$LAN_IP/$SUB_CIDR" \
        ipv4.never-default yes ipv6.method disabled \
        || error "Failed to set the static address on the access point."
    nmcli con down "$con" >/dev/null 2>&1 || true
    nmcli con up "$con" || error "Failed to bring up the access point."

    tmp=$(mktemp)
    strip_iface_config "$LAN_IF" > "$tmp"
    cat "$tmp" > /etc/network/interfaces
    rm -f "$tmp"
    log "Access point '$ssid' is up on $LAN_IF with $LAN_IP/$SUB_CIDR"
}

if iface_is_wlan "$LAN_IF"; then
    configure_lan_hotspot
else
    configure_lan_ethernet
fi

cat > "$SYSCTL_DROPIN" <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
sysctl -p "$SYSCTL_DROPIN" >/dev/null || error "Failed to apply sysctl settings"
log "IP forwarding and rp_filter settings applied"

for WAN in "${WAN_IFS[@]}"; do
    iptables -t nat -C POSTROUTING -o "$WAN" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -o "$WAN" -j MASQUERADE \
        || error "NAT rule for $WAN failed"
    iptables -C FORWARD -i "$LAN_IF" -o "$WAN" -j ACCEPT 2>/dev/null \
        || iptables -A FORWARD -i "$LAN_IF" -o "$WAN" -j ACCEPT \
        || error "FORWARD rule LAN -> $WAN failed"
    iptables -C FORWARD -i "$WAN" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
        || iptables -A FORWARD -i "$WAN" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT \
        || error "FORWARD rule $WAN -> LAN failed"
    log "NAT and forwarding configured for $WAN"
done
netfilter-persistent save >/dev/null 2>&1 || error "Could not save firewall rules"

DHCPD_TMP=$(mktemp)
cat > "$DHCPD_TMP" <<EOF
authoritative;

subnet $LAN_SUBNET netmask $LAN_NETMASK {
    range $DHCP_START $DHCP_END;
    option routers $LAN_IP;
    option domain-name-servers $DNS_SERVERS;
}
EOF
if ! dhcpd -t -cf "$DHCPD_TMP" >/dev/null 2>&1; then
    rm -f "$DHCPD_TMP"
    error "Generated dhcpd.conf failed the configuration test."
fi
install -m 644 "$DHCPD_TMP" /etc/dhcp/dhcpd.conf
rm -f "$DHCPD_TMP"
log "Wrote /etc/dhcp/dhcpd.conf"

DHCP_DEFAULTS=/etc/default/isc-dhcp-server
if grep -q '^INTERFACESv4=' "$DHCP_DEFAULTS" 2>/dev/null; then
    sed -i "s|^INTERFACESv4=.*|INTERFACESv4=\"$LAN_IF\"|" "$DHCP_DEFAULTS"
else
    echo "INTERFACESv4=\"$LAN_IF\"" >> "$DHCP_DEFAULTS"
fi

systemctl enable isc-dhcp-server >/dev/null 2>&1
systemctl restart isc-dhcp-server || error "Failed to restart the DHCP server (see: journalctl -u isc-dhcp-server)"
systemctl is-active --quiet isc-dhcp-server || error "DHCP server is not active after restart"
log "DHCP server is active and serving $LAN_IF"

echo
log "=== Summary ==="
echo "  LAN:     $LAN_IF  $LAN_IP/$SUB_CIDR"
echo "  DHCP:    $DHCP_START - $DHCP_END"
echo "  DNS:     $DNS_SERVERS"
echo "  WAN:     ${WAN_IFS[*]}"
echo "  Backup:  $BACKUP_DIR"
log "Network configuration completed successfully."

exit 0
