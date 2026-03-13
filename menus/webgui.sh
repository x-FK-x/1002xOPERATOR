#!/bin/bash
# /etc/1002xOPERATOR/menus/webgui.sh
# WebGUI service management menu – install, start/stop, uninstall

WEBGUI_DIR="/etc/1002xOPERATOR/webgui"
SERVICE_DIR="/etc/systemd/system"

SERVICES=(
    "1002x-portal"       "Portal         (Port 8080)" "portal.sh"
    "1002x-dhcp-webui"   "DHCP WebUI     (Port 8081)" "dhcp.sh"
    "1002x-samba-webui"  "Samba WebUI    (Port 8082)" "samba.sh"
    "1002x-ufw-webui"    "UFW Dashboard  (Port 8083)" "ufw-webinterface.sh"
)

get_status() {
    systemctl is-active "$1" 2>/dev/null
}

is_installed() {
    systemctl list-unit-files "$1.service" 2>/dev/null | grep -q "$1"
}

status_label() {
    local svc="$1"
    if ! is_installed "$svc"; then
        echo "[----]"
    else
        local s
        s=$(get_status "$svc")
        [[ "$s" == "active" ]] && echo "[ON  ]" || echo "[OFF ]"
    fi
}

get_lan_ip() {
    local lan_if
    lan_if=$(grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server 2>/dev/null | cut -d'"' -f2)
    local ip
    ip=$(ip -4 addr show dev "$lan_if" 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)
    [[ -z "$ip" ]] && ip=$(hostname -I | awk '{print $1}')
    echo "$ip"
}

