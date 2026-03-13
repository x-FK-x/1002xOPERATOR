#!/bin/bash

cp /etc/network/interfaces /etc/network/interfaces_before-dhcp

# =========================
# Logging functions
# =========================
log() {
    echo "[INFO] $1"
}

warn() {
    echo "[WARN] $1"
}

error() {
    echo "[ERROR] $1"
    exit 1
}

# =========================
# Root check
# =========================
if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root."
fi

# =========================
# Dependency check: nmcli
# =========================
if ! command -v nmcli >/dev/null 2>&1; then
    log "nmcli not found. Installing NetworkManager..."
    apt-get update -y || error "apt update failed"
    apt-get install -y network-manager || error "NetworkManager install failed"
    systemctl enable NetworkManager
    systemctl start NetworkManager
    log "NetworkManager installed."
fi

# =========================
# Detect interfaces
# =========================
log "Detecting network interfaces..."

mapfile -t INTERFACES < <(
    ip -o link show \
    | awk -F': ' '{print $2}' \
    | grep -v '^lo$'
)

if [[ ${#INTERFACES[@]} -lt 2 ]]; then
    error "At least two network interfaces are required."
fi

echo "Available interfaces:"
for i in "${!INTERFACES[@]}"; do
    printf "  [%d] %s\n" "$i" "${INTERFACES[$i]}"
done

echo
read -rp "Select the LAN interface by number: " LAN_INDEX

if ! [[ "$LAN_INDEX" =~ ^[0-9]+$ ]] || [[ "$LAN_INDEX" -ge ${#INTERFACES[@]} ]]; then
    error "Invalid LAN selection."
fi

LAN_INTERFACE="${INTERFACES[$LAN_INDEX]}"
log "Selected LAN interface: $LAN_INTERFACE"

# =========================
# Determine WAN interfaces
# =========================
WAN_INTERFACES=()
for i in "${!INTERFACES[@]}"; do
    [[ "$i" -ne "$LAN_INDEX" ]] && WAN_INTERFACES+=("${INTERFACES[$i]}")
done

log "WAN interfaces: ${WAN_INTERFACES[*]}"

# =========================
# Bring interfaces UP
# =========================
for IFACE in "$LAN_INTERFACE" "${WAN_INTERFACES[@]}"; do
    STATE=$(ip link show "$IFACE" | awk '/state/ {print $9}')
    if [[ "$STATE" == "DOWN" ]]; then
        log "Bringing up $IFACE..."
        ip link set "$IFACE" up
    fi
done

# =========================
# WAN WLAN warning only
# =========================
# =========================
# WAN WLAN check (only warn if unconfigured)
# =========================
for WAN in "${WAN_INTERFACES[@]}"; do
    if [[ "$WAN" =~ ^wl ]]; then
        if ip -4 addr show "$WAN" | grep -q "inet "; then
            log "WAN WLAN $WAN already has an IP address. Assuming configured."
        else
            warn "WAN interface $WAN is WLAN but has no IPv4 address."
            warn "No client configuration detected."
            warn "You can configure it manually using:"
            warn "  nmcli device rescan"
            warn "  nmcli device wifi list"
            warn "  nmcli device wifi connect 'SSID_NAME' password 'xxx'"
            warn "  IF HIDDEN SSID:"
            warn "  nmcli device wifi connect 'SSID_NAME' password 'xxx' hidden yes"
	    exit 0
        fi
    fi
done

# =========================
# LAN WLAN handling (AP only)
# =========================
if [[ "$LAN_INTERFACE" =~ ^wl ]]; then
    echo
    log "LAN interface is WLAN. Configuring Access Point."

    read -rp "Enter SSID for LAN WLAN: " SSID_LAN
    read -rp "Enter password for LAN WLAN: " PASSWORD_LAN

    if [[ -z "$SSID_LAN" || -z "$PASSWORD_LAN" ]]; then
        error "SSID or password missing for LAN WLAN."
    fi

    log "Creating WLAN Access Point '$SSID_LAN' on $LAN_INTERFACE..."
    nmcli dev wifi hotspot \
        ifname "$LAN_INTERFACE" \
        con-name "LAN-${SSID_LAN}" \
        ssid "$SSID_LAN" \
        password "$PASSWORD_LAN" \
        || error "Failed to create LAN WLAN Access Point."

    log "LAN WLAN Access Point '$SSID_LAN' created successfully."
else
    log "LAN interface is not WLAN. No WLAN configuration required."
fi

log "Network setup finished."

log "Network configuration completed successfully."


log "Configuring IP addresses..."
# =========================
# Subnet and LAN IP Configuration
# =========================

# Subnetz-Eingabe für den Benutzer
SUBNET_INPUT=$(whiptail --title "Subnet Selection" --inputbox \
    "Enter the subnet (e.g., 192.168.0.0/24, 172.16.0.0/16, 10.0.0.0/8, or even /25 for smaller subnets):" 8 60 "192.168.1.0/24" 3>&1 1>&2 2>&3)

if [[ $? -ne 0 || -z "$SUBNET_INPUT" ]]; then
    error "No subnet entered."
    exit 1
fi

# Extrahieren von Subnetz und Netzmaske (CIDR)
LAN_SUBNET=$(echo $SUBNET_INPUT | cut -d'/' -f1)
LAN_NETMASK_CIDR=$(echo $SUBNET_INPUT | cut -d'/' -f2)

# Zuordnung von CIDR-Wert zu Netzmaske
case "$LAN_NETMASK_CIDR" in
    8) LAN_NETMASK="255.0.0.0" ;;
    16) LAN_NETMASK="255.255.0.0" ;;
    24) LAN_NETMASK="255.255.255.0" ;;
    25) LAN_NETMASK="255.255.255.128" ;;
    26) LAN_NETMASK="255.255.255.192" ;;
    27) LAN_NETMASK="255.255.255.224" ;;
    28) LAN_NETMASK="255.255.255.240" ;;
    29) LAN_NETMASK="255.255.255.248" ;;
    30) LAN_NETMASK="255.255.255.252" ;;
    32) LAN_NETMASK="255.255.255.255" ;;
    *) error "Unsupported CIDR value entered for subnet mask." ;;
