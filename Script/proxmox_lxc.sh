#!/bin/sh
# =============================================================================
# proxmox_lxc.sh - Manage Proxmox VE LXC containers via the REST API.
#
#   * Run with NO arguments  -> guided, menu-driven mode (what the double-click
#                               launchers use).
#   * Run with a command     -> classic command-line mode (see --help).
#
# Needs only /bin/sh and curl (both ship with macOS and Linux). Nothing to
# install. Windows uses proxmox_lxc.ps1 instead (same features).
#
# Settings are saved in ~/.proxmox_lxc.conf (readable only by you).
# Environment variables PVE_HOST, PVE_NODE, PVE_USER, PVE_TOKEN_NAME,
# PVE_TOKEN_SECRET, PVE_VERIFY_SSL override the saved file; flags override both.
#
# NOTE: plain shell has no JSON parser (no jq), so replies are read with
# sed/grep. That is fine for Proxmox's compact JSON; proxmox_lxc.py is more
# robust if Python happens to be available.
# =============================================================================
set -u

# ------------------------- saved settings + defaults -------------------------
CONF=${PVE_CONFIG:-${HOME:-.}/.proxmox_lxc.conf}
C_HOST=''; C_NODE=''; C_USER=''; C_TNAME=''; C_TSECRET=''
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
C_HOST=${PVE_HOST:-$C_HOST};       C_NODE=${PVE_NODE:-$C_NODE}
C_USER=${PVE_USER:-$C_USER};       C_TNAME=${PVE_TOKEN_NAME:-$C_TNAME}
C_TSECRET=${PVE_TOKEN_SECRET:-$C_TSECRET}
VERIFY=0
case ${PVE_VERIFY_SSL:-} in 1|true|yes) VERIFY=1 ;; esac
TIMEOUT=300; NOWAIT=0
BASE=''

# Per-command options; reset between menu actions.
reset_opts() {
  VMID=''; CT_HOST=''; TEMPLATE=''; CORES=''; MEMORY=''; SWAP=''
  STORAGE=''; DISK=8; NET='name=eth0,bridge=vmbr0,ip=dhcp'
  NAMESERVER=''; DESCRIPTION=''; PASSWORD=''; PWPROMPT=0; SSHKEY=''
  PRIVILEGED=0; ONBOOT=0; START=0; SETS=''; UNSETS=''
  GRACE=60; FORCE=0; PURGE=0; YES=0
}
reset_opts

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { [ "$#" -ge 2 ] || die "Option $1 needs a value"; }

usage() {
  cat <<'EOF'
proxmox_lxc.sh - manage Proxmox LXC containers (no arguments = guided menu)

Connection (flag / environment variable):
  --host PVE_HOST   --node PVE_NODE   --user PVE_USER
  --token-name PVE_TOKEN_NAME   --token-secret PVE_TOKEN_SECRET
  --verify-ssl (or PVE_VERIFY_SSL=1)

Commands:
  create    --vmid N --template STORAGE:vztmpl/FILE [--hostname H] [--cores N]
            [--memory MiB] [--swap MiB] [--storage S] [--disk GiB] [--net STR]
            [--nameserver IP] [--description T] [--password P | --password-prompt]
            [--ssh-key-file F] [--privileged] [--onboot] [--start] [--set K=V]...
  start     --vmid N
  stop      --vmid N                 (hard stop)
  shutdown  --vmid N [--grace SEC]   (graceful, forced after grace)
  delete    --vmid N [--force] [--purge] [--yes]
  configure --vmid N [--cores N] [--memory MiB] [--swap MiB] [--hostname H]
            [--description T] [--set K=V]... [--unset KEY]...
  list
  status    --vmid N
  templates [--storage S]
Common: [--timeout SECONDS] [--no-wait]
EOF
}

