#!/bin/sh
# Double-click (choose "Run in Terminal"/"Execute") or run:  sh START-Linux.sh
DIR=$(cd "$(dirname "$0")" && pwd)
if [ -t 0 ] || [ $# -gt 0 ]; then
  exec sh "$DIR/proxmox_lxc.sh" "$@"
fi
# Started from a file manager without a terminal: open one.
RUN="sh '$DIR/proxmox_lxc.sh'; printf '\nPress Enter to close...'; read _"
for T in x-terminal-emulator gnome-terminal konsole xfce4-terminal mate-terminal lxterminal xterm; do
  if command -v "$T" >/dev/null 2>&1; then
    case $T in
      gnome-terminal)               exec "$T" -- sh -c "$RUN" ;;
      xfce4-terminal|mate-terminal) exec "$T" -x sh -c "$RUN" ;;
      *)                            exec "$T" -e sh -c "$RUN" ;;
    esac
  fi
done
echo "Please open a terminal and run:  sh \"$DIR/proxmox_lxc.sh\""