esac

log "Configured LAN Subnet: $LAN_SUBNET"
log "Configured LAN Netmask: $LAN_NETMASK"

# LAN-IP-Eingabe für den Benutzer
LAN_IP=$(whiptail --title "LAN IP Address" --inputbox \
    "Enter the IP address for the LAN ($LAN_INTERFACE):" 8 40 "$LAN_SUBNET" 3>&1 1>&2 2>&3)

if [[ $? -ne 0 || -z "$LAN_IP" ]]; then
    error "No IP address entered for LAN interface."
    exit 1
fi

# =========================
# LAN Interface Configuration
# =========================

log "Configuring LAN interface $LAN_INTERFACE with IP address $LAN_IP and netmask $LAN_NETMASK..."

# Prüfen, ob die IP-Adresse bereits gesetzt ist, und ggf. entfernen
ip addr show "$LAN_INTERFACE" | grep "$LAN_IP" && ip addr del "$LAN_IP/$LAN_NETMASK_CIDR" dev "$LAN_INTERFACE"

# Verwende den 'ip' Befehl, um die IP-Adresse zu setzen
ip addr add "$LAN_IP/$LAN_NETMASK_CIDR" dev "$LAN_INTERFACE"
if [[ $? -ne 0 ]]; then
    error "Failed to configure LAN interface $LAN_INTERFACE."
    exit 1
fi
log "LAN interface $LAN_INTERFACE configured successfully."

# Hinzufügen/Überschreiben der Konfiguration in /etc/network/interfaces
log "Overwriting LAN configuration in /etc/network/interfaces..."

# Lösche die bestehende Konfiguration für die LAN-Schnittstelle, falls vorhanden
sed -i "/allow-hotplug $LAN_INTERFACE" /etc/network/interfaces
sed -i "/iface $LAN_INTERFACE inet static/,+4d" /etc/network/interfaces