# ------------------------- argument parsing ----------------------------------
INTERACTIVE=0
CMD=''
if [ $# -eq 0 ]; then
  INTERACTIVE=1
else
  CMD=$1; shift
  case $CMD in -h|--help|help) usage; exit 0 ;; esac
  while [ $# -gt 0 ]; do
    case $1 in
      --host)          need "$@"; C_HOST=$2;      shift 2 ;;
      --node)          need "$@"; C_NODE=$2;      shift 2 ;;
      --user)          need "$@"; C_USER=$2;      shift 2 ;;
      --token-name)    need "$@"; C_TNAME=$2;     shift 2 ;;
      --token-secret)  need "$@"; C_TSECRET=$2;   shift 2 ;;
      --verify-ssl)    VERIFY=1;                  shift ;;
      --timeout)       need "$@"; TIMEOUT=$2;     shift 2 ;;
      --no-wait)       NOWAIT=1;                  shift ;;
      --vmid)          need "$@"; VMID=$2;        shift 2 ;;
      --hostname)      need "$@"; CT_HOST=$2;     shift 2 ;;
      --template)      need "$@"; TEMPLATE=$2;    shift 2 ;;
      --cores)         need "$@"; CORES=$2;       shift 2 ;;
      --memory)        need "$@"; MEMORY=$2;      shift 2 ;;
      --swap)          need "$@"; SWAP=$2;        shift 2 ;;
      --storage)       need "$@"; STORAGE=$2;     shift 2 ;;
      --disk)          need "$@"; DISK=$2;        shift 2 ;;
      --net)           need "$@"; NET=$2;         shift 2 ;;
      --nameserver)    need "$@"; NAMESERVER=$2;  shift 2 ;;
      --description)   need "$@"; DESCRIPTION=$2; shift 2 ;;
      --password)      need "$@"; PASSWORD=$2;    shift 2 ;;
      --password-prompt) PWPROMPT=1;              shift ;;
      --ssh-key-file)  need "$@"; SSHKEY=$2;      shift 2 ;;
      --privileged)    PRIVILEGED=1;              shift ;;
      --onboot)        ONBOOT=1;                  shift ;;
      --start)         START=1;                   shift ;;
      --set)           need "$@"; SETS="$SETS$2
";                                                shift 2 ;;   # newline-separated list
      --unset)         need "$@"; UNSETS=${UNSETS:+$UNSETS,}$2; shift 2 ;;
      --grace)         need "$@"; GRACE=$2;       shift 2 ;;
      --force)         FORCE=1;                   shift ;;
      --purge)         PURGE=1;                   shift ;;
      -y|--yes)        YES=1;                     shift ;;
      -h|--help)       usage; exit 0 ;;
      *)               die "Unknown option: $1 (try --help)" ;;
    esac
  done
fi

# ------------------------------ connection -----------------------------------
command -v curl >/dev/null 2>&1 || die "curl was not found on this computer."

# Accept "1.2.3.4", "1.2.3.4:8006" or "https://1.2.3.4:8006/".
build_base() {
  B_HOST=${C_HOST#https://}; B_HOST=${B_HOST#http://}; B_HOST=${B_HOST%/}
  case $B_HOST in *:[0-9]*) ;; *) B_HOST="$B_HOST:8006" ;; esac
  BASE="https://$B_HOST/api2/json"
}

check_settings() {
  MISSING=''
  [ -n "$C_HOST" ]    || MISSING="$MISSING --host/PVE_HOST"
  [ -n "$C_NODE" ]    || MISSING="$MISSING --node/PVE_NODE"
  [ -n "$C_USER" ]    || MISSING="$MISSING --user/PVE_USER"
  [ -n "$C_TNAME" ]   || MISSING="$MISSING --token-name/PVE_TOKEN_NAME"
  [ -n "$C_TSECRET" ] || MISSING="$MISSING --token-secret/PVE_TOKEN_SECRET"
  [ -z "$MISSING" ] || { printf 'Missing connection settings:%s\n(Run with no arguments for guided setup.)\n' "$MISSING" >&2; exit 2; }
}

