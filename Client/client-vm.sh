#!/bin/sh
# AutoBox temporary QEMU/KVM VM client. Requires only POSIX sh and curl.

set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
SETTINGS=${AUTOBOX_SETTINGS:-$DIR/settings.txt}
MESSAGE=$DIR/message-vm.txt
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trim_cr() { CR=$(printf '\r'); LINE=${LINE%"$CR"}; }

[ -r "$SETTINGS" ] || fail "Cannot read settings file: $SETTINGS"
[ -r "$MESSAGE" ] || fail "Cannot read message file: $MESSAGE"
PVE_HOST=''; PVE_USER=root@pam; PVE_TOKEN_NAME=''; PVE_TOKEN_SECRET=''; PVE_NODE=''
LIFETIME_DAYS=2; VERIFY_SSL=0
VM_TEMPLATE_ID=''; VM_NAME_PREFIX=vm; VM_CORES=2; VM_MEMORY=2048; VM_DISK_GB=''
VM_STORAGE=''; VM_USER=root; VM_PASSWORD=docker; VM_IP_MODE=dhcp; VM_BRIDGE=''
VM_GUEST_OS=linux; VM_CLONE_MODE=full; VM_CLONE_TIMEOUT=1800
while IFS= read -r LINE || [ -n "$LINE" ]; do
  trim_cr
  case $LINE in ''|\#*) continue ;; esac
  case $LINE in *=*) KEY=${LINE%%=*}; VALUE=${LINE#*=} ;; *) continue ;; esac
  case $KEY in
    PVE_HOST) PVE_HOST=$VALUE ;; PVE_USER) PVE_USER=$VALUE ;;
    PVE_TOKEN_NAME) PVE_TOKEN_NAME=$VALUE ;; PVE_TOKEN_SECRET) PVE_TOKEN_SECRET=$VALUE ;;
    PVE_NODE) PVE_NODE=$VALUE ;; LIFETIME_DAYS) LIFETIME_DAYS=$VALUE ;;
    VERIFY_SSL) VERIFY_SSL=$VALUE ;; VM_TEMPLATE_ID) VM_TEMPLATE_ID=$VALUE ;;
    VM_NAME_PREFIX) VM_NAME_PREFIX=$VALUE ;; VM_CORES) VM_CORES=$VALUE ;;
    VM_MEMORY) VM_MEMORY=$VALUE ;; VM_DISK_GB) VM_DISK_GB=$VALUE ;;
    VM_STORAGE) VM_STORAGE=$VALUE ;; VM_USER) VM_USER=$VALUE ;;
    VM_PASSWORD) VM_PASSWORD=$VALUE ;; VM_IP_MODE) VM_IP_MODE=$VALUE ;;
    VM_BRIDGE) VM_BRIDGE=$VALUE ;; VM_GUEST_OS) VM_GUEST_OS=$VALUE ;;
    VM_CLONE_MODE) VM_CLONE_MODE=$VALUE ;; VM_CLONE_TIMEOUT) VM_CLONE_TIMEOUT=$VALUE ;;
  esac
done < "$SETTINGS"

printf '%s\n' "$(cat "$MESSAGE")"
printf 'Create it now? (y/n): '
IFS= read -r ANSWER || ANSWER=''
LINE=$ANSWER; trim_cr; ANSWER=$LINE
case $ANSWER in y|Y|yes) ;; *) printf 'Cancelled. Nothing was created.\n'; exit 0 ;; esac

MISSING=''
[ -n "$PVE_HOST" ] || MISSING="$MISSING PVE_HOST"
[ -n "$PVE_TOKEN_NAME" ] || MISSING="$MISSING PVE_TOKEN_NAME"
[ -n "$PVE_TOKEN_SECRET" ] || MISSING="$MISSING PVE_TOKEN_SECRET"
[ -n "$VM_TEMPLATE_ID" ] || MISSING="$MISSING VM_TEMPLATE_ID"
[ -z "$MISSING" ] || fail "Settings are not finished. Fill in:$MISSING"
case $VM_TEMPLATE_ID in *[!0-9]*) fail 'VM_TEMPLATE_ID must be a number.' ;; esac
[ "${#VM_PASSWORD}" -ge 5 ] || fail 'VM_PASSWORD must be at least 5 characters.'
VM_GUEST_OS=$(printf '%s' "$VM_GUEST_OS" | tr '[:upper:]' '[:lower:]')
case $VM_GUEST_OS in linux|windows) ;; *) fail 'VM_GUEST_OS must be linux or windows.' ;; esac
VM_CLONE_MODE=$(printf '%s' "$VM_CLONE_MODE" | tr '[:upper:]' '[:lower:]')
case $VM_CLONE_MODE in full|linked) ;; *) fail 'VM_CLONE_MODE must be full or linked.' ;; esac
case $VM_CLONE_TIMEOUT in ''|*[!0-9]*) fail 'VM_CLONE_TIMEOUT must be a whole number of at least 1.' ;; esac
[ "$VM_CLONE_TIMEOUT" -ge 1 ] || fail 'VM_CLONE_TIMEOUT must be a whole number of at least 1.'
case $LIFETIME_DAYS in ''|*[!0-9]*) fail 'LIFETIME_DAYS must be a whole number of at least 1.' ;; esac
[ "$LIFETIME_DAYS" -ge 1 ] || fail 'LIFETIME_DAYS must be a whole number of at least 1.'
if [ -n "$VM_DISK_GB" ]; then
  case $VM_DISK_GB in *[!0-9]*) fail 'VM_DISK_GB must be a whole number of at least 1.' ;; esac
  [ "$VM_DISK_GB" -ge 1 ] || fail 'VM_DISK_GB must be a whole number of at least 1.'