# Füge die neue Konfiguration hinzu
echo -e "\n# Configuration for $LAN_INTERFACE" >> /etc/network/interfaces
echo -e "allow-hotplug $LAN_INTERFACE" >> /etc/network/interfaces
echo -e "iface $LAN_INTERFACE inet static" >> /etc/network/interfaces
echo -e "    address $LAN_IP" >> /etc/network/interfaces
echo -e "    netmask $LAN_NETMASK" >> /etc/network/interfaces
log "LAN configuration added/overwritten in /etc/network/interfaces."

# Neustart des Netzwerkinterfaces (wird mit ip link statt ifdown/ifup durchgeführt)
log "Restarting the network interface to apply changes..."
ip link set "$LAN_INTERFACE" down
ip link set "$LAN_INTERFACE" up
if [[ $? -ne 0 ]]; then
    error "Failed to restart LAN interface $LAN_INTERFACE."
    exit 1
fi

log "LAN interface $LAN_INTERFACE configured successfully."

# =========================
# WAN Interface Configuration
# =========================

WAN_INTERFACES=()
for IFACE in "${INTERFACES[@]}"; do
    # WAN-Schnittstellen (die NICHT LAN sind) finden
    if [[ "$IFACE" != "$LAN_INTERFACE" ]]; then
        WAN_INTERFACES+=("$IFACE")
    fi
done

