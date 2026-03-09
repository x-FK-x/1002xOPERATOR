#!/bin/bash

SMB="/etc/samba/smb.conf"
BASE="/etc/1002xOPERATOR/samba"

NAME=$(whiptail --inputbox "Share name" 10 60 3>&1 1>&2 2>&3) || exit

PATHX=$(whiptail --inputbox "Share path" 10 60 "/srv/samba/$NAME" 3>&1 1>&2 2>&3) || exit

mkdir -p "$PATHX"

CONFIG="

[$NAME]
   path = $PATHX
   browseable = yes
   read only = no
   guest ok = yes
"

echo "$CONFIG" | sudo tee -a "$SMB" >/dev/null

"$BASE/reload.sh"

whiptail --msgbox "Public share created." 8 40