fi
case $VERIFY_SSL in 1|true|yes|TRUE|YES) VERIFY=1 ;; *) VERIFY=0 ;; esac
command -v curl >/dev/null 2>&1 || fail 'curl was not found on this computer.'
HOST=${PVE_HOST#https://}; HOST=${HOST#http://}; HOST=${HOST%/}
case $HOST in *:[0-9]*) ;; *) HOST="$HOST:8006" ;; esac
BASE="https://$HOST/api2/json"
API_DATA=''; API_BODY=''; API_CODE=''

# api METHOD PATH [key=value ...]; results are in API_DATA/API_BODY/API_CODE.
api() {
  A_METHOD=$1; A_PATH=$2; shift 2
  A_N=$#; A_I=0
  while [ "$A_I" -lt "$A_N" ]; do set -- "$@" --data-urlencode "$1"; shift; A_I=$((A_I + 1)); done
  case $A_METHOD in GET|DELETE) set -- -G "$@" ;; esac
  [ "$VERIFY" -eq 1 ] || set -- -k "$@"
  A_OUT=$(curl -sS --connect-timeout 15 -X "$A_METHOD" \
    -H "Authorization: PVEAPIToken=$PVE_USER!$PVE_TOKEN_NAME=$PVE_TOKEN_SECRET" \
    -w '\n%{http_code}' "$@" "$BASE$A_PATH") || {
      API_CODE=000; API_BODY='Cannot reach the Proxmox server.'; API_DATA=''; return 1;
    }
  API_CODE=$(printf '%s\n' "$A_OUT" | tail -n 1)
  API_BODY=$(printf '%s\n' "$A_OUT" | sed '$d')
  API_DATA=$API_BODY
  case $API_CODE in 2??) return 0 ;; *) return 1 ;; esac
}
jget() { printf '%s\n' "$1" | sed -n 's/.*"'"$2"'":"\{0,1\}\([^",}]*\).*/\1/p'; }
json_lines() { printf '%s\n' "$1" | sed 's/^{"data":\[//; s/\]}$//; s/},{/}\
{/g'; }
api_error() {
  A_HINT=''
  [ "$API_CODE" = 401 ] && A_HINT=' Check PVE_USER, PVE_TOKEN_NAME, and PVE_TOKEN_SECRET.'
  [ "$API_CODE" = 403 ] && A_HINT=' The token needs permission for this action.'
  printf 'ERROR: HTTP %s: %s.%s\n' "$API_CODE" "$API_BODY" "$A_HINT" >&2
}

if ! api GET /nodes; then
  if [ "$API_CODE" = 401 ] || [ "$API_CODE" = 403 ]; then
    fail 'The Proxmox token was rejected or lacks permission. Check PVE_USER, PVE_TOKEN_NAME, PVE_TOKEN_SECRET, and token permissions.'
  fi
  api_error; exit 1
fi
NODES=$(jget "$API_DATA" node)
if [ -z "$PVE_NODE" ]; then PVE_NODE=$(printf '%s\n' "$NODES" | sed -n '1p'); fi
[ -n "$PVE_NODE" ] || fail 'No Proxmox node was found.'
if ! api GET "/nodes/$PVE_NODE/qemu/$VM_TEMPLATE_ID/config"; then
  fail "Could not read VM_TEMPLATE_ID $VM_TEMPLATE_ID. Check that the template exists and the token can read it."
