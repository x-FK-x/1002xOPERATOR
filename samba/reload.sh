#!/bin/bash

# Reload Samba configuration and restart service
smbcontrol all reload-config 2>/dev/null
sudo systemctl restart smbd