# ------------------------------ API layer ------------------------------------
# api METHOD PATH [key=value ...]
#   GET/DELETE: params go in the query string.  POST/PUT: form-encoded body.
#   Prints the JSON reply on success; prints an error and returns 1 on failure.
#   (Plain sh has no arrays, so each key=value is turned into a curl
#    "--data-urlencode" pair by rotating the positional parameters.)
api() {
  A_METHOD=$1; A_PATH=$2; shift 2
  A_N=$#; A_I=0
  while [ "$A_I" -lt "$A_N" ]; do
    set -- "$@" --data-urlencode "$1"
    shift
    A_I=$((A_I + 1))
  done
  if [ "$A_N" -eq 0 ]; then                      # POST/PUT with no params still need an empty body
    case $A_METHOD in POST|PUT) set -- -d '' ;; esac
  fi
  case $A_METHOD in GET|DELETE) set -- -G "$@" ;; esac    # -G = send data as query string
  [ "$VERIFY" -eq 1 ] || set -- -k "$@"                   # -k = accept self-signed certificate

  # Token auth is stateless: no login ticket and no CSRF token required.
  A_OUT=$(curl -sS --connect-timeout 15 -X "$A_METHOD" \
            -H "Authorization: PVEAPIToken=${C_USER}!${C_TNAME}=${C_TSECRET}" \
            -w '\n%{http_code}' "$@" "$BASE$A_PATH") || {
    printf 'ERROR: cannot reach https://%s - check the address and that the server is on.\n' "$B_HOST" >&2
    return 1; }

  A_CODE=$(printf '%s\n' "$A_OUT" | tail -n 1)
  A_BODY=$(printf '%s\n' "$A_OUT" | sed '$d')
  case $A_CODE in 2??) printf '%s' "$A_BODY"; return 0 ;; esac
  A_HINT=''
  [ "$A_CODE" = 401 ] && A_HINT=' (login rejected: check user, token name and token secret)'
  [ "$A_CODE" = 403 ] && A_HINT=' (token has no permission: untick "Privilege Separation" or grant it a role)'
  printf 'ERROR: HTTP %s%s: %s\n' "$A_CODE" "$A_HINT" "$A_BODY" >&2
  return 1
}

# jget JSON KEY -> value of a simple "KEY":value or "KEY":"value" pair.
jget() { printf '%s\n' "$1" | sed -n 's/.*"'"$2"'":"\{0,1\}\([^",}]*\).*/\1/p'; }

# Split a Proxmox JSON array reply into one object per line.
json_lines() { printf '%s\n' "$1" | sed 's/^{"data":\[//; s/\]}$//; s/},{/}\
{/g'; }

# wait_task UPID - poll until the Proxmox task stops; fail unless exitstatus=OK.
wait_task() {
  W_ENC=$(printf '%s' "$1" | sed 's/:/%3A/g; s/@/%40/g; s/!/%21/g')   # UPIDs contain : @ !
  W_ELAPSED=0
  while [ "$W_ELAPSED" -lt "$TIMEOUT" ]; do
    W_RESP=$(api GET "/nodes/$C_NODE/tasks/$W_ENC/status") || return 1
    case $W_RESP in
      *'"status":"stopped"'*)
        case $W_RESP in *'"exitstatus":"OK"'*) return 0 ;; esac
        printf 'ERROR: task failed: %s\n' "$(jget "$W_RESP" exitstatus)" >&2
        api GET "/nodes/$C_NODE/tasks/$W_ENC/log" limit=50 2>/dev/null \
          | grep -o '"t":"[^"]*"' | sed 's/^"t":"/    /; s/"$//' >&2
        return 1 ;;
    esac
    sleep 2
    W_ELAPSED=$((W_ELAPSED + 2))
  done
  printf 'ERROR: timed out after %ss waiting for the task\n' "$TIMEOUT" >&2
  return 1
}