fi
[ "$(jget "$API_DATA" template)" = 1 ] || fail "VM_TEMPLATE_ID $VM_TEMPLATE_ID is not a Proxmox VM template. Choose a VM marked as a template."
if ! api GET "/nodes/$PVE_NODE/status"; then api_error; exit 1; fi
SERVER_TIME=$(jget "$API_DATA" time)
case $SERVER_TIME in ''|*[!0-9]*) fail 'The Proxmox server returned an invalid time.' ;; esac
EXPIRY=$((SERVER_TIME + LIFETIME_DAYS * 86400))
PREFIX=$(printf '%s' "$VM_NAME_PREFIX" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
[ -n "$PREFIX" ] || PREFIX=vm
CREATOR="${USER:-user}@$(hostname 2>/dev/null || printf computer)"
format_epoch() {
  date -u -d "@$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || date -u -r "$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || printf '%s' "$1"
}
DESCRIPTION="AutoBox temporary VM. Created by $CREATOR on $(format_epoch "$SERVER_TIME"). Auto-deleted after $(format_epoch "$EXPIRY")."
TAGS="autobox;exp-$EXPIRY"
if ! api GET /cluster/nextid; then api_error; exit 1; fi
VMID=$(printf '%s' "$API_DATA" | sed -n 's/.*"data":"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p')
case $VMID in ''|*[!0-9]*) fail 'Proxmox returned an invalid VM ID.' ;; esac
ATTEMPT=0; CLONED=0
while [ "$ATTEMPT" -le 6 ]; do
  VM_NAME="$PREFIX-$VMID"
  CLONE_FULL=1; [ "$VM_CLONE_MODE" = linked ] && CLONE_FULL=0
  set -- "newid=$VMID" "name=$VM_NAME" "full=$CLONE_FULL"
  [ -z "$VM_STORAGE" ] || set -- "$@" "storage=$VM_STORAGE"
  if api POST "/nodes/$PVE_NODE/qemu/$VM_TEMPLATE_ID/clone" "$@"; then
    CLONE_UPID=$(printf '%s' "$API_DATA" | sed -n 's/.*"data":"\(UPID:[^"]*\)".*/\1/p')
    CLONED=1; break
  fi
  case $API_BODY in
    *'already exists'*|*'already in use'*)
      if [ "$ATTEMPT" -ge 6 ]; then break; fi
      OFFSET=$(awk -v seed="$(date +%s)$$$ATTEMPT" 'BEGIN { srand(seed); print int(rand() * 30) }')
      PROBE=$((VMID + (OFFSET + ATTEMPT) % 30)); [ "$PROBE" -ne "$VMID" ] || PROBE=$((PROBE + 1))
      if api GET /cluster/nextid "vmid=$PROBE"; then
        VMID=$(printf '%s' "$API_DATA" | sed -n 's/.*"data":"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p')
        [ -n "$VMID" ] || VMID=$PROBE
      else api_error; exit 1; fi
      ATTEMPT=$((ATTEMPT + 1)) ;;
    *) api_error; printf 'Send the text above to the owner.\n' >&2; exit 1 ;;
  esac
done
[ "$CLONED" -eq 1 ] || { api_error; fail 'Could not reserve a free VM ID after 6 retries.'; }
wait_task() {
  W_UPID=$(printf '%s' "$1" | sed 's/:/%3A/g; s/@/%40/g; s/!/%21/g')
  W_LABEL=${2:-}
  W_ELAPSED=0
  case $W_LABEL in
    clone) printf 'Cloning a large disk can take several minutes...' ;;
    start) printf 'Starting VM...' ;;
  esac
  while [ "$W_ELAPSED" -lt "$VM_CLONE_TIMEOUT" ]; do
    if ! api GET "/nodes/$PVE_NODE/tasks/$W_UPID/status"; then api_error; return 1; fi
    case $API_DATA in
      *'"status":"stopped"'*)
        case $API_DATA in *'"exitstatus":"OK"'*) [ -z "$W_LABEL" ] || printf '\n'; return 0 ;; esac
        printf 'ERROR: Proxmox task failed: %s\n' "$(jget "$API_DATA" exitstatus)" >&2
        if api GET "/nodes/$PVE_NODE/tasks/$W_UPID/log" limit=50; then
          printf '%s\n' "$API_DATA" | grep -o '"t":"[^"]*"' | sed 's/^"t":"/    /; s/"$//' >&2
        fi
        return 1 ;;
    esac
    sleep 2; W_ELAPSED=$((W_ELAPSED + 2))
    case $W_LABEL in clone|start) [ $((W_ELAPSED % 4)) -eq 0 ] && printf '.' ;; esac
  done
  [ -z "$W_LABEL" ] || printf '\n'
  printf 'ERROR: timed out waiting for Proxmox task after %ss.\n' "$VM_CLONE_TIMEOUT" >&2
  return 1
}
if [ -n "$CLONE_UPID" ]; then wait_task "$CLONE_UPID" clone || fail 'Clone task did not finish successfully. Send the task output above to the owner.'; fi

