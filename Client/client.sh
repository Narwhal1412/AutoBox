#!/bin/sh
# AutoBox temporary LXC client. Requires only POSIX sh and curl.

set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
SETTINGS=${AUTOBOX_SETTINGS:-$DIR/settings.txt}
MESSAGE=$DIR/message.txt

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trim_cr() { CR=$(printf '\r'); LINE=${LINE%"$CR"}; }

[ -r "$SETTINGS" ] || fail "Cannot read settings file: $SETTINGS"
[ -r "$MESSAGE" ] || fail "Cannot read message file: $MESSAGE"

PVE_HOST=''; PVE_USER='root@pam'; PVE_TOKEN_NAME=''; PVE_TOKEN_SECRET=''
PVE_NODE=''; TEMPLATE=''; CORES=1; MEMORY=512; DISK=8; STORAGE=''
IP_MODE=dhcp; BRIDGE=vmbr0; ROOT_PASSWORD=docker; NAME_PREFIX=client
FEATURES=''; LIFETIME_DAYS=2; VERIFY_SSL=0
while IFS= read -r LINE || [ -n "$LINE" ]; do
  trim_cr
  case $LINE in ''|\#*) continue ;; esac
  case $LINE in *=*) KEY=${LINE%%=*}; VALUE=${LINE#*=} ;; *) continue ;; esac
  case $KEY in
    PVE_HOST) PVE_HOST=$VALUE ;; PVE_USER) PVE_USER=$VALUE ;;
    PVE_TOKEN_NAME) PVE_TOKEN_NAME=$VALUE ;; PVE_TOKEN_SECRET) PVE_TOKEN_SECRET=$VALUE ;;
    PVE_NODE) PVE_NODE=$VALUE ;; TEMPLATE) TEMPLATE=$VALUE ;;
    CORES) CORES=$VALUE ;; MEMORY) MEMORY=$VALUE ;; DISK) DISK=$VALUE ;;
    STORAGE) STORAGE=$VALUE ;; IP_MODE) IP_MODE=$VALUE ;; BRIDGE) BRIDGE=$VALUE ;;
    ROOT_PASSWORD) ROOT_PASSWORD=$VALUE ;; NAME_PREFIX) NAME_PREFIX=$VALUE ;;
    FEATURES) FEATURES=$VALUE ;; LIFETIME_DAYS) LIFETIME_DAYS=$VALUE ;;
    VERIFY_SSL) VERIFY_SSL=$VALUE ;;
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
[ -z "$MISSING" ] || fail "Settings are not finished. Fill in:$MISSING"
[ "${#ROOT_PASSWORD}" -ge 5 ] || fail 'ROOT_PASSWORD must be at least 5 characters.'
case $LIFETIME_DAYS in ''|*[!0-9]*) fail 'LIFETIME_DAYS must be a whole number of at least 1.' ;; esac
[ "$LIFETIME_DAYS" -ge 1 ] || fail 'LIFETIME_DAYS must be a whole number of at least 1.'
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
  [ "$API_CODE" = 401 ] && A_HINT=' Check the token user, name, and secret.'
  [ "$API_CODE" = 403 ] && A_HINT=' The token needs permission for this action.'
  printf 'ERROR: HTTP %s: %s.%s\n' "$API_CODE" "$API_BODY" "$A_HINT" >&2
}

if ! api GET /nodes; then
  if [ "$API_CODE" = 401 ] || [ "$API_CODE" = 403 ]; then
    printf 'The Proxmox token was rejected or does not have permission. Check PVE_USER, PVE_TOKEN_NAME, PVE_TOKEN_SECRET and token permissions.\n' >&2
  else api_error; fi
  exit 1
fi
NODES=$(jget "$API_DATA" node)
if [ -z "$PVE_NODE" ]; then PVE_NODE=$(printf '%s\n' "$NODES" | sed -n '1p'); fi
[ -n "$PVE_NODE" ] || fail 'No Proxmox node was found.'

if ! api GET "/nodes/$PVE_NODE/status"; then api_error; exit 1; fi
SERVER_TIME=$(jget "$API_DATA" time)
case $SERVER_TIME in ''|*[!0-9]*) fail 'The Proxmox server returned an invalid time.' ;; esac
EXPIRY=$((SERVER_TIME + LIFETIME_DAYS * 86400))

if [ -z "$TEMPLATE" ]; then
  if ! api GET "/nodes/$PVE_NODE/storage" content=vztmpl; then api_error; exit 1; fi
  STORES=$(printf '%s\n' "$API_DATA" | sed 's/},{/} /g' | tr ' ' '\n' | sed -n 's/.*"storage":"\([^"]*\)".*/\1/p')
  for STORE in $STORES; do
    if api GET "/nodes/$PVE_NODE/storage/$STORE/content" content=vztmpl; then
      TEMPLATE=$(jget "$API_DATA" volid)
      [ -z "$TEMPLATE" ] || break
    fi
  done
  [ -n "$TEMPLATE" ] || fail 'No container template was found on the server.'
fi
if [ -z "$STORAGE" ]; then
  if ! api GET "/nodes/$PVE_NODE/storage" content=rootdir; then api_error; exit 1; fi
  STORES=$(printf '%s\n' "$API_DATA" | sed 's/},{/} /g' | tr ' ' '\n' | sed -n 's/.*"storage":"\([^"]*\)".*/\1/p')
  STORAGE=''
  for STORE in $STORES; do [ "$STORE" = local-lvm ] && STORAGE=$STORE && break; done
  [ -n "$STORAGE" ] || STORAGE=$(printf '%s\n' "$STORES" | sed -n '1p')
  [ -n "$STORAGE" ] || fail 'No storage that supports container disks was found.'