# run_task METHOD PATH [key=value ...] - call an endpoint that returns a task ID
# (UPID) and wait for it unless --no-wait was given.
run_task() {
  R_M=$1; R_P=$2; shift 2
  R_RESP=$(api "$R_M" "$R_P" "$@") || return 1
  R_UPID=$(printf '%s' "$R_RESP" | sed -n 's/.*"data":"\(UPID:[^"]*\)".*/\1/p')
  if [ -n "$R_UPID" ] && [ "$NOWAIT" -eq 0 ]; then
    wait_task "$R_UPID" || return 1
  fi
  return 0
}

need_vmid() {
  [ -n "$VMID" ] || die "--vmid is required"
  case $VMID in *[!0-9]*) die "VMID must be a number" ;; esac
}

# Read a secret without echoing it to the terminal.
read_secret() {
  printf '%s: ' "$1" >&2
  trap 'stty echo 2>/dev/null' EXIT INT
  stty -echo 2>/dev/null
  IFS= read -r SECRET || SECRET=''
  stty echo 2>/dev/null
  trap - EXIT INT
  printf '\n' >&2
}

# ------------------------------- commands ------------------------------------
cmd_create() {
  need_vmid
  [ -n "$TEMPLATE" ] || die "--template is required (run the 'templates' command to list them)"
  STORAGE=${STORAGE:-local-lvm}

  if [ "$PWPROMPT" -eq 1 ]; then
    read_secret "Root password for the new container"; P1=$SECRET
    read_secret "Repeat password";                      P2=$SECRET
    [ "$P1" = "$P2" ] || die "Passwords do not match."
    PASSWORD=$P1
  fi

  UNPRIV=1; [ "$PRIVILEGED" -eq 1 ] && UNPRIV=0
  set -- "vmid=$VMID" "hostname=${CT_HOST:-ct$VMID}" "ostemplate=$TEMPLATE" \
         "cores=${CORES:-1}" "memory=${MEMORY:-512}" "swap=${SWAP:-512}" \
         "rootfs=$STORAGE:$DISK" "net0=$NET" "unprivileged=$UNPRIV"
  [ -z "$NAMESERVER" ]  || set -- "$@" "nameserver=$NAMESERVER"
  [ -z "$DESCRIPTION" ] || set -- "$@" "description=$DESCRIPTION"
  [ -z "$PASSWORD" ]    || set -- "$@" "password=$PASSWORD"
  [ "$ONBOOT" -eq 0 ]   || set -- "$@" "onboot=1"
  [ "$START" -eq 0 ]    || set -- "$@" "start=1"
  if [ -n "$SSHKEY" ]; then
    [ -r "$SSHKEY" ] || die "Cannot read SSH key file: $SSHKEY"
    set -- "$@" "ssh-public-keys=$(cat "$SSHKEY")"
  fi
  if [ -z "$PASSWORD" ] && [ -z "$SSHKEY" ]; then
    echo "WARNING: no --password/--ssh-key-file given; you will have no login." >&2
  fi
  while IFS= read -r KV; do                       # extra raw options: --set key=value
    [ -n "$KV" ] || continue
    case $KV in *=*) set -- "$@" "$KV" ;; *) die "--set expects key=value, got: $KV" ;; esac
  done <<EOF
$SETS
EOF

  echo "Creating container $VMID on node '$C_NODE' ..."
  run_task POST "/nodes/$C_NODE/lxc" "$@" || exit 1
  echo "OK: container $VMID created."
}

cmd_start() {
  need_vmid; echo "Starting $VMID ..."
  run_task POST "/nodes/$C_NODE/lxc/$VMID/status/start" || exit 1
  echo "OK: $VMID started."
}

cmd_stop() {
  need_vmid; echo "Stopping $VMID ..."
  run_task POST "/nodes/$C_NODE/lxc/$VMID/status/stop" || exit 1
  echo "OK: $VMID stopped."
}

