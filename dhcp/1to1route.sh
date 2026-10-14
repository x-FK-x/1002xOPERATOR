#!/bin/bash
# 1to1route.sh – Interactive static route manager with resilient WLAN
# Generates soloroute.sh, which re-applies saved routes every minute via cron
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "[ERROR] Must be run as root."; exit 1; }
command -v whiptail &>/dev/null || { echo "[ERROR] Please install whiptail first (apt install whiptail)"; exit 1; }

CONFIG_DIR="/etc/1002xOPERATOR/dhcp/settings"
CONFIG_FILE="$CONFIG_DIR/static-routes.conf"
APPLY_SCRIPT="$CONFIG_DIR/soloroute.sh"
DHCP_DEFAULTS="/etc/default/isc-dhcp-server"

mkdir -p "$CONFIG_DIR"
touch "$CONFIG_FILE"

# DHCP server interface, excluded from the selectable interfaces
DHCP_IF=$(awk -F'=' '/^INTERFACESv4=/ {gsub(/"/,"",$2); print $2}' "$DHCP_DEFAULTS" 2>/dev/null | tr -d ' ' || true)

valid_ipv4() {
    local ip=$1 o
    [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

# Accepts a plain IPv4 address or IPv4 with prefix length (0-32)
valid_dest() {
    local ip=${1%/*} prefix=""
    [[ $1 == */* ]] && prefix=${1#*/}
    valid_ipv4 "$ip" || return 1
    [[ -z $prefix ]] && return 0
    [[ $prefix =~ ^[0-9]{1,2}$ ]] && (( 10#$prefix <= 32 ))
}

# ask_value PROMPT DEFAULT VALIDATOR – repeats until valid, returns 1 on cancel/empty
ask_value() {
    local value
    while true; do
        value=$(whiptail --inputbox "$1" 10 60 "$2" 3>&1 1>&2 2>&3) || return 1
        value=${value// /}
        [[ -z $value ]] && return 1
        if "$3" "$value"; then
            echo "$value"
            return 0
        fi
        whiptail --msgbox "Invalid value: $value" 8 60
    done
}

# Excludes lo and the DHCP server interface
list_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | while IFS= read -r name; do
        [[ $name == lo || -z $name || $name == "$DHCP_IF" ]] && continue
        echo "$name"
    done
}

# Default gateway for one interface only
gateway_for() {
    ip -4 route show default dev "$1" 2>/dev/null | awk '{print $3; exit}'
}

# Stores "DEST IFACE" once, replacing an older entry for the same pair.
# The gateway is not stored, because soloroute.sh looks it up on every run.
save_route() {
    local tmp
    tmp=$(mktemp)
    awk -v d="$1" -v i="$2" '!($1 == d && $2 == i)' "$CONFIG_FILE" > "$tmp"
    echo "$1 $2" >> "$tmp"
    mv "$tmp" "$CONFIG_FILE"
}

while true; do
    CHOICE=$(whiptail --title "1to1route Manager" --menu "Select action:" 15 50 5 \
        1 "Add new route" \
        2 "Delete existing route" \
        3 "Show saved routes" \
        4 "Exit" 3>&1 1>&2 2>&3) || break

    case "$CHOICE" in
        1)
            mapfile -t INTERFACES < <(list_interfaces)
            if (( ${#INTERFACES[@]} == 0 )); then
                whiptail --msgbox "No suitable interfaces found." 10 60
                continue
            fi

            MENU_ITEMS=()
            for i in "${INTERFACES[@]}"; do MENU_ITEMS+=("$i" ""); done
            SELECT_IF=$(whiptail --title "Select Interface" --menu "Choose interface for the route:" 15 50 6 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3) || continue

            DEST_IP=$(ask_value "Enter destination IP or subnet (e.g. 10.2.50.0/24):" "" valid_dest) || continue

            GW=$(gateway_for "$SELECT_IF")
            if [[ -z $GW ]]; then
                whiptail --msgbox "No gateway found for $SELECT_IF, cannot add route." 10 60
                continue
            fi

            if ip route replace "$DEST_IP" via "$GW" dev "$SELECT_IF"; then
                save_route "$DEST_IP" "$SELECT_IF"
                whiptail --msgbox "Route $DEST_IP via $SELECT_IF ($GW) saved and applied!" 10 60
            else
                whiptail --msgbox "Failed to apply route $DEST_IP via $SELECT_IF. Nothing saved." 10 60
            fi
            ;;

        2)
            if [[ ! -s $CONFIG_FILE ]]; then
                whiptail --msgbox "No saved routes to delete." 10 50
                continue
            fi

            # Menu tag = line number in the file, so sed targets the right line even with blank lines
            ROUTES=()
            LINE_NO=0
            while IFS= read -r line; do
                LINE_NO=$((LINE_NO + 1))
                [[ -z $line ]] && continue
                ROUTES+=("$LINE_NO" "$line")
            done < "$CONFIG_FILE"

            SELECT_DEL=$(whiptail --title "Delete Route" --menu "Select route to delete:" 20 70 10 "${ROUTES[@]}" 3>&1 1>&2 2>&3) || continue

            DEL_LINE=$(sed -n "${SELECT_DEL}p" "$CONFIG_FILE")
            read -r DEL_DEST DEL_IF _ <<< "$DEL_LINE"
            sed -i "${SELECT_DEL}d" "$CONFIG_FILE"
            ip route del "$DEL_DEST" dev "$DEL_IF" 2>/dev/null || true

            whiptail --msgbox "Route '$DEL_LINE' deleted!" 10 60
            ;;

        3)
            if [[ ! -s $CONFIG_FILE ]]; then
                whiptail --msgbox "No saved routes." 10 50
                continue
            fi
            whiptail --title "Saved Routes" --scrolltext --msgbox "$(cat "$CONFIG_FILE")" 20 70
            ;;

        4)
            break
            ;;
    esac
done

# --- soloroute.sh erzeugen ---
cat > "$APPLY_SCRIPT" <<'EOF'
#!/bin/bash
# soloroute.sh – generated by 1to1route.sh, do not edit by hand
# Cron runs with a minimal PATH, so it is set explicitly here.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CONFIG_FILE="/etc/1002xOPERATOR/dhcp/settings/static-routes.conf"
[[ -f "$CONFIG_FILE" ]] || exit 0

while read -r DEST IFACE _; do
    [[ -z "$DEST" || "$DEST" == \#* ]] && continue

    # Gateway is looked up on every run, so a changed WLAN lease is picked up
    GW=$(ip -4 route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}')
    [[ -z "$GW" ]] && continue

    ip route replace "$DEST" via "$GW" dev "$IFACE" || logger -t soloroute "failed: $DEST via $IFACE"
done < "$CONFIG_FILE"
EOF

chmod +x "$APPLY_SCRIPT"

# --- Cronjob einrichten ---
CRON_LINE="* * * * * /bin/bash $APPLY_SCRIPT"
(crontab -l 2>/dev/null | grep -v -F "$APPLY_SCRIPT"; echo "$CRON_LINE") | crontab -

echo "soloroute.sh created at $APPLY_SCRIPT with resilient WLAN support and cronjob installed."
