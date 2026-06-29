#!/bin/bash
# /etc/1002xOPERATOR/dns/firstrun.sh
# Initial setup for dnsmasq DNS Server
# Installs dnsmasq, configures interface/upstream/domain/cache
# Optionally enables DNS-based adblocking (sinkhole) during setup

BASE_DIR="/etc/1002xOPERATOR/dns"
DNSMASQ_CONF="/etc/dnsmasq.conf"
DNSMASQ_D="/etc/dnsmasq.d"
LOCAL_HOSTS="$DNSMASQ_D/1002x-local-hosts.conf"
CUSTOM_ZONES="$DNSMASQ_D/1002x-custom-zones.conf"
ADBLOCK_CONF="$DNSMASQ_D/1002x-adblock.conf"
ADBLOCK_DIR="$BASE_DIR/blocklists"
WHITELIST_FILE="$BASE_DIR/whitelist.txt"
SINKHOLE_IP="0.0.0.0"

# =========================
# Logging
# =========================
log()   { echo "[INFO] $1"; }
warn()  { echo "[WARN] $1"; }
error() { echo "[ERROR] $1"; exit 1; }

# =========================
# Root check
# =========================
if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root."
fi

# =========================
# Dependency check: dnsmasq
# =========================
if ! command -v dnsmasq &>/dev/null; then
    whiptail --yesno "dnsmasq is not installed. Install it now?" 8 50
    if [[ $? -eq 0 ]]; then
        apt-get update -y || error "apt update failed"
        apt-get install -y dnsmasq || error "dnsmasq install failed"
        log "dnsmasq installed."
    else
        error "dnsmasq is required. Aborting."
    fi
fi

# =========================
# Backup existing config
# =========================
if [[ -f "$DNSMASQ_CONF" ]]; then
    cp "$DNSMASQ_CONF" "${DNSMASQ_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    log "Backed up existing dnsmasq.conf"
fi

# =========================
# Detect LAN interface
# =========================
LAN_IF=$(grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server 2>/dev/null | cut -d'"' -f2)
if [[ -z "$LAN_IF" ]]; then
    mapfile -t IFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$')
    IFACE_MENU=()
    for i in "${!IFACES[@]}"; do
        IFACE_MENU+=("${IFACES[$i]}" "Interface $i")
    done
    LAN_IF=$(whiptail --title "Select Interface" \
        --menu "Select the LAN interface for dnsmasq:" 15 55 8 \
        "${IFACE_MENU[@]}" 3>&1 1>&2 2>&3) || error "No interface selected."
fi
log "Using interface: $LAN_IF"

LAN_IP=$(ip -4 addr show dev "$LAN_IF" 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
[[ -z "$LAN_IP" ]] && LAN_IP=$(hostname -I | awk '{print $1}')
log "LAN IP: $LAN_IP"

# =========================
# Upstream DNS selection
# =========================
UPSTREAM=$(whiptail --title "Upstream DNS" \
    --menu "Select upstream DNS servers:" 16 60 6 \
    "cloudflare" "1.1.1.1 + 1.0.0.1" \
    "google"     "8.8.8.8 + 8.8.4.4" \
    "quad9"      "9.9.9.9 + 149.112.112.112 (security)" \
    "opendns"    "208.67.222.222 + 208.67.220.220" \
    "custom"     "Enter manually" \
    "none"       "No upstream (local only)" \
    3>&1 1>&2 2>&3) || error "No upstream selected."

case "$UPSTREAM" in
    cloudflare) DNS1="1.1.1.1";        DNS2="1.0.0.1" ;;
    google)     DNS1="8.8.8.8";        DNS2="8.8.4.4" ;;
    quad9)      DNS1="9.9.9.9";        DNS2="149.112.112.112" ;;
    opendns)    DNS1="208.67.222.222"; DNS2="208.67.220.220" ;;
    custom)
        DNS1=$(whiptail --inputbox "Primary DNS server:" 8 50 3>&1 1>&2 2>&3) || error "Aborted."
        DNS2=$(whiptail --inputbox "Secondary DNS server (leave empty for none):" 8 50 3>&1 1>&2 2>&3)
        ;;
    none) DNS1=""; DNS2="" ;;