cmd_shutdown() {
  need_vmid; echo "Shutting down $VMID ..."
  [ "$TIMEOUT" -gt $((GRACE + 30)) ] || TIMEOUT=$((GRACE + 30))
  run_task POST "/nodes/$C_NODE/lxc/$VMID/status/shutdown" "timeout=$GRACE" "forceStop=1" || exit 1
  echo "OK: $VMID is down."
}

cmd_delete() {
  need_vmid
  CUR=$(api GET "/nodes/$C_NODE/lxc/$VMID/status/current") || exit 1
  case $CUR in *'"status":"running"'*)
    [ "$FORCE" -eq 1 ] || die "Container $VMID is running. Stop it first, or add --force."
    cmd_stop ;;
  esac
  if [ "$YES" -eq 0 ]; then
    printf "Permanently delete container %s? Type 'yes' to confirm: " "$VMID"
    read -r ANS || ANS=''
    [ "$ANS" = yes ] || { echo "Aborted - nothing was deleted."; exit 0; }
  fi
  echo "Deleting $VMID ..."
  if [ "$PURGE" -eq 1 ]; then set -- purge=1 destroy-unreferenced-disks=1; else set --; fi
  run_task DELETE "/nodes/$C_NODE/lxc/$VMID" "$@" || exit 1
  echo "OK: $VMID deleted."
}

cmd_configure() {
  need_vmid
  set --
  [ -z "$CORES" ]       || set -- "$@" "cores=$CORES"
  [ -z "$MEMORY" ]      || set -- "$@" "memory=$MEMORY"
  [ -z "$SWAP" ]        || set -- "$@" "swap=$SWAP"
  [ -z "$CT_HOST" ]     || set -- "$@" "hostname=$CT_HOST"
  [ -z "$DESCRIPTION" ] || set -- "$@" "description=$DESCRIPTION"
  [ -z "$UNSETS" ]      || set -- "$@" "delete=$UNSETS"       # comma-separated keys to remove
  while IFS= read -r KV; do
    [ -n "$KV" ] || continue
    case $KV in *=*) set -- "$@" "$KV" ;; *) die "--set expects key=value, got: $KV" ;; esac
  done <<EOF
$SETS
EOF
  [ $# -gt 0 ] || die "Nothing to change. Use --cores/--memory/--set key=value/--unset key."
  api PUT "/nodes/$C_NODE/lxc/$VMID/config" "$@" >/dev/null || exit 1
  echo "OK: settings of $VMID updated (CPU/memory changes on a running container may need a restart)."
}

cmd_list() {
  RESP=$(api GET "/nodes/$C_NODE/lxc") || exit 1
  printf '%-7s%-24s%-10s%-6s%-10s\n' VMID NAME STATUS CPUS 'MEM(MiB)'
  json_lines "$RESP" | while IFS= read -r LINE; do
    [ -n "$LINE" ] || continue
    MEM=$(jget "$LINE" maxmem); MEM=$(( ${MEM:-0} / 1048576 ))
    printf '%-7s%-24s%-10s%-6s%-10s\n' "$(jget "$LINE" vmid)" "$(jget "$LINE" name)" \
      "$(jget "$LINE" status)" "$(jget "$LINE" cpus)" "$MEM"
  done | sort -n
}

cmd_status() {
  need_vmid
  S=$(api GET "/nodes/$C_NODE/lxc/$VMID/status/current") || exit 1
  C=$(api GET "/nodes/$C_NODE/lxc/$VMID/config") || exit 1
  printf 'STATUS:\n%s\n\nCONFIG:\n%s\n' \
    "$(printf '%s' "$S" | sed 's/,"/,\
"/g')" "$(printf '%s' "$C" | sed 's/,"/,\
"/g')"
}

