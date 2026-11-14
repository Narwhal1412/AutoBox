#!/bin/sh
# Remove only AutoBox containers whose exp-<epoch> tag has expired.
LOG=${AUTOBOX_CLEANUP_LOG:-/var/log/autobox-cleanup.log}
NOW=$(date +%s)

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

pct list 2>/dev/null | while IFS= read -r LINE; do
  case $LINE in VMID*|'') continue ;; esac
  VMID=$(printf '%s\n' "$LINE" | awk '{print $1}')
  case $VMID in ''|*[!0-9]*) continue ;; esac
  CONFIG=$(pct config "$VMID" 2>/dev/null) || continue
  TAGS=$(printf '%s\n' "$CONFIG" | sed -n 's/^tags: *//p')
  HAS_AUTOBOX=0
  EXPIRY=''
  OLD_IFS=$IFS; IFS=';,'
  for TAG in $TAGS; do
    TAG=$(printf '%s' "$TAG" | sed 's/^ *//; s/ *$//')
    [ "$TAG" = autobox ] && HAS_AUTOBOX=1
    case $TAG in exp-*) EXP=${TAG#exp-}; case $EXP in ''|*[!0-9]*) ;; *) EXPIRY=$EXP ;; esac ;; esac
  done
  IFS=$OLD_IFS
  [ "$HAS_AUTOBOX" -eq 1 ] || continue
  [ -n "$EXPIRY" ] && [ "$EXPIRY" -le "$NOW" ] || continue
  STATUS=$(printf '%s\n' "$LINE" | awk '{print $2}')
  if [ "$STATUS" = running ]; then
    if pct stop "$VMID" >> "$LOG" 2>&1; then log "Stopped expired AutoBox container $VMID"; else log "ERROR: failed to stop container $VMID"; continue; fi
  fi
  if pct destroy "$VMID" --purge >> "$LOG" 2>&1; then
    log "Destroyed expired AutoBox container $VMID (exp-$EXPIRY)"
  else
    log "ERROR: failed to destroy container $VMID"
  fi
done

qm list 2>/dev/null | while IFS= read -r LINE; do
  case $LINE in VMID*|'') continue ;; esac
  VMID=$(printf '%s\n' "$LINE" | awk '{print $1}')
  case $VMID in ''|*[!0-9]*) continue ;; esac
  CONFIG=$(qm config "$VMID" 2>/dev/null) || continue
  printf '%s\n' "$CONFIG" | grep -q '^template: 1$' && continue
  TAGS=$(printf '%s\n' "$CONFIG" | sed -n 's/^tags: *//p')
  HAS_AUTOBOX=0
  EXPIRY=''
  OLD_IFS=$IFS; IFS=';,'
  for TAG in $TAGS; do
    TAG=$(printf '%s' "$TAG" | sed 's/^ *//; s/ *$//')
    [ "$TAG" = autobox ] && HAS_AUTOBOX=1
    case $TAG in exp-*) EXP=${TAG#exp-}; case $EXP in ''|*[!0-9]*) ;; *) EXPIRY=$EXP ;; esac ;; esac
  done
  IFS=$OLD_IFS
  [ "$HAS_AUTOBOX" -eq 1 ] || continue
  [ -n "$EXPIRY" ] && [ "$EXPIRY" -le "$NOW" ] || continue
  STATUS=$(printf '%s\n' "$LINE" | awk '{print $3}')
  if [ "$STATUS" = running ]; then
    if qm stop "$VMID" >> "$LOG" 2>&1; then log "Stopped expired AutoBox VM $VMID"; else log "ERROR: failed to stop VM $VMID"; continue; fi
  fi
  if qm destroy "$VMID" --purge --destroy-unreferenced-disks 1 >> "$LOG" 2>&1; then
    log "Destroyed expired AutoBox VM $VMID (exp-$EXPIRY)"
  else
    log "ERROR: failed to destroy VM $VMID"
  fi
done