install_all() {
    mkdir -p "$WEBGUI_DIR"

    local missing=""
    for script in portal.sh dhcp.sh samba.sh ufw-webinterface.sh; do
        [[ ! -f "$WEBGUI_DIR/$script" ]] && missing+="  $script\n"
    done
    if [[ -n "$missing" ]]; then
        whiptail --msgbox "The following scripts are missing in $WEBGUI_DIR:\n${missing}\nPlease copy them first." 12 60
        return 1
    fi

    chmod +x "$WEBGUI_DIR"/*.sh

    # Portal Service
    cat > "$SERVICE_DIR/1002x-portal.service" <<'EOF'
[Unit]
Description=1002xOPERATOR Portal
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash /etc/1002xOPERATOR/webgui/portal.sh 8080
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # DHCP WebUI Service
    cat > "$SERVICE_DIR/1002x-dhcp-webui.service" <<'EOF'
[Unit]
Description=1002xOPERATOR DHCP Web Interface
After=network.target wan-failover.service

[Service]
Type=simple
ExecStart=/bin/bash /etc/1002xOPERATOR/webgui/dhcp.sh 8081
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Samba WebUI Service
    cat > "$SERVICE_DIR/1002x-samba-webui.service" <<'EOF'
[Unit]
Description=1002xOPERATOR Samba Web Interface
After=network.target smbd.service

[Service]
Type=simple
ExecStart=/bin/bash /etc/1002xOPERATOR/webgui/samba.sh 8082
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # UFW Dashboard Service
    cat > "$SERVICE_DIR/1002x-ufw-webui.service" <<'EOF'
[Unit]
Description=1002xOPERATOR UFW Dashboard
After=network.target ufw.service

[Service]
Type=simple
ExecStart=/bin/bash /etc/1002xOPERATOR/webgui/ufw-webinterface.sh 8083
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    for (( i=0; i<${#SERVICES[@]}; i+=3 )); do
        local svc="${SERVICES[$i]}"
        systemctl enable "$svc" 2>/dev/null
        systemctl start  "$svc" 2>/dev/null
    done
    return 0
}

uninstall_all() {
    for (( i=0; i<${#SERVICES[@]}; i+=3 )); do
        local svc="${SERVICES[$i]}"
        systemctl stop    "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
        rm -f "$SERVICE_DIR/$svc.service"
    done
    systemctl daemon-reload
}

install_service() {
    local svc="$1"
    local script="$2"
    local port="$3"
    
    mkdir -p "$WEBGUI_DIR"
    
    if [[ ! -f "$WEBGUI_DIR/$script" ]]; then
        whiptail --msgbox "Script $script not found in $WEBGUI_DIR" 8 50
        return 1
    fi
    
    chmod +x "$WEBGUI_DIR/$script"
    
    # Create service file
    cat > "$SERVICE_DIR/$svc.service" <<EOF
[Unit]
Description=1002xOPERATOR $svc
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash $WEBGUI_DIR/$script $port
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$svc" 2>/dev/null
    systemctl start "$svc" 2>/dev/null
    
    whiptail --msgbox "$svc installed and started on port $port" 8 50
    return 0
}

remove_service() {
    local svc="$1"
    
    whiptail --yesno "Remove service $svc?" 8 50
    [[ $? -ne 0 ]] && return 1
    
    systemctl stop "$svc" 2>/dev/null
    systemctl disable "$svc" 2>/dev/null
    rm -f "$SERVICE_DIR/$svc.service"
    systemctl daemon-reload
    
    whiptail --msgbox "$svc removed" 8 50
    return 0
}

# Main Loop
while true; do
    any_installed=0
    is_installed "1002x-portal" && any_installed=1

    MENU_OPTIONS=()

    if [[ "$any_installed" -eq 0 ]]; then
        MENU_OPTIONS+=("install_all" "⬇  Install & start all WebGUI services")
        MENU_OPTIONS+=("install_sel" "⬇  Install specific service")
    else
        MENU_OPTIONS+=("all_on"    "▶  Start all services")
        MENU_OPTIONS+=("all_off"   "■  Stop all services")
        MENU_OPTIONS+=("install_sel" "⬇  Install additional service")
        MENU_OPTIONS+=("uninstall_all" "✕  Uninstall all WebGUI services")
        MENU_OPTIONS+=("separator" "────────────────────────")
        
        for (( i=0; i<${#SERVICES[@]}; i+=3 )); do
            SVC="${SERVICES[$i]}"
            DESC="${SERVICES[$i+1]}"
            LABEL=$(status_label "$SVC")
            MENU_OPTIONS+=("$SVC" "$LABEL  $DESC")
        done
    fi

    MENU_OPTIONS+=("exit" "Leave menu")

    CHOICE=$(whiptail --title "1002xOPERATOR WebGUI Manager" \
        --menu "Select service:" 25 70 16 \
        "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)

    [[ $? -ne 0 || "$CHOICE" == "exit" ]] && exit 0

    case "$CHOICE" in
        install_all)
            if install_all; then
                IP=$(get_lan_ip)
                whiptail --msgbox "✓ WebGUI services installed and started!\n\nPortal:  http://$IP:8080\nDHCP:    http://$IP:8081\nSamba:   http://$IP:8082\nUFW:     http://$IP:8083" 14 58
            fi
            ;;
        install_sel)
            SERVICES_MENU=()
            for (( i=0; i<${#SERVICES[@]}; i+=3 )); do
                SVC="${SERVICES[$i]}"
                if ! is_installed "$SVC"; then
                    DESC="${SERVICES[$i+1]}"
                    SERVICES_MENU+=("$SVC" "$DESC")
                fi
            done
            
            if [[ ${#SERVICES_MENU[@]} -eq 0 ]]; then
                whiptail --msgbox "All services already installed." 8 50
                continue
            fi
            
            SVC_CHOICE=$(whiptail --title "Select Service" \
                --menu "Choose service to install:" 15 60 6 \
                "${SERVICES_MENU[@]}" 3>&1 1>&2 2>&3)
            
            [[ -z "$SVC_CHOICE" ]] && continue
            
            for (( i=0; i<${#SERVICES[@]}; i+=3 )); do
                if [[ "${SERVICES[$i]}" == "$SVC_CHOICE" ]]; then
                    SCRIPT="${SERVICES[$i+2]}"
                    PORT=$((8080 + i/3))
                    install_service "$SVC_CHOICE" "$SCRIPT" "$PORT"
                    break
                fi
            done
            ;;
        uninstall_all)
            whiptail --yesno "Really uninstall all WebGUI services?\nAll services will be stopped and removed." 10 60
            if [[ $? -eq 0 ]]; then
                uninstall_all
                whiptail --msgbox "✓ All WebGUI services removed." 8 50
            fi
            ;;
        all_on)
            for (( i=0; i<${#SERVICES[@]}; i+=3 )); do
                systemctl start "${SERVICES[$i]}" 2>/dev/null
            done
            whiptail --msgbox "✓ All WebGUI services started." 8 50
            ;;
        all_off)
            for (( i=0; i<${#SERVICES[@]}; i+=3 )); do
                systemctl stop "${SERVICES[$i]}" 2>/dev/null
            done
            whiptail --msgbox "✓ All WebGUI services stopped." 8 50
            ;;
        separator)
            continue
            ;;
        *)
            STATUS=$(get_status "$CHOICE")
            if [[ "$STATUS" == "active" ]]; then
                systemctl stop "$CHOICE" 2>/dev/null
                whiptail --msgbox "✓ $CHOICE stopped." 8 50
            else
                systemctl start "$CHOICE" 2>/dev/null
                whiptail --msgbox "✓ $CHOICE started." 8 50
            fi
            ;;
    esac
done
