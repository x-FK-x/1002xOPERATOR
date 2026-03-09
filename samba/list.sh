#!/bin/bash

SMB="/etc/samba/smb.conf"

# List all share blocks except standard system blocks
awk '
/^\[/{
    name=$0
    gsub(/\[|\]/,"",name)
    # exclude common system blocks
    if(name!="global" && name!="homes" && name!="printers" && name!="print$")
        print name
}
' "$SMB"
