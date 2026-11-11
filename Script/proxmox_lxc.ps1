<#
=============================================================================
 proxmox_lxc.ps1 - Manage Proxmox VE LXC containers via the REST API.

   * Run with NO arguments -> guided, menu-driven mode (what double-clicking
                              START-Windows.cmd does).
   * Run with a command    -> classic command-line mode (see below).

 Uses only Windows PowerShell 5.1, which is built into Windows 10/11. Nothing
 to install. Also works unchanged in PowerShell 7 on any OS.

 Settings are saved in %USERPROFILE%\.proxmox_lxc.json (the token secret is
 encrypted for your Windows account). Environment variables PVE_HOST, PVE_NODE,
 PVE_USER, PVE_TOKEN_NAME, PVE_TOKEN_SECRET, PVE_VERIFY_SSL override the saved
 file; command-line options override both.

 Command-line mode (via START-Windows.cmd <command> [options]):
   create    --vmid N --template STORAGE:vztmpl/FILE [--hostname H] [--cores N]
             [--memory MiB] [--swap MiB] [--storage S] [--disk GiB] [--net STR]
             [--nameserver IP] [--description T] [--password P | --password-prompt]
             [--ssh-key-file F] [--privileged] [--onboot] [--start] [--set K=V]...
   start     --vmid N
   stop      --vmid N              (hard stop)
   shutdown  --vmid N [--grace SECONDS]
   delete    --vmid N [--force] [--purge] [--yes]
   configure --vmid N [--cores N] [--memory MiB] [--swap MiB] [--hostname H]
             [--description T] [--set K=V]... [--unset KEY]...
   list
   status    --vmid N
   templates [--storage S]
 Connection: --host --node --user --token-name --token-secret --verify-ssl
 Common:     --timeout SECONDS  --no-wait
=============================================================================
#>
#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # makes Invoke-RestMethod much faster in PS 5.1

function Fail([string]$Message) { throw [System.InvalidOperationException]::new($Message) }

function Show-Usage {
    # Print the comment block at the top of this file.
    $text = Get-Content -LiteralPath $PSCommandPath -Raw
    if ($text -match '(?s)<#\s*=+\s*(.*?)\s*=+\s*#>') { Write-Host $Matches[1] }
}

# Options for the current command (filled from the command line or by the menu).
$O = @{}
$script:sets   = @()     # --set key=value (repeatable)
$script:unsets = @()     # --unset key     (repeatable)
function Reset-Options {
    $O.Clear()
    $O['timeout'] = 300; $O['disk'] = 8; $O['grace'] = 60
    $O['net'] = 'name=eth0,bridge=vmbr0,ip=dhcp'
    $script:sets = @(); $script:unsets = @()
}
Reset-Options

# --------------------------- argument parsing --------------------------------
$Interactive = ($args.Count -eq 0)
$Command = ''
if (-not $Interactive) {
    if ($args[0] -in '-h', '--help', 'help') { Show-Usage; exit 0 }
    $Command = [string]$args[0]
    $rest    = @($args | Select-Object -Skip 1)

    $valueOpts = 'host','node','user','token-name','token-secret','timeout','vmid','hostname',
                 'template','cores','memory','swap','storage','disk','net','nameserver',
                 'description','password','ssh-key-file','grace'
    $flagOpts  = 'verify-ssl','no-wait','password-prompt','privileged','onboot','start',
                 'force','purge','yes'

    for ($i = 0; $i -lt $rest.Count; ) {
        $a = [string]$rest[$i]
        $name = if ($a.StartsWith('--')) { $a.Substring(2) } else { $null }
        if ($a -eq '-y')                { $O['yes'] = $true; $i++ }
        elseif ($a -in '-h', '--help')  { Show-Usage; exit 0 }
        elseif ($name -in $valueOpts)   {
            if ($i + 1 -ge $rest.Count) { Fail "Option $a needs a value" }
            $O[$name] = [string]$rest[$i + 1]; $i += 2
        }
        elseif ($name -in $flagOpts)    { $O[$name] = $true; $i++ }
        elseif ($name -eq 'set')        {
            if ($i + 1 -ge $rest.Count) { Fail "Option $a needs a value" }
            $script:sets += [string]$rest[$i + 1]; $i += 2
        }
        elseif ($name -eq 'unset')      {
            if ($i + 1 -ge $rest.Count) { Fail "Option $a needs a value" }
            $script:unsets += [string]$rest[$i + 1]; $i += 2
        }
        else { Fail "Unknown option: $a (try --help)" }
    }
}

