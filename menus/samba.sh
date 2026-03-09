#!/bin/bash

BASE="/etc/1002xOPERATOR"
SAMBA="$BASE/samba"

# === Check required packages ===
REQUIRED_PACKAGES=("samba" "smbclient")
MISSING=()

for PKG in "${REQUIRED_PACKAGES[@]}"; do
    dpkg -s "$PKG" &>/dev/null || MISSING+=("$PKG")
done

if [ ${#MISSING[@]} -ne 0 ]; then
    whiptail --title "Missing Packages" --yesno \
    "The following packages are missing:\n\n${MISSING[*]}\n\nInstall them now?" 15 60
    if [ $? -eq 0 ]; then
        sudo apt update && sudo apt install -y "${MISSING[@]}"
    else
        whiptail --msgbox "Cannot proceed without required Samba packages." 10 50
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
--menu "Select Samba share or action:" \
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
    # Choose action: Edit path or Delete share
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