# Überprüfen, ob WAN-Schnittstellen gefunden wurden
if [[ ${#WAN_INTERFACES[@]} -eq 0 ]]; then
    error "No WAN interfaces found."
    exit 1
fi

# Überprüfen der WAN-Schnittstellen auf IP und Gateway
for WAN_INTERFACE in "${WAN_INTERFACES[@]}"; do
    WAN_IP=$(ip addr show "$WAN_INTERFACE" | grep 'inet ' | awk '{print $2}')
    if [[ -z "$WAN_IP" ]]; then
        error "No IP address found for WAN interface $WAN_INTERFACE. Exiting setup."
        exit 1
    fi

    log "WAN interface $WAN_INTERFACE already has an IP address: $WAN_IP."

    # Ermitteln des WAN-Gateways (automatisch)
    WAN_GATEWAY=$(ip route show dev "$WAN_INTERFACE" | awk '/default/ {print $3}')
    if [[ -z "$WAN_GATEWAY" ]]; then
        error "No WAN gateway found for $WAN_INTERFACE. Exiting setup."
        exit 1
    fi

    log "WAN Gateway for $WAN_INTERFACE: $WAN_GATEWAY"
done


# =========================
# DNS Configuration (Beibehalten)
# =========================
DNS_SERVERS=$(whiptail --title "DNS Servers" --inputbox \
    "Enter DNS servers (e.g., 8.8.8.8, 8.8.4.4):" 8 40 "8.8.8.8, 8.8.4.4" 3>&1 1>&2 2>&3)

if [[ $? -ne 0 || -z "$DNS_SERVERS" ]]; then
    error "No DNS servers entered."
    exit 1
fi

log "DNS servers configured: $DNS_SERVERS"


# =========================
# DHCP Range Configuration
# =========================

# Dynamisch den Start- und Endbereich des DHCP aus der LAN-IP berechnen
IFS='.' read -r -a ip_parts <<< "$LAN_IP"

# Start beim nächsten IP nach der LAN IP (z.B. wenn LAN_IP=10.2.0.65, dann beginnt der DHCP-Bereich bei 10.2.0.66)
DHCP_START="${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.$((ip_parts[3] + 1))"
# Endbereich, z.B. 50 Adressen nach dem Start (optional, kann angepasst werden)
DHCP_END="${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.$((ip_parts[3] + 51))"

# Warnung an den Benutzer, wenn der Bereich mit der LAN IP kollidiert
if [[ "$DHCP_START" == "$LAN_IP" ]]; then
    whiptail --title "DHCP Range Error" --msgbox \
        "Warning: The DHCP range cannot overlap with the LAN IP address. Please enter a different range." 8 45
    exit 1
fi

# Sicherstellen, dass der Bereich nicht mit der LAN IP oder der Gateway-IP kollidiert
if [[ "$DHCP_START" == "$LAN_IP" || "$DHCP_START" == "10.2.0.65" ]]; then
    whiptail --title "DHCP Range Error" --msgbox \
        "Warning: The DHCP range cannot overlap with the gateway IP address. Please enter a different range." 8 45
    exit 1
fi

# DHCP Range Eingabe mit Default-Werten
DHCP_RANGE_INPUT=$(whiptail --title "DHCP Range Configuration" --inputbox \
    "Enter the DHCP start and end range (default is $DHCP_START to $DHCP_END):" 8 60 "$DHCP_START-$DHCP_END" 3>&1 1>&2 2>&3)

if [[ $? -ne 0 || -z "$DHCP_RANGE_INPUT" ]]; then
    error "No DHCP range entered."
    exit 1
fi

# Aufteilen des Range-Eingabewerts in Start- und End-IP
IFS='-' read -r DHCP_START DHCP_END <<< "$DHCP_RANGE_INPUT"

log "Setting up DHCP range: $DHCP_START to $DHCP_END"

#=========================
# Configure NAT & Forwarding
#=========================

# Ensure iptables-persistent is installed
apt-get install -y iptables-persistent
log "iptables-persistent installed."

# Overwrite sysctl.conf as in your original setup
touch /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" > /etc/sysctl.conf
echo "net.ipv4.conf.all.rp_filter=0" >> /etc/sysctl.conf
echo "net.ipv4.conf.default.rp_filter=0" >> /etc/sysctl.conf

# Apply immediately
sysctl --system
log "IP forwarding & RP filters enabled."

# Set up NAT and FORWARD rules
for iface in "${WAN_INTERFACES[@]}"; do
    # Only configure if interface has an IPv4 address
    if ip addr show "$iface" | grep -q "inet "; then

        # NAT: POSTROUTING
        if ! iptables -t nat -C POSTROUTING -o "$iface" -j MASQUERADE &>/dev/null; then
            log "Setting up NAT for $iface..."
            iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
        else
            log "NAT already exists for $iface, skipping..."
        fi

        # Forward: LAN -> WAN
        if ! iptables -C FORWARD -i eno1 -o "$iface" -j ACCEPT &>/dev/null; then
            log "Setting up FORWARD rule LAN -> $iface..."
            iptables -A FORWARD -i eno1 -o "$iface" -j ACCEPT
        else
            log "Forward rule LAN -> $iface exists, skipping..."
        fi

        # Forward: WAN -> LAN (return traffic)
        if ! iptables -C FORWARD -i "$iface" -o eno1 -m state --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null; then
            log "Setting up FORWARD rule WAN -> LAN..."
            iptables -A FORWARD -i "$iface" -o eno1 -m state --state RELATED,ESTABLISHED -j ACCEPT
        else
            log "Forward rule WAN -> LAN exists, skipping..."
        fi

    else
        log "Skipping $iface (no IP assigned)"
    fi
done

# Save rules permanently
netfilter-persistent save

# =========================
# Configure ISC DHCP Server
# =========================

# Installiere ISC DHCP Server, wenn noch nicht installiert
log "Installing ISC DHCP server..."
apt-get install -y isc-dhcp-server
if [[ $? -ne 0 ]]; then
    error "Failed to install ISC DHCP server."
    exit 1
fi

log "Setting up DHCP server configuration..."
cat > /etc/dhcp/dhcpd.conf <<EOL
subnet $LAN_SUBNET netmask $LAN_NETMASK {
    range $DHCP_START $DHCP_END;
    option routers $LAN_IP;
    option domain-name-servers $DNS_SERVERS;
}
EOL
if [[ $? -ne 0 ]]; then
    error "Failed to write DHCP configuration."
    exit 1
fi

# Setze den DHCP Server, um die LAN-Schnittstelle zu verwenden
if ! grep -q "INTERFACESv4" /etc/default/isc-dhcp-server; then
    echo "INTERFACESv4=\"$LAN_INTERFACE\"" > /etc/default/isc-dhcp-server
    if [[ $? -ne 0 ]]; then
        error "Failed to update isc-dhcp-server configuration."
        exit 1
    fi
fi

# DHCP Server neustarten
log "Restarting DHCP server..."
systemctl restart isc-dhcp-server
if [[ $? -ne 0 ]]; then
    error "Failed to restart DHCP server."
    exit 1
fi

log "DHCP server restarted and ready."

log "Network configuration completed successfully."

exit 0
