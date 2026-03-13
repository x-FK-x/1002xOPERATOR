#!/bin/bash
# 1to1route.sh – Interactive Static Route Manager with resilient WLAN
# Generates soloroute.sh to apply saved routes automatically

CONFIG_DIR="/etc/1002xOPERATOR/dhcp/settings"
CONFIG_FILE="$CONFIG_DIR/static-routes.conf"
APPLY_SCRIPT="$CONFIG_DIR/soloroute.sh"

mkdir -p "$CONFIG_DIR"

# Prüfen ob whiptail installiert ist
if ! command -v whiptail &>/dev/null; then
    echo "Please install whiptail first (apt install whiptail)"
    exit 1
fi

# DHCP-Server Interface auslesen
DHCP_CONF="/etc/default/isc-dhcp-server"
DHCP_IF=$(awk -F'=' '/INTERFACESv4/ {gsub(/"/,"",$2); print $2}' "$DHCP_CONF")
[[ -z "$DHCP_IF" ]] && DHCP_IF=""

# Hauptmenü
while true; do
    CHOICE=$(whiptail --title "1to1route Manager" --menu "Select action:" 15 50 5 \
        1 "Add new route" \
        2 "Delete existing route" \
        3 "Show saved routes" \
        4 "Exit" 3>&1 1>&2 2>&3)
    
    case "$CHOICE" in
        1)
            # --- Add new route ---
            IFS=$'\n' read -r -d '' -a INTERFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -v -E "lo|^${DHCP_IF}$" && printf '\0')
            [[ ${#INTERFACES[@]} -eq 0 ]] && { whiptail --msgbox "No suitable interfaces found." 10 60; continue; }

            MENU_ITEMS=()
            for i in "${INTERFACES[@]}"; do MENU_ITEMS+=("$i" ""); done
            SELECT_IF=$(whiptail --title "Select Interface" --menu "Choose interface for the route:" 15 50 6 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3)
            [[ -z "$SELECT_IF" ]] && continue

            DEST_IP=$(whiptail --inputbox "Enter destination IP or subnet (e.g. 10.2.50.0/24):" 10 50 3>&1 1>&2 2>&3)
            [[ -z "$DEST_IP" ]] && continue

            # --- Dynamisches Gateway ermitteln ---
            GW=$(ip route | awk -v iface="$SELECT_IF" '$0 ~ "^default" && $0 ~ iface {print $3; exit}')
            [[ -z "$GW" ]] && whiptail --msgbox "No gateway found for $SELECT_IF, cannot add route." 10 60 && continue

            ip route replace "$DEST_IP" via "$GW" dev "$SELECT_IF"
            grep -qxF "$DEST_IP $SELECT_IF $GW" "$CONFIG_FILE" 2>/dev/null || echo "$DEST_IP $SELECT_IF $GW" >> "$CONFIG_FILE"
            whiptail --msgbox "Route $DEST_IP via $SELECT_IF ($GW) saved and applied!" 10 60
            ;;

        2)
            # --- Delete route ---
            if [[ ! -f "$CONFIG_FILE" || ! -s "$CONFIG_FILE" ]]; then
                whiptail --msgbox "No saved routes to delete." 10 50
                continue
            fi

            ROUTES=()
            INDEX=1
            while read -r line; do
                [[ -z "$line" ]] && continue
                ROUTES+=("$INDEX" "$line")
                INDEX=$((INDEX+1))
            done < "$CONFIG_FILE"

            SELECT_DEL=$(whiptail --title "Delete Route" --menu "Select route to delete:" 20 70 10 "${ROUTES[@]}" 3>&1 1>&2 2>&3)
            [[ -z "$SELECT_DEL" ]] && continue

            DEL_LINE=$(sed -n "${SELECT_DEL}p" "$CONFIG_FILE")
            sed -i "${SELECT_DEL}d" "$CONFIG_FILE"

            DEST_IF_GW=($DEL_LINE)
            ip route del "${DEST_IF_GW[0]}" dev "${DEST_IF_GW[1]}" 2>/dev/null

            whiptail --msgbox "Route '${DEL_LINE}' deleted!" 10 60
            ;;

        3)
            # --- Show routes ---
            [[ ! -f "$CONFIG_FILE" || ! -s "$CONFIG_FILE" ]] && { whiptail --msgbox "No saved routes." 10 50; continue; }
            ROUTES_DISPLAY=$(cat "$CONFIG_FILE")
            whiptail --title "Saved Routes" --msgbox "$ROUTES_DISPLAY" 20 70
            ;;

        4)
            break
            ;;
    esac
done

# --- soloroute.sh erzeugen ---
cat > "$APPLY_SCRIPT" <<'EOF'
#!/bin/bash
CONFIG_FILE="/etc/1002xOPERATOR/dhcp/settings/static-routes.conf"
[[ ! -f "$CONFIG_FILE" ]] && exit 0

while read -r line; do
    [[ -z "$line" ]] && continue
    DEST_IF_GW=($line)
    DEST=${DEST_IF_GW[0]}
    IFACE=${DEST_IF_GW[1]}

    # Dynamisches Gateway
    GW=$(ip route | awk -v iface="$IFACE" '$0 ~ "^default" && $0 ~ iface {print $3; exit}')
    [[ -z "$GW" ]] && continue

    ip route replace "$DEST" via "$GW" dev "$IFACE"
done < "$CONFIG_FILE"
EOF

chmod +x "$APPLY_SCRIPT"

# --- Cronjob einrichten ---
CRON_LINE="* * * * * /bin/bash $APPLY_SCRIPT"
(crontab -l 2>/dev/null | grep -v -F "$APPLY_SCRIPT"; echo "$CRON_LINE") | crontab -

echo "soloroute.sh created at $APPLY_SCRIPT with resilient WLAN support and cronjob installed."