if ! api GET "/nodes/$PVE_NODE/qemu/$VMID/config"; then api_error; exit 1; fi
CURRENT_CONFIG=$API_DATA
set -- "cores=$VM_CORES" "memory=$VM_MEMORY" 'agent=1' "tags=$TAGS" "description=$DESCRIPTION"
if [ "$VM_GUEST_OS" = linux ]; then
  set -- "$@" "ciuser=$VM_USER" "cipassword=$VM_PASSWORD" "ipconfig0=ip=$VM_IP_MODE"
fi
[ -z "$VM_BRIDGE" ] || set -- "$@" "net0=virtio,bridge=$VM_BRIDGE"
if ! api PUT "/nodes/$PVE_NODE/qemu/$VMID/config" "$@"; then api_error; printf 'Send the text above to the owner.\n' >&2; exit 1; fi
CONFIG_UPID=$(printf '%s' "$API_DATA" | sed -n 's/.*"data":"\(UPID:[^"]*\)".*/\1/p')
[ -z "$CONFIG_UPID" ] || wait_task "$CONFIG_UPID" || fail 'VM configuration task failed.'

if [ -n "$VM_DISK_GB" ]; then
  CURRENT_SIZE=$(printf '%s' "$CURRENT_CONFIG" | sed -n 's/.*"scsi0":"[^"]*size=\([0-9][0-9]*\)G[^\"]*".*/\1/p')
  if [ -z "$CURRENT_SIZE" ]; then
    printf 'NOTE: could not read current scsi0 size; disk resize skipped.\n'
  elif [ "$VM_DISK_GB" -gt "$CURRENT_SIZE" ]; then
    if ! api PUT "/nodes/$PVE_NODE/qemu/$VMID/resize" disk=scsi0 "size=${VM_DISK_GB}G"; then api_error; exit 1; fi
    RESIZE_UPID=$(printf '%s' "$API_DATA" | sed -n 's/.*"data":"\(UPID:[^"]*\)".*/\1/p')
    [ -z "$RESIZE_UPID" ] || wait_task "$RESIZE_UPID" || fail 'VM disk resize task failed.'
  elif [ "$VM_DISK_GB" -lt "$CURRENT_SIZE" ]; then
    printf 'WARNING: VM_DISK_GB is smaller than the template disk; disk resize skipped.\n'
  else
    printf 'NOTE: requested disk size matches the template disk; resize skipped.\n'
  fi
fi
if ! api POST "/nodes/$PVE_NODE/qemu/$VMID/status/start"; then api_error; exit 1; fi
START_UPID=$(printf '%s' "$API_DATA" | sed -n 's/.*"data":"\(UPID:[^"]*\)".*/\1/p')
[ -z "$START_UPID" ] || wait_task "$START_UPID" start || fail 'VM start task failed.'

IP=''; ELAPSED=0; IP_TIMEOUT=120
[ "$VM_GUEST_OS" = windows ] && IP_TIMEOUT=300
while [ "$ELAPSED" -lt "$IP_TIMEOUT" ]; do
  if api GET "/nodes/$PVE_NODE/qemu/$VMID/agent/network-get-interfaces"; then
    IP=$(printf '%s\n' "$API_DATA" | grep -o '"ip-address":"[0-9.]*"' | sed 's/^"ip-address":"//; s/"$//' | while IFS= read -r ADDRESS; do
      case $ADDRESS in 127.*|'') continue ;; esac
      printf '%s\n' "$ADDRESS"; break
    done)
    [ -n "$IP" ] && break
  fi
  sleep 5; ELAPSED=$((ELAPSED + 5))
done
printf '%s\n' '+----------------------------------------------------------+'
printf '| VM:        %-48s |\n' "$VM_NAME (ID $VMID)"
if [ -n "$IP" ]; then printf '| IP:        %-48s |\n' "$IP"; else printf '| IP:        %-48s |\n' 'still starting - the first boot can take a few minutes, ask the owner'; fi
printf '| User:      %-48s |\n' "$VM_USER"
printf '| Password:  %-48s |\n' "$VM_PASSWORD"
printf '| Delete:    %-48s |\n' "$(format_epoch "$EXPIRY")"
printf '%s\n' '+----------------------------------------------------------+'
[ "$VM_GUEST_OS" != windows ] || printf 'Windows credentials must already exist inside the template.\n'
[ -n "$IP" ] || [ "$VM_GUEST_OS" != windows ] || printf 'No IP appeared; install qemu-guest-agent from the virtio-win ISO in the template.\n'