# List "storage:vztmpl/file" entries from every storage that holds templates.
list_all_templates() {
  for TS in $(api GET "/nodes/$C_NODE/storage" content=vztmpl \
              | grep -o '"storage":"[^"]*"' | sed 's/^"storage":"//; s/"$//'); do
    api GET "/nodes/$C_NODE/storage/$TS/content" content=vztmpl \
      | grep -o '"volid":"[^"]*"' | sed 's/^"volid":"//; s/"$//'
  done
}

cmd_templates() {
  if [ -n "$STORAGE" ]; then
    OUT=$(api GET "/nodes/$C_NODE/storage/$STORAGE/content" content=vztmpl \
          | grep -o '"volid":"[^"]*"' | sed 's/^"volid":"//; s/"$//')
  else
    OUT=$(list_all_templates)
  fi
  if [ -n "$OUT" ]; then printf '%s\n' "$OUT"
  else echo "No templates found. Use the guided menu (option 7) to download one."; fi
}

# =============================================================================
# GUIDED (INTERACTIVE) MODE
# =============================================================================
ask() {   # ask "Question" [default]  -> ANSWER
  if [ -n "${2:-}" ]; then printf '%s [%s]: ' "$1" "$2"; else printf '%s: ' "$1"; fi
  IFS= read -r ANSWER || exit 0
  [ -n "$ANSWER" ] || ANSWER=${2:-}
}
confirm() {  # confirm "Question" [y|n default]  -> success if yes
  ask "$1 (y/n)" "${2:-y}"
  case $ANSWER in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}
pause_key() { printf '\nPress Enter to go back to the menu...'; read -r _ || exit 0; }

# choose_from "line1\nline2..." "Prompt"  -> CHOICE (returns 1 if cancelled)
choose_from() {
  CF_LIST=$1; CF_PROMPT=$2
  CF_COUNT=$(printf '%s\n' "$CF_LIST" | wc -l | tr -d ' ')
  printf '%s\n' "$CF_LIST" | awk '{printf "  %2d) %s\n", NR, $0}'
  while :; do
    ask "$CF_PROMPT (type a number, or 0 to cancel)" ""
    case $ANSWER in ''|*[!0-9]*) echo "Please type a number."; continue ;; esac
    [ "$ANSWER" -eq 0 ] && return 1
    [ "$ANSWER" -le "$CF_COUNT" ] && break
    echo "Please choose a number from 1 to $CF_COUNT."
  done
  CHOICE=$(printf '%s\n' "$CF_LIST" | sed -n "${ANSWER}p")
}

ask_vmid() {  # show the container list, then ask which one
  cmd_list; echo
  ask "$1" ""; VMID=$ANSWER
  case $VMID in ''|*[!0-9]*) echo "The container ID must be a number."; return 1 ;; esac
}

save_config() {
  (
    umask 077
    {
      printf "C_HOST='%s'\n"   "$(printf '%s' "$C_HOST"   | tr -d "'")"
      printf "C_NODE='%s'\n"   "$(printf '%s' "$C_NODE"   | tr -d "'")"
      printf "C_USER='%s'\n"   "$(printf '%s' "$C_USER"   | tr -d "'")"
      printf "C_TNAME='%s'\n"  "$(printf '%s' "$C_TNAME"  | tr -d "'")"
      printf "C_TSECRET='%s'\n" "$(printf '%s' "$C_TSECRET" | tr -d "'")"
    } > "$CONF"
  ) && echo "Settings saved to $CONF" || echo "Warning: could not save settings."
}

