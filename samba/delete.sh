#!/bin/bash

SMB="/etc/samba/smb.conf"
BASE="/etc/1002xOPERATOR/samba"

SHARE="$1"

whiptail --yesno "Delete share $SHARE ?" 10 50
[ $? -ne 0 ] && exit

awk -v share="$SHARE" '
BEGIN{skip=0}
/\[/{
if($0=="["share"]"){skip=1;next}
if(skip==1){skip=0}
}
skip==0{print}
' "$SMB" > /tmp/smb_new

sudo mv /tmp/smb_new "$SMB"

"$BASE/reload.sh"

whiptail --msgbox "Share removed." 8 40
