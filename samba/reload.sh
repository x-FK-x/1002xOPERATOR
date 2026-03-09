#!/bin/bash

smbcontrol all reload-config 2>/dev/null
systemctl restart smbd 2>/dev/null
