#!/bin/bash

BASE="/etc/1002xOPERATOR"
SAMBA="$BASE/samba"

# === Check required packages (only samba) ===
if ! dpkg -s samba &>/dev/null; then
    whiptail --title "Missing Package" --yesno \
    "The package 'samba' is not installed.\n\nInstall it now?" 15 60
    if [ $? -eq 0 ]; then
        sudo apt update && sudo apt install -y samba
    else
        whiptail --msgbox "Cannot proceed without Samba installed." 10 50
        exit 1
    fi
fi

# === Get shares with paths ===
SHARES=()
while read -r SHARE; do
    PATHX=$(awk "/\[$SHARE\]/,/^\[/" /etc/samba/smb.conf | grep "path" | cut -d'=' -f2 | xargs)
    SHARES+=("$SHARE" "$PATHX")
done < <("$SAMBA/list.sh")

# === Add menu options ===
SHARES+=("NEW" "Create new public share")
SHARES+=("RELOAD" "Reload Samba configuration and restart smbd")
SHARES+=("EXIT" "Back")

# === Show Whiptail menu ===
CHOICE=$(whiptail \
--title "1002xOPERATOR - Samba Manager" \
--menu "Select a share or action:" \
25 80 15 \
"${SHARES[@]}" \
3>&1 1>&2 2>&3)

[ $? -ne 0 ] && exit

case "$CHOICE" in

NEW)
    "$SAMBA/add.sh"
    "$SAMBA/reload.sh"
    ;;

RELOAD)
    "$SAMBA/reload.sh"
    whiptail --msgbox "Samba configuration reloaded and smbd restarted." 8 50
    ;;

EXIT)
    exit
    ;;

*)
    ACTION=$(whiptail \
    --title "$CHOICE" \
    --menu "Action" \
    15 60 5 \
    EDIT "Edit path" \
    DELETE "Delete share" \
    BACK "Back" \
    3>&1 1>&2 2>&3)

    case "$ACTION" in
        EDIT) "$SAMBA/edit.sh" "$CHOICE"; "$SAMBA/reload.sh" ;;
        DELETE) "$SAMBA/delete.sh" "$CHOICE"; "$SAMBA/reload.sh" ;;
    esac
    ;;
esac