fi

if ! api GET /cluster/nextid; then api_error; exit 1; fi
VMID=$(printf '%s' "$API_DATA" | sed -n 's/.*"data":"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p')
case $VMID in ''|*[!0-9]*) fail 'Proxmox returned an invalid container ID.' ;; esac
PREFIX=$(printf '%s' "$NAME_PREFIX" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
[ -n "$PREFIX" ] || PREFIX=client
CREATOR="${USER:-user}@$(hostname 2>/dev/null || printf computer)"
format_epoch() {
  date -u -d "@$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || date -u -r "$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || printf '%s' "$1"
}
DESCRIPTION="AutoBox temporary container. Created by $CREATOR on $(format_epoch "$SERVER_TIME").
Auto-deleted after $(format_epoch "$EXPIRY")."
TAGS="autobox;exp-$EXPIRY"

CREATED=0
ATTEMPT=0
while [ "$ATTEMPT" -le 6 ]; do
  CREATED_NAME="$PREFIX-$VMID"
  set -- "vmid=$VMID" "hostname=$CREATED_NAME" "ostemplate=$TEMPLATE" "cores=$CORES" \
    "memory=$MEMORY" 'swap=512' "rootfs=$STORAGE:$DISK" \
    "net0=name=eth0,bridge=$BRIDGE,ip=$IP_MODE" 'unprivileged=1' \
    "password=$ROOT_PASSWORD" 'start=1' "tags=$TAGS" "description=$DESCRIPTION"
  [ -z "$FEATURES" ] || set -- "$@" "features=$FEATURES"
  if api POST "/nodes/$PVE_NODE/lxc" "$@"; then
    UPID=$(printf '%s' "$API_DATA" | sed -n 's/.*"data":"\(UPID:[^"]*\)".*/\1/p')
    CREATED=1
    break
  fi
  case $API_BODY in
    *'already exists'*|*'already in use'*)
      if [ "$ATTEMPT" -ge 6 ]; then break; fi
      OFFSET=$(awk -v seed="$(date +%s)$$$ATTEMPT" 'BEGIN { srand(seed); print int(rand() * 30) }')
      PROBE=$((VMID + (OFFSET + ATTEMPT) % 30))
      [ "$PROBE" -ne "$VMID" ] || PROBE=$((PROBE + 1))
      if api GET /cluster/nextid "vmid=$PROBE"; then
        NEXT=$(printf '%s' "$API_DATA" | sed -n 's/.*"data":"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p')
        [ -n "$NEXT" ] && VMID=$NEXT || VMID=$PROBE
      else api_error; exit 1; fi
      ATTEMPT=$((ATTEMPT + 1)) ;;
    *) api_error; printf 'Send the text above to the owner.\n' >&2; exit 1 ;;
  esac
done
[ "$CREATED" -eq 1 ] || { api_error; printf 'Could not reserve a free container ID after 6 retries.\n' >&2; exit 1; }

if [ -n "$UPID" ]; then
  UPID_ENC=$(printf '%s' "$UPID" | sed 's/:/%3A/g; s/@/%40/g; s/!/%21/g')
  ELAPSED=0
  while [ "$ELAPSED" -lt 300 ]; do
    if ! api GET "/nodes/$PVE_NODE/tasks/$UPID_ENC/status"; then api_error; exit 1; fi
    case $API_DATA in
      *'"status":"stopped"'*)
        case $API_DATA in *'"exitstatus":"OK"'*) break ;; esac
        printf 'ERROR: creation task failed: %s\n' "$(jget "$API_DATA" exitstatus)" >&2
        if api GET "/nodes/$PVE_NODE/tasks/$UPID_ENC/log" limit=50; then
          printf '%s\n' "$API_DATA" | grep -o '"t":"[^"]*"' | sed 's/^"t":"/    /; s/"$//' >&2
        fi
        printf 'Send the text above to the owner.\n' >&2; exit 1 ;;
    esac
    sleep 2; ELAPSED=$((ELAPSED + 2))
  done
  [ "$ELAPSED" -lt 300 ] || fail 'Timed out waiting for the Proxmox task.'
fi

IP=''
ELAPSED=0
while [ "$ELAPSED" -lt 60 ]; do
  if api GET "/nodes/$PVE_NODE/lxc/$VMID/interfaces"; then
    IP=$(json_lines "$API_DATA" | while IFS= read -r IFACE; do
      [ "$(jget "$IFACE" name)" = eth0 ] || continue
      jget "$IFACE" inet
      break
    done)
    IP=${IP%%/*}
    [ -n "$IP" ] && break
  fi
  sleep 3
  ELAPSED=$((ELAPSED + 3))
done
printf '%s\n' '+------------------------------------------+'
printf '| Container: %-28s |\n' "$CREATED_NAME (ID $VMID)"
if [ -n "$IP" ]; then printf '| IP:        %-28s |\n' "$IP"; else printf '| IP:        %-28s |\n' 'still starting, ask the owner'; fi
printf '| User:      %-28s |\n' root
printf '| Password:  %-28s |\n' "$ROOT_PASSWORD"
printf '| Delete:    %-28s |\n' "$(format_epoch "$EXPIRY")"
printf '%s\n' '+------------------------------------------+'