esac

# =========================
# Local domain
# =========================
LOCAL_DOMAIN=$(whiptail --inputbox "Local domain name (e.g. home.lan):" 8 55 "home.lan" \
    3>&1 1>&2 2>&3) || LOCAL_DOMAIN="home.lan"
LOCAL_DOMAIN="${LOCAL_DOMAIN//[^a-zA-Z0-9._-]/}"
[[ -z "$LOCAL_DOMAIN" ]] && LOCAL_DOMAIN="home.lan"

# =========================
# Cache size
# =========================
CACHE_SIZE=$(whiptail --inputbox "DNS cache size (entries, 0 = disable):" 8 55 "1000" \
    3>&1 1>&2 2>&3) || CACHE_SIZE="1000"
[[ ! "$CACHE_SIZE" =~ ^[0-9]+$ ]] && CACHE_SIZE=1000

# =========================
# Adblock question
# =========================
SETUP_ADBLOCK=0
ADBLOCK_PRESET="none"
BLOCKED_COUNT=0

whiptail --title "DNS Adblock" \
    --yesno "Enable DNS-based adblocking?\n\nBlocks ads and trackers for ALL devices\nusing this DNS server by responding with\n$SINKHOLE_IP for blocked domains.\n\nYou can choose a blocklist in the next step." \
    13 58
if [[ $? -eq 0 ]]; then
    SETUP_ADBLOCK=1

    ADBLOCK_PRESET=$(whiptail --title "Adblock – Initial Blocklist" \
        --menu "Select a blocklist to download now:" 18 68 6 \
        "stevenblack"     "Steven Black Unified Hosts  (~130k domains)" \
        "someonewhocares" "Dan Pollock hosts            (~15k domains)" \
        "adaway"          "AdAway default hosts         (~400 entries)" \
        "oisd-small"      "OISD Small                   (~50k domains)" \
        "hagezi-light"    "HaGeZi Light                 (~200k domains)" \
        "none"            "Skip – configure manually later via adblock.sh" \
        3>&1 1>&2 2>&3) || ADBLOCK_PRESET="none"
fi

# =========================
# Write dnsmasq.conf
# =========================
mkdir -p "$BASE_DIR" "$DNSMASQ_D" "$ADBLOCK_DIR"
touch "$WHITELIST_FILE" 2>/dev/null

cat > "$DNSMASQ_CONF" <<EOF
# /etc/dnsmasq.conf
# Managed by 1002xOPERATOR DNS
# Generated: $(date)

# === Interface ===
interface=$LAN_IF
bind-interfaces

# === Upstream DNS ===
$([ -n "$DNS1" ] && echo "server=$DNS1")
$([ -n "$DNS2" ] && echo "server=$DNS2")

# === Local domain ===
local=/$LOCAL_DOMAIN/
domain=$LOCAL_DOMAIN
expand-hosts

# === Cache ===
cache-size=$CACHE_SIZE
neg-ttl=60

# === Security ===
domain-needed
bogus-priv
no-resolv

# === Includes ===
conf-dir=$DNSMASQ_D,*.conf
EOF

echo "# 1002xOPERATOR – local host entries" > "$LOCAL_HOSTS"
echo "# 1002xOPERATOR – custom zones and forwards" > "$CUSTOM_ZONES"
log "dnsmasq.conf written."