# ------------------------- saved settings --------------------------------------
$script:ConfPath = if ($env:PVE_CONFIG) { $env:PVE_CONFIG } else { Join-Path $HOME '.proxmox_lxc.json' }

function Get-SavedConfig {
    if (Test-Path -LiteralPath $script:ConfPath) {
        try { return (Get-Content -LiteralPath $script:ConfPath -Raw | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

function Get-SavedSecret($Cfg) {
    if (-not $Cfg) { return '' }
    if ($Cfg.secretProtected) {
        try {
            $ss   = ConvertTo-SecureString $Cfg.secretProtected     # Windows DPAPI: only this user can decrypt
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
            try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        } catch { return '' }
    }
    return [string]$Cfg.secret
}

function Save-Config {
    $obj = [ordered]@{
        host = $script:Conn.host; node = $script:Conn.node
        user = $script:Conn.user; tokenName = $script:Conn.tokenName
    }
    try   { $obj['secretProtected'] = ConvertTo-SecureString $script:Conn.secret -AsPlainText -Force | ConvertFrom-SecureString }
    catch { $obj['secret'] = $script:Conn.secret }       # non-Windows PowerShell: store as plain text
    try {
        $obj | ConvertTo-Json | Set-Content -LiteralPath $script:ConfPath -Encoding UTF8
        Write-Host "Settings saved to $script:ConfPath"
    } catch { Write-Warning "Could not save settings: $($_.Exception.Message)" }
}

# Effective setting = command-line option, else environment variable, else saved file.
function Get-Setting([string]$Opt, [string]$EnvName, $Saved) {
    if ($O[$Opt]) { return [string]$O[$Opt] }
    $e = [Environment]::GetEnvironmentVariable($EnvName)
    if ($e) { return $e }
    if ($Saved) { return [string]$Saved }
    return ''
}

$saved = Get-SavedConfig
$script:Conn = @{
    host      = Get-Setting 'host'         'PVE_HOST'         $saved.host
    node      = Get-Setting 'node'         'PVE_NODE'         $saved.node
    user      = Get-Setting 'user'         'PVE_USER'         $saved.user
    tokenName = Get-Setting 'token-name'   'PVE_TOKEN_NAME'   $saved.tokenName
    secret    = Get-Setting 'token-secret' 'PVE_TOKEN_SECRET' (Get-SavedSecret $saved)
}
$script:Verify   = [bool]$O['verify-ssl'] -or ($env:PVE_VERIFY_SSL -in '1', 'true', 'yes')
$script:SslReady = $false
$script:SkipCert = $false
$script:Base = ''; $script:Node = ''; $script:Headers = @{}

# ---------------------- connection + SSL setup ---------------------------------
function Initialize-Connection {
    # Accept "1.2.3.4", "1.2.3.4:8006" or "https://1.2.3.4:8006/".
    $h = ($script:Conn.host -replace '^https?://', '').TrimEnd('/')
    if ($h -notmatch ':\d+$') { $h += ':8006' }
    $script:Base = "https://$h/api2/json"
    $script:Node = $script:Conn.node
    # Token auth is stateless: no login ticket and no CSRF token required.
    $script:Headers = @{ Authorization = "PVEAPIToken=$($script:Conn.user)!$($script:Conn.tokenName)=$($script:Conn.secret)" }

    if (-not $script:SslReady) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12   # PS 5.1 defaults can be too old
        if (-not $script:Verify) {
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                $script:SkipCert = $true        # PS 7 has a built-in -SkipCertificateCheck switch
            }
            else {
                # PS 5.1 has no such switch: install a certificate policy that accepts the self-signed cert.
                if (-not ('TrustAllCertsPolicy' -as [type])) {
                    Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
                }
                [Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
            }
        }
        $script:SslReady = $true
    }
}

# ------------------------------ API layer ------------------------------------
function Get-ApiError($Record) {
    $ex     = $Record.Exception
    $detail = $Record.ErrorDetails.Message          # PS 7 puts the response body here
    $code   = $null
    if ($ex.Response) {
        try { $code = [int]$ex.Response.StatusCode } catch {}
        if (-not $detail) {                         # PS 5.1: read the body from the response stream
            try { $detail = (New-Object IO.StreamReader($ex.Response.GetResponseStream())).ReadToEnd() } catch {}
        }
        if (-not $detail) { try { $detail = $ex.Response.StatusDescription } catch {} }
    }
    if (-not $code) { return "Cannot reach $script:Base - check the address and that the server is on. ($($ex.Message))" }
    $hint = ''
    if ($code -eq 401) { $hint = ' (login rejected: check user, token name and token secret)' }
    if ($code -eq 403) { $hint = ' (token has no permission: untick "Privilege Separation" or grant it a role)' }
    return "HTTP $code$hint : $detail"
}

# Invoke-Api METHOD PATH [hashtable]  -> the 'data' field of Proxmox's reply.
#   GET/DELETE: params go in the query string.  POST/PUT: form-encoded body.
function Invoke-Api([string]$Method, [string]$Path, [hashtable]$Params = @{}) {
    $pairs = @()
    foreach ($k in $Params.Keys) {
        $v = $Params[$k]
        if ($null -eq $v -or "$v" -eq '') { continue }          # skip unset values
        if ($v -is [bool]) { $v = [int]$v }                      # Proxmox wants 1/0
        $pairs += ('{0}={1}' -f [uri]::EscapeDataString($k), [uri]::EscapeDataString("$v"))
    }
    $query = $pairs -join '&'
    $req = @{ Method = $Method; Headers = $script:Headers; TimeoutSec = 30 }
    if ($Method -in 'POST', 'PUT') {
        $req.Uri         = $script:Base + $Path
        $req.Body        = $query
        $req.ContentType = 'application/x-www-form-urlencoded'
    }
    else {
        $req.Uri = $script:Base + $Path + $(if ($query) { "?$query" } else { '' })
    }
    if ($script:SkipCert) { $req.SkipCertificateCheck = $true }
    try   { $resp = Invoke-RestMethod @req }
    catch { Fail (Get-ApiError $_) }
    return $resp.data
}

# Most write operations return a UPID (task ID) and run asynchronously.
function Wait-Task([string]$Upid) {
    $enc      = [uri]::EscapeDataString($Upid)
    $deadline = (Get-Date).AddSeconds([int]$O['timeout'])
    while ((Get-Date) -lt $deadline) {
        $st = Invoke-Api GET "/nodes/$script:Node/tasks/$enc/status"
        if ($st.status -eq 'stopped') {
            if ($st.exitstatus -eq 'OK') { return }
            $log   = @(Invoke-Api GET "/nodes/$script:Node/tasks/$enc/log" @{ limit = 50 })
            $lines = ($log | ForEach-Object { '    ' + $_.t }) -join "`n"
            Fail "Task failed: $($st.exitstatus)`n$lines"
        }
        Start-Sleep -Seconds 2
    }
    Fail "Timed out after $($O['timeout'])s waiting for task $Upid"
}

function Invoke-Task([string]$Method, [string]$Path, [hashtable]$Params = @{}) {
    $upid = Invoke-Api $Method $Path $Params
    if ($upid -is [string] -and $upid.StartsWith('UPID:') -and -not $O['no-wait']) { Wait-Task $upid }
}

# ------------------------------- helpers -------------------------------------
function Get-Vmid {
    if (-not $O['vmid']) { Fail '--vmid is required' }
    if ("$($O['vmid'])" -notmatch '^\d+$') { Fail 'VMID must be a number' }
    return [int]$O['vmid']
}

function ConvertFrom-KvList([string[]]$Items) {
    $h = @{}
    foreach ($item in $Items) {
        $idx = $item.IndexOf('=')
        if ($idx -lt 1) { Fail "--set expects key=value, got: $item" }
        $h[$item.Substring(0, $idx).Trim()] = $item.Substring($idx + 1)   # split on FIRST '=' only
    }
    return $h
}

function Read-Secret([string]$Prompt) {
    $s    = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# ------------------------------- commands ------------------------------------
function Invoke-Create {
    $vmid = Get-Vmid
    if (-not $O['template']) { Fail "--template is required (run the 'templates' command to list them)" }
    $storage = if ($O['storage']) { $O['storage'] } else { 'local-lvm' }

    $p = @{
        vmid         = $vmid
        hostname     = $(if ($O['hostname']) { $O['hostname'] } else { "ct$vmid" })
        ostemplate   = $O['template']
        cores        = $(if ($O['cores'])  { $O['cores'] }  else { 1 })
        memory       = $(if ($O['memory']) { $O['memory'] } else { 512 })   # MiB
        swap         = $(if ($O['swap'])   { $O['swap'] }   else { 512 })   # MiB
        rootfs       = "${storage}:$($O['disk'])"                           # <storage>:<GiB>
        net0         = $O['net']
        unprivileged = -not $O['privileged']
        nameserver   = $O['nameserver']
        description  = $O['description']
        onboot       = $O['onboot']
        start        = $O['start']
    }
    if ($O['password-prompt']) {
        $p1 = Read-Secret 'Root password for the new container'
        $p2 = Read-Secret 'Repeat password'
        if ($p1 -ne $p2) { Fail 'Passwords do not match.' }
        $p['password'] = $p1
    }
    elseif ($O['password']) { $p['password'] = $O['password'] }

    if ($O['ssh-key-file']) {
        if (-not (Test-Path -LiteralPath $O['ssh-key-file'])) { Fail "Cannot read SSH key file: $($O['ssh-key-file'])" }
        $p['ssh-public-keys'] = (Get-Content -LiteralPath $O['ssh-key-file'] -Raw).Trim()
    }
    if (-not $p['password'] -and -not $p['ssh-public-keys']) {
        Write-Warning 'No --password/--ssh-key-file given; you will have no login.'
    }
    $extra = ConvertFrom-KvList $script:sets          # extra raw options, e.g. --set features=nesting=1
    foreach ($k in $extra.Keys) { $p[$k] = $extra[$k] }

    Write-Host "Creating container $vmid on node '$script:Node' ..."
    Invoke-Task POST "/nodes/$script:Node/lxc" $p
    Write-Host "OK: container $vmid created."
}

function Invoke-Start {
    $vmid = Get-Vmid; Write-Host "Starting $vmid ..."
    Invoke-Task POST "/nodes/$script:Node/lxc/$vmid/status/start"
    Write-Host "OK: $vmid started."
}

function Invoke-Stop {
    $vmid = Get-Vmid; Write-Host "Stopping $vmid ..."
    Invoke-Task POST "/nodes/$script:Node/lxc/$vmid/status/stop"
    Write-Host "OK: $vmid stopped."
}

function Invoke-Shutdown {
    $vmid = Get-Vmid; Write-Host "Shutting down $vmid ..."
    $grace = [int]$O['grace']
    if ([int]$O['timeout'] -lt $grace + 30) { $O['timeout'] = $grace + 30 }
    Invoke-Task POST "/nodes/$script:Node/lxc/$vmid/status/shutdown" @{ timeout = $grace; forceStop = $true }
    Write-Host "OK: $vmid is down."
}

function Invoke-Delete {
    $vmid = Get-Vmid
    $cur = Invoke-Api GET "/nodes/$script:Node/lxc/$vmid/status/current"
    if ($cur.status -eq 'running') {
        if (-not $O['force']) { Fail "Container $vmid is running. Stop it first, or add --force." }
        Invoke-Stop
    }
    if (-not $O['yes']) {
        $ans = Read-Host "Permanently delete container $vmid? Type 'yes' to confirm"
        if ($ans.Trim().ToLower() -ne 'yes') { Write-Host 'Aborted - nothing was deleted.'; return }
    }
    Write-Host "Deleting $vmid ..."
    $p = @{}
    if ($O['purge']) { $p['purge'] = $true; $p['destroy-unreferenced-disks'] = $true }
    Invoke-Task DELETE "/nodes/$script:Node/lxc/$vmid" $p
    Write-Host "OK: $vmid deleted."
}

function Invoke-Configure {
    $vmid = Get-Vmid
    $p = @{
        cores = $O['cores']; memory = $O['memory']; swap = $O['swap']
        hostname = $O['hostname']; description = $O['description']
    }
    $extra = ConvertFrom-KvList $script:sets
    foreach ($k in $extra.Keys) { $p[$k] = $extra[$k] }
    if ($script:unsets.Count -gt 0) { $p['delete'] = ($script:unsets -join ',') }   # comma-separated keys to remove
    $hasAny = $false
    foreach ($v in $p.Values) { if ($null -ne $v -and "$v" -ne '') { $hasAny = $true } }
    if (-not $hasAny) { Fail 'Nothing to change. Use --cores/--memory/--set key=value/--unset key.' }
    $null = Invoke-Api PUT "/nodes/$script:Node/lxc/$vmid/config" $p
    Write-Host "OK: settings of $vmid updated (CPU/memory changes on a running container may need a restart)."
}

function Invoke-List {
    $rows = @(Invoke-Api GET "/nodes/$script:Node/lxc")
    Write-Host ('{0,-7}{1,-24}{2,-10}{3,-6}{4,-10}' -f 'VMID', 'NAME', 'STATUS', 'CPUS', 'MEM(MiB)')
    foreach ($c in ($rows | Where-Object { $_ } | Sort-Object { [int]$_.vmid })) {
        Write-Host ('{0,-7}{1,-24}{2,-10}{3,-6}{4,-10}' -f $c.vmid, $c.name, $c.status, $c.cpus, [int]($c.maxmem / 1MB))
    }
}

function Invoke-Status {
    $vmid = Get-Vmid
    $st  = Invoke-Api GET "/nodes/$script:Node/lxc/$vmid/status/current"
    $cfg = Invoke-Api GET "/nodes/$script:Node/lxc/$vmid/config"
    @{ status = $st; config = $cfg } | ConvertTo-Json -Depth 6
}

# Every template file ("storage:vztmpl/name") on every storage that holds templates.
function Get-AllTemplates {
    foreach ($s in @(Invoke-Api GET "/nodes/$script:Node/storage" @{ content = 'vztmpl' })) {
        if (-not $s) { continue }
        foreach ($it in @(Invoke-Api GET "/nodes/$script:Node/storage/$($s.storage)/content" @{ content = 'vztmpl' })) {
            if ($it) { $it.volid }
        }
    }
}

function Invoke-Templates {
    if ($O['storage']) {
        $items = @(Invoke-Api GET "/nodes/$script:Node/storage/$($O['storage'])/content" @{ content = 'vztmpl' }) |
                 Where-Object { $_ } | ForEach-Object { $_.volid }
    }
    else { $items = @(Get-AllTemplates) }
    if ($items) { $items }
    else { Write-Host 'No templates found. Use the guided menu (option 7) to download one.' }
}

# =============================================================================
# GUIDED (INTERACTIVE) MODE
# =============================================================================
function Ask([string]$Prompt, [string]$Default = '') {
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $r = Read-Host "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
    return $r.Trim()
}

function Confirm-Yes([string]$Prompt, [string]$Default = 'y') {
    return ((Ask "$Prompt (y/n)" $Default) -match '^(y|yes)$')
}

function Wait-Key { Read-Host "`nPress Enter to go back to the menu..." | Out-Null }

# Show a numbered list; return the chosen item, or $null if cancelled.
function Select-FromList([string[]]$Items, [string]$Prompt) {
    for ($n = 0; $n -lt $Items.Count; $n++) { Write-Host ('  {0,2}) {1}' -f ($n + 1), $Items[$n]) }
    while ($true) {
        $a = Ask "$Prompt (type a number, or 0 to cancel)"
        if ($a -notmatch '^\d+$') { Write-Host 'Please type a number.'; continue }
        $k = [int]$a
        if ($k -eq 0) { return $null }
        if ($k -le $Items.Count) { return $Items[$k - 1] }
        Write-Host "Please choose a number from 1 to $($Items.Count)."
    }
}

# Run one menu action; show errors instead of closing the program.
function Invoke-Safely([scriptblock]$Block) {
    try { & $Block }
    catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
}

function Read-VmidFromUser([string]$Prompt) {
    Invoke-List
    Write-Host ''
    $id = Ask $Prompt
    if ($id -notmatch '^\d+$') { Fail 'The container ID must be a number.' }
    $O['vmid'] = $id
}

function Start-Setup {
    Write-Host @'

==================== First-time setup ====================
You need an "API token" from Proxmox (a password just for this tool).
Create it once in the Proxmox web page:
  Datacenter > Permissions > API Tokens > Add
  - User: root@pam     - Token ID: any name, e.g. manager
  - UNTICK "Privilege Separation" (simplest)
  - Click Add, then COPY THE SECRET (it is shown only once)
==========================================================

'@
    $nodes = @()
    while ($true) {
        $script:Conn.host      = Ask 'Proxmox address (IP or name, e.g. 192.168.1.10)' $script:Conn.host
        $script:Conn.user      = Ask 'Login user' $(if ($script:Conn.user) { $script:Conn.user } else { 'root@pam' })
        $script:Conn.tokenName = Ask 'Token ID (the name you gave the token)' $script:Conn.tokenName
        $sec = Read-Secret 'Token secret (typing is hidden; Enter keeps the saved one)'
        if ($sec) { $script:Conn.secret = $sec }
        try {
            Initialize-Connection
            Write-Host 'Testing the connection... ' -NoNewline
            $nodes = @(Invoke-Api GET '/nodes')
            Write-Host 'OK'
            break
        }
        catch {
            Write-Host ''
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
            if (-not (Confirm-Yes 'Try again?' 'y')) { return $false }
        }
    }
    $names = @($nodes | Where-Object { $_ } | ForEach-Object { $_.node })
    if ($names.Count -eq 0) { Write-Host 'Connected, but found no nodes.'; return $false }
    if ($names.Count -eq 1) { $script:Conn.node = $names[0] }
    else {
        Write-Host 'Several servers (nodes) found:'
        $pick = Select-FromList $names 'Which one to manage'
        if (-not $pick) { return $false }
        $script:Conn.node = $pick
    }
    Write-Host "Using node: $($script:Conn.node)"
    Initialize-Connection
    Save-Config
    return $true
}

function Do-Create {
    Reset-Options
    Write-Host "`n=== Create a new container ==="
    $tpls = @(Get-AllTemplates)
    if ($tpls.Count -eq 0) { Write-Host 'No OS templates are on the server yet. Use menu option 7 to download one first.'; return }
    Write-Host 'Available operating system templates:'
    $t = Select-FromList $tpls 'Pick a template'
    if (-not $t) { Write-Host 'Cancelled.'; return }
    $O['template'] = $t

    $next = Invoke-Api GET '/cluster/nextid'
    $vmid = Ask 'Container ID (a free number)' "$next"
    if ($vmid -notmatch '^\d+$') { Fail 'The container ID must be a number.' }
    $O['vmid']     = $vmid
    $O['hostname'] = Ask 'Name for the container' "ct$vmid"
    $O['cores']    = Ask 'CPU cores' '1'
    $O['memory']   = Ask 'Memory in MiB (1024 = 1 GB)' '512'
    $O['disk']     = Ask 'Disk size in GiB' '8'

    $stores = @(Invoke-Api GET "/nodes/$script:Node/storage" @{ content = 'rootdir' } | Where-Object { $_ } | ForEach-Object { $_.storage })
    $def = if ($stores -contains 'local-lvm') { 'local-lvm' } elseif ($stores.Count -gt 0) { $stores[0] } else { 'local-lvm' }
    $O['storage'] = Ask "Disk storage (available: $($stores -join ', '))" $def

    while ($true) {
        $p1 = Read-Secret 'Root password for the container (min 5 characters, hidden)'
        if ($p1.Length -lt 5) { Write-Host 'Too short, try again.'; continue }
        $p2 = Read-Secret 'Repeat the password'
        if ($p1 -eq $p2) { break }
        Write-Host 'The passwords do not match, try again.'
    }
    $O['password'] = $p1
    if (Confirm-Yes 'Start it right after creating?' 'y') { $O['start'] = $true }

    Write-Host ''
    Write-Host "About to create:  ID $vmid, name $($O['hostname']), $($O['cores']) core(s), $($O['memory']) MiB RAM, $($O['disk']) GiB disk on $($O['storage'])"
    if (-not (Confirm-Yes 'Go ahead?' 'y')) { Write-Host 'Cancelled.'; return }
    Invoke-Create
}

function Do-Start     { Reset-Options; Read-VmidFromUser 'Which container ID do you want to START'; Invoke-Start }
function Do-Stop      { Reset-Options; Read-VmidFromUser 'Which container ID do you want to STOP'; $O['grace'] = 30; Invoke-Shutdown }
function Do-Details   { Reset-Options; Read-VmidFromUser 'Which container ID do you want details for'; Invoke-Status }

function Do-Delete {
    Reset-Options
    Read-VmidFromUser 'Which container ID do you want to DELETE'
    Write-Host "WARNING: this permanently erases container $($O['vmid']) and its disk."
    $O['force'] = $true; $O['purge'] = $true
    Invoke-Delete
}

function Do-Configure {
    Reset-Options
    Read-VmidFromUser 'Which container ID do you want to change'
    $cur = Invoke-Api GET "/nodes/$script:Node/lxc/$($O['vmid'])/config"
    Write-Host "Current: $($cur.cores) core(s), $($cur.memory) MiB memory"
    Write-Host '(Press Enter to leave a value unchanged.)'
    $O['cores']  = Ask 'New number of CPU cores'
    $O['memory'] = Ask 'New memory in MiB'
    Invoke-Configure
}

function Do-Download {
    Reset-Options
    Write-Host "`n=== Download an OS template to the server ==="
    $apl = @(Invoke-Api GET "/nodes/$script:Node/aplinfo") |
           Where-Object { $_ -and $_.type -eq 'lxc' -and $_.section -eq 'system' } | Sort-Object template
    $names = @($apl | ForEach-Object { $_.template })
    if ($names.Count -eq 0) { Write-Host 'No downloadable templates found.'; return }
    $tpl = Select-FromList $names 'Which template to download'
    if (-not $tpl) { Write-Host 'Cancelled.'; return }
    $stores = @(Invoke-Api GET "/nodes/$script:Node/storage" @{ content = 'vztmpl' } | Where-Object { $_ } | ForEach-Object { $_.storage })
    $def = if ($stores.Count -gt 0) { $stores[0] } else { 'local' }
    $st = Ask "Store it on (available: $($stores -join ', '))" $def
    Write-Host "Downloading $tpl (this can take a minute or two) ..."
    $O['timeout'] = 900
    Invoke-Task POST "/nodes/$script:Node/aplinfo" @{ storage = $st; template = $tpl }
    Write-Host 'OK: template downloaded. You can now create containers from it.'
}

function Start-Interactive {
    if (-not ($script:Conn.host -and $script:Conn.node -and $script:Conn.user -and $script:Conn.tokenName -and $script:Conn.secret)) {
        if (-not (Start-Setup)) { Write-Host 'Setup was not completed.'; return }
    }
    Initialize-Connection
    while ($true) {
        Write-Host ''
        Write-Host '=============================================================='
        Write-Host "  Proxmox Container Manager      server: $($script:Conn.host)   node: $script:Node"
        Write-Host '=============================================================='
        Write-Host '   1) List my containers'
        Write-Host '   2) Create a new container'
        Write-Host '   3) Start a container'
        Write-Host '   4) Stop a container'
        Write-Host '   5) Delete a container'
        Write-Host '   6) Change CPU / memory of a container'
        Write-Host '   7) Download an OS template (needed before the first create)'
        Write-Host '   8) Show details of a container'
        Write-Host '   9) Change server / login settings'
        Write-Host '   0) Quit'
        $c = Ask 'Choose a number'
        switch ($c) {
            '1' { Invoke-Safely { Reset-Options; Invoke-List }; Wait-Key }
            '2' { Invoke-Safely { Do-Create };    Wait-Key }
            '3' { Invoke-Safely { Do-Start };     Wait-Key }
            '4' { Invoke-Safely { Do-Stop };      Wait-Key }
            '5' { Invoke-Safely { Do-Delete };    Wait-Key }
            '6' { Invoke-Safely { Do-Configure }; Wait-Key }
            '7' { Invoke-Safely { Do-Download };  Wait-Key }
            '8' { Invoke-Safely { Do-Details };   Wait-Key }
            '9' { Invoke-Safely { $null = Start-Setup } }
            '0' { Write-Host 'Goodbye.'; return }
            'q' { Write-Host 'Goodbye.'; return }
            default { Write-Host 'Please type one of the numbers above.' }
        }
    }
}

# -------------------------------- main ---------------------------------------
try {
    if ($Interactive) {
        Start-Interactive
        exit 0
    }

    $missing = @()
    if (-not $script:Conn.host)      { $missing += '--host/PVE_HOST' }
    if (-not $script:Conn.node)      { $missing += '--node/PVE_NODE' }
    if (-not $script:Conn.user)      { $missing += '--user/PVE_USER' }
    if (-not $script:Conn.tokenName) { $missing += '--token-name/PVE_TOKEN_NAME' }
    if (-not $script:Conn.secret)    { $missing += '--token-secret/PVE_TOKEN_SECRET' }
    if ($missing) {
        [Console]::Error.WriteLine('Missing connection settings: ' + ($missing -join ', '))
        [Console]::Error.WriteLine('(Run without arguments for guided setup.)')
        exit 2
    }
    Initialize-Connection

    switch ($Command) {
        'create'    { Invoke-Create }
        'start'     { Invoke-Start }
        'stop'      { Invoke-Stop }
        'shutdown'  { Invoke-Shutdown }
        'delete'    { Invoke-Delete }
        'configure' { Invoke-Configure }
        'list'      { Invoke-List }
        'status'    { Invoke-Status }
        'templates' { Invoke-Templates }
        default     { Fail "Unknown command: $Command (try --help)" }
    }
}
catch {
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
    exit 1
}
