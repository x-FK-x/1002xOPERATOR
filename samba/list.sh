#!/bin/bash

SMB="/etc/samba/smb.conf"

# List all shares except [global] and standard system shares
awk '
/^\[/{
    name=$0
    gsub(/\[|\]/,"",name)
    if(name!="global" && name!="homes" && name!="printers" && name!="print$")
        print name
}
' "$SMB"
