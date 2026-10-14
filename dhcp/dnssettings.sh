#!/bin/bash
# dnssettings.sh – interactive DHCP DNS manager with confirmation dialogs
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "[ERROR] Must be run as root."; exit 1; }
command -v whiptail &>/dev/null || { echo "[ERROR] whiptail is not installed."; exit 1; }
command -v dhcpd &>/dev/null || { echo "[ERROR] dhcpd is not installed."; exit 1; }

DHCP_CONF="/etc/dhcp/dhcpd.conf"
SETTINGS_DIR="/etc/1002xOPERATOR/dhcp/settings"
BACKUP_CONF="$SETTINGS_DIR/dhcpd.conf.bak"
SERVICE="isc-dhcp-server"

mkdir -p "$SETTINGS_DIR"

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

valid_domain() {
    [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]
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

# Anchored patterns: "option domain-name-servers" is not matched by "option domain-name "
read_current_settings() {
    CURRENT_DNS=$(sed -nE 's/^[[:space:]]*option domain-name-servers ([^;]*);.*/\1/p' "$DHCP_CONF" | head -n1)
    CURRENT_DOMAIN=$(sed -nE 's/^[[:space:]]*option domain-name "([^"]*)";.*/\1/p' "$DHCP_CONF" | head -n1)
}

backup_conf() {
    cp "$DHCP_CONF" "$BACKUP_CONF"
    echo "[INFO] Backup created at $BACKUP_CONF"
}

# Validates the config and restarts the service if it is active.
# On a failed validation the backup is restored, so the service is never started with a broken file.
apply_config() {
    if ! dhcpd -t -cf "$DHCP_CONF" >/dev/null 2>&1; then
        echo "[ERROR] dhcpd configuration test failed. Restoring backup."
        cp "$BACKUP_CONF" "$DHCP_CONF"
        return 1
    fi
    if systemctl is-active --quiet "$SERVICE"; then
        if systemctl restart "$SERVICE"; then
            echo "[INFO] DHCP server restarted"
        else
            echo "[ERROR] DHCP server failed to restart"
            return 1
        fi
    fi
    return 0
}

# write_config SED_EXPRESSION – builds the new file in the same directory, then applies it
write_config() {
    local tmp
    tmp=$(mktemp "$(dirname "$DHCP_CONF")/.dhcpd.conf.XXXXXX") || return 1
    if ! sed -E "$1" "$DHCP_CONF" > "$tmp"; then
        rm -f "$tmp"
        echo "[ERROR] Failed to build the new configuration"
        return 1
    fi
    chmod --reference="$DHCP_CONF" "$tmp"
    mv "$tmp" "$DHCP_CONF"
    apply_config
}

while true; do
    read_current_settings
    CHOICE=$(whiptail --title "DHCP DNS Manager" --menu "Select action:" 20 70 6 \
    1 "Show current DNS settings" \
    2 "Edit DNS servers" \
    3 "Edit DNS domain" \
    4 "Restore last backup" \
    5 "Exit" 3>&1 1>&2 2>&3) || exit 0

    case "$CHOICE" in
    1)
        whiptail --title "Current DHCP DNS Settings" --msgbox "DNS Servers: $CURRENT_DNS\nDNS Domain: $CURRENT_DOMAIN" 12 60
        ;;
    2)
        NEW_DNS=$(ask_value "Enter new DNS servers (comma separated, e.g. 8.8.8.8,8.8.4.4):" "${CURRENT_DNS// /}" valid_dns_list) || continue
        NEW_DNS=${NEW_DNS//,/, }
        if whiptail --title "Confirm DNS change" --yesno "Do you want to set DNS servers to: $NEW_DNS ?" 10 60; then
            backup_conf
            if write_config "s|^([[:space:]]*option domain-name-servers ).*;|\1${NEW_DNS};|"; then
                echo "[INFO] DNS servers updated to $NEW_DNS"
            else
                echo "[ERROR] DNS change failed, previous configuration restored"
            fi
        else
            echo "[CANCELED] DNS change aborted"
        fi
        read -r -p "Press Enter to continue..." _
        ;;
    3)
        NEW_DOMAIN=$(ask_value "Enter new DNS domain:" "$CURRENT_DOMAIN" valid_domain) || continue
        if whiptail --title "Confirm Domain change" --yesno "Do you want to set DNS domain to: $NEW_DOMAIN ?" 10 60; then
            backup_conf
            if write_config "s|^([[:space:]]*option domain-name )\".*\";|\1\"${NEW_DOMAIN}\";|"; then
                echo "[INFO] DNS domain updated to $NEW_DOMAIN"
            else
                echo "[ERROR] Domain change failed, previous configuration restored"
            fi
        else
            echo "[CANCELED] Domain change aborted"
        fi
        read -r -p "Press Enter to continue..." _
        ;;
    4)
        if [[ ! -f $BACKUP_CONF ]]; then
            echo "[WARN] No backup found"
        elif whiptail --title "Confirm Restore" --yesno "Do you want to restore the last backup?" 10 60; then
            cp "$BACKUP_CONF" "$DHCP_CONF"
            if apply_config; then
                echo "[INFO] Backup restored from $BACKUP_CONF"
            fi
        else
            echo "[CANCELED] Restore aborted"
        fi
        read -r -p "Press Enter to continue..." _
        ;;
    5)
        exit 0
        ;;
    esac
done