# =========================
# Adblock: download + convert
# =========================
_convert_and_write_adblock() {
    local src_file="$1"
    local list_name="$2"

    echo "# 1002xOPERATOR DNS Adblock – generated $(date)" > "$ADBLOCK_CONF"
    echo "# Source: $list_name" >> "$ADBLOCK_CONF"
    echo "" >> "$ADBLOCK_CONF"

    grep -v '^#\|^!\|^$' "$src_file" | \
    awk '{
        if ($1 == "0.0.0.0" || $1 == "127.0.0.1") print $2
        else if (NF == 1 && $0 ~ /^[a-zA-Z0-9._-]+$/) print $0
    }' | \
    grep -v '^localhost$\|^0\.0\.0\.0$\|^127\.' | \
    sort -u | \
    while IFS= read -r domain; do
        echo "address=/$domain/$SINKHOLE_IP"
    done >> "$ADBLOCK_CONF"

    grep -c '^address=' "$ADBLOCK_CONF" 2>/dev/null || echo 0
}

if [[ "$SETUP_ADBLOCK" -eq 1 && "$ADBLOCK_PRESET" != "none" ]]; then
    case "$ADBLOCK_PRESET" in
        stevenblack)     BL_URL="https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" ;;
        someonewhocares) BL_URL="https://someonewhocares.org/hosts/hosts" ;;
        adaway)          BL_URL="https://adaway.org/hosts.txt" ;;
        oisd-small)      BL_URL="https://small.oisd.nl/domainswild" ;;
        hagezi-light)    BL_URL="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/light.txt" ;;
    esac

    whiptail --infobox "Downloading $ADBLOCK_PRESET blocklist ..." 6 55

    DL_TMP=$(mktemp)
    if curl -fsSL --max-time 120 "$BL_URL" -o "$DL_TMP" 2>/dev/null \
    || wget -qO "$DL_TMP" --timeout=120 "$BL_URL" 2>/dev/null; then
        mv "$DL_TMP" "$ADBLOCK_DIR/${ADBLOCK_PRESET}.txt"
        BLOCKED_COUNT=$(_convert_and_write_adblock "$ADBLOCK_DIR/${ADBLOCK_PRESET}.txt" "$ADBLOCK_PRESET")
        log "Adblock built: $BLOCKED_COUNT entries blocked."
    else
        rm -f "$DL_TMP"
        warn "Blocklist download failed. Adblock will be empty."
        echo "# 1002xOPERATOR DNS Adblock – download failed" > "$ADBLOCK_CONF"
        BLOCKED_COUNT=0
    fi

elif [[ "$SETUP_ADBLOCK" -eq 1 && "$ADBLOCK_PRESET" == "none" ]]; then
    echo "# 1002xOPERATOR DNS Adblock – no list loaded yet" > "$ADBLOCK_CONF"
    BLOCKED_COUNT=0
fi

# =========================
# Enable & start service
# =========================
systemctl enable dnsmasq
systemctl restart dnsmasq

# =========================
# Summary
# =========================
if systemctl is-active --quiet dnsmasq; then
    log "dnsmasq is running."

    if [[ "$SETUP_ADBLOCK" -eq 1 ]]; then
        if [[ "$BLOCKED_COUNT" -gt 0 ]]; then
            ADBLOCK_LINE="Adblock   : ENABLED  ($BLOCKED_COUNT domains blocked)"
        else
            ADBLOCK_LINE="Adblock   : ENABLED  (no list yet – run adblock.sh)"
        fi
    else
        ADBLOCK_LINE="Adblock   : disabled  (run adblock.sh to enable)"
    fi

    whiptail --title "Setup Complete" --msgbox \
"DNS Server setup complete!

Interface : $LAN_IF  ($LAN_IP)
Domain    : $LOCAL_DOMAIN
Upstream  : ${DNS1:-none}${DNS2:+ / $DNS2}
Cache     : $CACHE_SIZE entries
$ADBLOCK_LINE

Point clients to $LAN_IP as their DNS server." 17 62
else
    whiptail --msgbox "WARNING: dnsmasq failed to start.\nCheck: journalctl -u dnsmasq" 10 55
fi