setup_wizard() {
  cat <<'EOF'

==================== First-time setup ====================
You need an "API token" from Proxmox (a password just for this tool).
Create it once in the Proxmox web page:
  Datacenter > Permissions > API Tokens > Add
  - User: root@pam     - Token ID: any name, e.g. manager
  - UNTICK "Privilege Separation" (simplest)
  - Click Add, then COPY THE SECRET (it is shown only once)
==========================================================

EOF
  while :; do
    ask "Proxmox address (IP or name, e.g. 192.168.1.10)" "$C_HOST"; C_HOST=$ANSWER
    ask "Login user" "${C_USER:-root@pam}";                           C_USER=$ANSWER
    ask "Token ID (the name you gave the token)" "$C_TNAME";          C_TNAME=$ANSWER
    read_secret "Token secret (typing is hidden; Enter keeps the saved one)"
    [ -z "$SECRET" ] || C_TSECRET=$SECRET
    build_base
    printf 'Testing the connection... '
    if NODES=$(api GET /nodes); then echo "OK"; break; fi
    confirm "Try again?" y || return 1
  done
  NODE_LIST=$(printf '%s' "$NODES" | grep -o '"node":"[^"]*"' | sed 's/^"node":"//; s/"$//')
  [ -n "$NODE_LIST" ] || { echo "Connected, but found no nodes."; return 1; }
  if [ "$(printf '%s\n' "$NODE_LIST" | wc -l | tr -d ' ')" -eq 1 ]; then
    C_NODE=$NODE_LIST
  else
    echo "Several servers (nodes) found:"; choose_from "$NODE_LIST" "Which one to manage" || return 1
    C_NODE=$CHOICE
  fi
  echo "Using node: $C_NODE"
  save_config
}

action_create() {
  reset_opts
  (
    echo; echo "=== Create a new container ==="
    TPLS=$(list_all_templates)
    if [ -z "$TPLS" ]; then
      echo "No OS templates are on the server yet. Use menu option 7 to download one first."; exit 0
    fi
    echo "Available operating system templates:"
    choose_from "$TPLS" "Pick a template" || { echo Cancelled.; exit 0; }
    TEMPLATE=$CHOICE
    NEXT=$(jget "$(api GET /cluster/nextid)" data)
    ask "Container ID (a free number)" "$NEXT";   VMID=$ANSWER
    case $VMID in ''|*[!0-9]*) echo "The container ID must be a number."; exit 1 ;; esac
    ask "Name for the container" "ct$VMID";        CT_HOST=$ANSWER
    ask "CPU cores" 1;                             CORES=$ANSWER
    ask "Memory in MiB (1024 = 1 GB)" 512;         MEMORY=$ANSWER
    ask "Disk size in GiB" 8;                      DISK=$ANSWER
    STORES=$(api GET "/nodes/$C_NODE/storage" content=rootdir \
             | grep -o '"storage":"[^"]*"' | sed 's/^"storage":"//; s/"$//' | tr '\n' ' ')
    DEF=${STORES%% *}
    case " $STORES" in *" local-lvm "*) DEF=local-lvm ;; esac
    ask "Disk storage (available: ${STORES:-unknown})" "${DEF:-local-lvm}"; STORAGE=$ANSWER
    while :; do
      read_secret "Root password for the container (min 5 characters, hidden)"; P1=$SECRET
      [ "${#P1}" -ge 5 ] || { echo "Too short, try again."; continue; }
      read_secret "Repeat the password"; P2=$SECRET
      [ "$P1" = "$P2" ] && break
      echo "The passwords do not match, try again."
    done
    PASSWORD=$P1
    confirm "Start it right after creating?" y && START=1
    echo
    echo "About to create:  ID $VMID, name $CT_HOST, $CORES core(s), $MEMORY MiB RAM, $DISK GiB disk on $STORAGE"
    confirm "Go ahead?" y || { echo "Cancelled."; exit 0; }
    cmd_create
  )
  pause_key
}

action_start() {
  reset_opts
  ( ask_vmid "Which container ID do you want to START" || exit 1; cmd_start )
  pause_key
}

action_stop() {
  reset_opts
  ( ask_vmid "Which container ID do you want to STOP" || exit 1; GRACE=30; cmd_shutdown )
  pause_key
}

action_delete() {
  reset_opts
  (
    ask_vmid "Which container ID do you want to DELETE" || exit 1
    echo "WARNING: this permanently erases container $VMID and its disk."
    FORCE=1; PURGE=1
    cmd_delete
  )
  pause_key
}

