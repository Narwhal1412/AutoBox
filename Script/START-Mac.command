#!/bin/sh
# Double-click this file (macOS opens it in Terminal and runs the manager).
cd "$(dirname "$0")" || exit 1
sh ./proxmox_lxc.sh "$@"
if [ $# -eq 0 ]; then printf '\nYou can close this window now.\n'; fi
