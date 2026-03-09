#!/bin/bash

BASE="/etc/1002xOPERATOR"
SAMBA="$BASE/samba"

# Get shares with their paths
SHARES=()
while read -r SHARE; do
    PATHX=$(awk "/\[$SHARE\]/,/^\[/" /etc/samba/smb.conf | grep "path" | cut -d'=' -f2 | xargs)
    SHARES+=("$SHARE" "$PATHX")
done < <("$SAMBA/list.sh")

# Add menu options
SHARES+=("NEW" "Create new public share")
SHARES+=("EXIT" "Back")

CHOICE=$(whiptail \
--title "1002xOPERATOR - Samba Manager" \
--menu "Select Samba share" \
25 80 15 \
"${SHARES[@]}" \
3>&1 1>&2 2>&3)

[ $? -ne 0 ] && exit

case "$CHOICE" in

NEW)
"$SAMBA/add.sh"
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
EDIT) "$SAMBA/edit.sh" "$CHOICE" ;;
DELETE) "$SAMBA/delete.sh" "$CHOICE" ;;
esac
;;

esac