action_configure() {
  reset_opts
  (
    ask_vmid "Which container ID do you want to change" || exit 1
    CUR=$(api GET "/nodes/$C_NODE/lxc/$VMID/config") || exit 1
    echo "Current: $(jget "$CUR" cores) core(s), $(jget "$CUR" memory) MiB memory"
    echo "(Press Enter to leave a value unchanged.)"
    ask "New number of CPU cores" "";  CORES=$ANSWER
    ask "New memory in MiB" "";        MEMORY=$ANSWER
    cmd_configure
  )
  pause_key
}

action_download() {
  reset_opts
  (
    echo; echo "=== Download an OS template to the server ==="
    RESP=$(api GET "/nodes/$C_NODE/aplinfo") || exit 1
    LIST=$(json_lines "$RESP" | while IFS= read -r L; do
             case $L in *'"type":"lxc"'*'"section":"system"'*|*'"section":"system"'*'"type":"lxc"'*)
               jget "$L" template ;; esac
           done | sort)
    [ -n "$LIST" ] || { echo "No downloadable templates found."; exit 1; }
    choose_from "$LIST" "Which template to download" || { echo Cancelled.; exit 0; }
    TPL=$CHOICE
    STORES=$(api GET "/nodes/$C_NODE/storage" content=vztmpl \
             | grep -o '"storage":"[^"]*"' | sed 's/^"storage":"//; s/"$//' | tr '\n' ' ')
    DEF=${STORES%% *}
    ask "Store it on (available: ${STORES:-unknown})" "${DEF:-local}"; ST=$ANSWER
    echo "Downloading $TPL (this can take a minute or two) ..."
    TIMEOUT=900
    run_task POST "/nodes/$C_NODE/aplinfo" "storage=$ST" "template=$TPL" || exit 1
    echo "OK: template downloaded. You can now create containers from it."
  )
  pause_key
}

action_details() {
  reset_opts
  ( ask_vmid "Which container ID do you want details for" || exit 1; cmd_status )
  pause_key
}

interactive() {
  if [ -z "$C_HOST" ] || [ -z "$C_NODE" ] || [ -z "$C_USER" ] || [ -z "$C_TNAME" ] || [ -z "$C_TSECRET" ]; then
    setup_wizard || { echo "Setup was not completed."; exit 1; }
  fi
  build_base
  while :; do
    cat <<EOF

==============================================================
  Proxmox Container Manager      server: $C_HOST   node: $C_NODE
==============================================================
   1) List my containers
   2) Create a new container
   3) Start a container
   4) Stop a container
   5) Delete a container
   6) Change CPU / memory of a container
   7) Download an OS template (needed before the first create)
   8) Show details of a container
   9) Change server / login settings
   0) Quit
EOF
    ask "Choose a number" ""
    case $ANSWER in
      1) ( cmd_list ); pause_key ;;
      2) action_create ;;
      3) action_start ;;
      4) action_stop ;;
      5) action_delete ;;
      6) action_configure ;;
      7) action_download ;;
      8) action_details ;;
      9) setup_wizard; build_base ;;
      0|q|Q) echo "Goodbye."; return 0 ;;
      *) echo "Please type one of the numbers above." ;;
    esac
  done
}

# -------------------------------- dispatch -----------------------------------
if [ "$INTERACTIVE" -eq 1 ]; then
  interactive
  exit 0
fi

check_settings
build_base
case $CMD in
  create)    cmd_create ;;
  start)     cmd_start ;;
  stop)      cmd_stop ;;
  shutdown)  cmd_shutdown ;;
  delete)    cmd_delete ;;
  configure) cmd_configure ;;
  list)      cmd_list ;;
  status)    cmd_status ;;
  templates) cmd_templates ;;
  *)         die "Unknown command: $CMD (try --help)" ;;
esac
