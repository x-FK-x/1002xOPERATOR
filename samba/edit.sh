#!/bin/bash

SMB="/etc/samba/smb.conf"
BASE="/etc/1002xOPERATOR/samba"

SHARE="$1"

# Only show path (public shares)
PATH_CURRENT=$(awk "/\[$SHARE\]/,/^\[/" "$SMB" | grep "path" | cut -d'=' -f2 | xargs)

NEW_PATH=$(whiptail --inputbox "Edit path for public share $SHARE" 10 60 "$PATH_CURRENT" 3>&1 1>&2 2>&3) || exit

# Replace path line
awk -v share="$SHARE" -v path="$NEW_PATH" '
/\[/{
if($0=="["share"]"){inblock=1}
else{inblock=0}
}
inblock && /path[ ]*=/{
$0="   path = " path
}
{print}
' "$SMB" > /tmp/smb_new

sudo mv /tmp/smb_new "$SMB"

"$BASE/reload.sh"

whiptail --msgbox "Public share updated." 8 40
