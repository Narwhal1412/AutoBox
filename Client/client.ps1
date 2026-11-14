#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Dir = Split-Path -Parent $PSCommandPath
$script:SettingsPath = if ($env:AUTOBOX_SETTINGS) { $env:AUTOBOX_SETTINGS } else { Join-Path $script:Dir 'settings.txt' }

function Fail([string]$Text) { throw [System.InvalidOperationException]::new($Text) }
function Read-KvFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { Fail "Cannot read file: $Path" }
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $line = $line.TrimEnd([char]13)
        if (-not $line -or $line.TrimStart().StartsWith('#') -or -not $line.Contains('=')) { continue }
        $index = $line.IndexOf('=')
        $values[$line.Substring(0, $index)] = $line.Substring($index + 1)
    }
    return $values
}

try {
    $settings = Read-KvFile $script:SettingsPath
    $messagePath = Join-Path $script:Dir 'message.txt'
    if (-not (Test-Path -LiteralPath $messagePath)) { Fail "Cannot read message file: $messagePath" }
    [IO.File]::ReadAllText($messagePath).TrimEnd([char]13) | Write-Host
    $answer = Read-Host 'Create it now? (y/n)'
    if ($answer -cnotin @('y','Y','yes')) { Write-Host 'Cancelled. Nothing was created.'; exit 0 }

    $defaults = @{
        PVE_HOST=''; PVE_USER='root@pam'; PVE_TOKEN_NAME=''; PVE_TOKEN_SECRET=''; PVE_NODE=''
        TEMPLATE='sas-bulk:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst'; CORES='1'; MEMORY='512'
        DISK='8'; STORAGE='ssd-storage'; IP_MODE='dhcp'; BRIDGE='vmbr0'; ROOT_PASSWORD='docker'
        NAME_PREFIX='client'; FEATURES=''; LIFETIME_DAYS='2'; VERIFY_SSL='0'
    }
    foreach ($key in $defaults.Keys) { if (-not $settings.ContainsKey($key)) { $settings[$key] = $defaults[$key] } }
    $missing = @('PVE_HOST','PVE_TOKEN_NAME','PVE_TOKEN_SECRET') | Where-Object { -not $settings[$_] }
    if ($missing.Count) { Fail ('Settings are not finished. Fill in: ' + ($missing -join ', ')) }
    if ($settings.ROOT_PASSWORD.Length -lt 5) { Fail 'ROOT_PASSWORD must be at least 5 characters.' }
    if ($settings.LIFETIME_DAYS -notmatch '^\d+$' -or [long]$settings.LIFETIME_DAYS -lt 1) {
        Fail 'LIFETIME_DAYS must be a whole number of at least 1.'
    }

    $hostName = $settings.PVE_HOST -replace '^https?://', ''
    $hostName = $hostName.TrimEnd('/')
    if ($hostName -notmatch ':\d+$') { $hostName += ':8006' }
    $script:Base = "https://$hostName/api2/json"
    $script:Verify = $settings.VERIFY_SSL -in @('1','true','yes','TRUE','YES')
    $script:Headers = @{ Authorization = "PVEAPIToken=$($settings.PVE_USER)!$($settings.PVE_TOKEN_NAME)=$($settings.PVE_TOKEN_SECRET)" }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not $script:Verify) {
        if (-not ('AutoBoxTrustAllCertsPolicy' -as [type])) {
            Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class AutoBoxTrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
        }
        [Net.ServicePointManager]::CertificatePolicy = New-Object AutoBoxTrustAllCertsPolicy
    }

    function Invoke-Api([string]$Method, [string]$Path, [hashtable]$Params = @{}) {
        $pairs = @()
        foreach ($key in $Params.Keys) {
            if ($null -ne $Params[$key] -and "$($Params[$key])" -ne '') {
                $pairs += ('{0}={1}' -f [uri]::EscapeDataString($key), [uri]::EscapeDataString([string]$Params[$key]))
            }
        }
        $query = $pairs -join '&'
        if ($Method -in @('POST','PUT')) {
            $request = @{ Method=$Method; Uri=($script:Base + $Path); Headers=$script:Headers; Body=$query; ContentType='application/x-www-form-urlencoded'; TimeoutSec=30 }
        } else {
            $uri = $script:Base + $Path
            if ($query) { $uri += "?$query" }
            $request = @{ Method=$Method; Uri=$uri; Headers=$script:Headers; TimeoutSec=30 }
        }
        try { return (Invoke-RestMethod @request).data }
        catch {
            $code = $null; $detail = $_.ErrorDetails.Message
            if ($_.Exception.Response) {
                try { $code = [int]$_.Exception.Response.StatusCode } catch {}
                if (-not $detail) {
                    try { $detail = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {}
                }
            }
            if ($code -eq 401) { Fail 'The Proxmox token was rejected (HTTP 401). Check PVE_USER, PVE_TOKEN_NAME, and PVE_TOKEN_SECRET.' }
            if ($code -eq 403) { Fail 'The Proxmox token has no permission (HTTP 403). Check its permissions.' }
            if (-not $detail) { $detail = $_.Exception.Message }
            Fail "HTTP $code`: $detail"
        }
    }

    $nodes = @(Invoke-Api GET '/nodes')
    $node = $settings.PVE_NODE
    if (-not $node -and $nodes.Count) { $node = [string]$nodes[0].node }
    if (-not $node) { Fail 'No Proxmox node was found.' }
    $status = Invoke-Api GET "/nodes/$node/status"
    $serverTime = [long]$status.time
    $expiry = $serverTime + ([long]$settings.LIFETIME_DAYS * 86400)
    $expiryDate = [DateTimeOffset]::FromUnixTimeSeconds($expiry).UtcDateTime.ToString('yyyy-MM-dd HH:mm UTC')
    $createdDate = [DateTimeOffset]::FromUnixTimeSeconds($serverTime).UtcDateTime.ToString('yyyy-MM-dd HH:mm UTC')

    $template = $settings.TEMPLATE
    if (-not $template) {
        foreach ($store in @(Invoke-Api GET "/nodes/$node/storage" @{ content='vztmpl' })) {
            $content = @(Invoke-Api GET "/nodes/$node/storage/$($store.storage)/content" @{ content='vztmpl' })
            if ($content.Count) { $template = [string]$content[0].volid; break }
        }
        if (-not $template) { Fail 'No container template was found on the server.' }
    }
    $storage = $settings.STORAGE
    if (-not $storage) {
        $stores = @(Invoke-Api GET "/nodes/$node/storage" @{ content='rootdir' } | ForEach-Object { [string]$_.storage })
        if ($stores -contains 'local-lvm') { $storage = 'local-lvm' } elseif ($stores.Count) { $storage = $stores[0] }
        if (-not $storage) { Fail 'No storage that supports container disks was found.' }
    }
    $baseId = [int](Invoke-Api GET '/cluster/nextid')
    $prefix = ($settings.NAME_PREFIX.ToLowerInvariant() -replace '[^a-z0-9-]', '')
    if (-not $prefix) { $prefix = 'client' }
    $creator = "$env:USERNAME@$env:COMPUTERNAME"
    $description = "AutoBox temporary container. Created by $creator on $createdDate.`nAuto-deleted after $expiryDate."
    $tags = "autobox;exp-$expiry"
    $vmid = $baseId; $created = $false; $upid = ''

    for ($attempt = 0; $attempt -le 6; $attempt++) {
        $name = "$prefix-$vmid"
        $params = @{
            vmid=[string]$vmid; hostname=$name; ostemplate=$template; cores=$settings.CORES
            memory=$settings.MEMORY; swap='512'; rootfs="$storage`:$($settings.DISK)"
            net0="name=eth0,bridge=$($settings.BRIDGE),ip=$($settings.IP_MODE)"
            unprivileged='1'; password=$settings.ROOT_PASSWORD; start='1'; tags=$tags; description=$description
        }
        if ($settings.FEATURES) { $params.features = $settings.FEATURES }
        try { $upid = [string](Invoke-Api POST "/nodes/$node/lxc" $params); $created = $true; break }
        catch {
            $text = $_.Exception.Message
            if ($text -notmatch 'already exists|already in use' -or $attempt -ge 6) { throw }
            $probe = $baseId + (Get-Random -Minimum 0 -Maximum 30)
            if ($probe -eq $vmid) { $probe++ }
            $vmid = [int](Invoke-Api GET '/cluster/nextid' @{ vmid=[string]$probe })
        }
    }
    if (-not $created) { Fail 'Could not reserve a free container ID after 6 retries.' }

    if ($upid.StartsWith('UPID:')) {
        $encoded = [uri]::EscapeDataString($upid)
        $deadline = (Get-Date).AddSeconds(300)
        while ((Get-Date) -lt $deadline) {
            $task = Invoke-Api GET "/nodes/$node/tasks/$encoded/status"
            if ($task.status -eq 'stopped') {
                if ($task.exitstatus -ne 'OK') {
                    $log = @(Invoke-Api GET "/nodes/$node/tasks/$encoded/log" @{ limit='50' } | ForEach-Object { '    ' + $_.t }) -join "`n"
                    Fail "Task failed: $($task.exitstatus)`n$log`nSend the text above to the owner."
                }
                break
            }
            Start-Sleep -Seconds 2
        }
        if ((Get-Date) -ge $deadline) { Fail 'Timed out waiting for the Proxmox task.' }
    }

    $ip = ''
    for ($wait = 0; $wait -lt 60 -and -not $ip; $wait += 3) {
        try {
            $interfaces = @(Invoke-Api GET "/nodes/$node/lxc/$vmid/interfaces")
            $eth0 = $interfaces | Where-Object { $_.name -eq 'eth0' } | Select-Object -First 1
            if ($eth0.inet) { $ip = ([string]$eth0.inet -split '/')[0] }
        } catch {}
        if (-not $ip -and $wait -lt 57) { Start-Sleep -Seconds 3 }
    }
    Write-Host ''
    Write-Host '+------------------------------------------+'
    Write-Host (('| Container: {0,-28} |' -f "$name (ID $vmid)"))
    if ($ip) { Write-Host (('| IP:        {0,-28} |' -f $ip)) } else { Write-Host '| IP:        still starting, ask the owner |' }
    Write-Host '| User:      root                         |'
    Write-Host (('| Password:  {0,-28} |' -f $settings.ROOT_PASSWORD))
    Write-Host (('| Delete:    {0,-28} |' -f $expiryDate))
    Write-Host '+------------------------------------------+'
}
catch {
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
    if ($_.Exception.Message -notmatch '^The Proxmox token|^HTTP 401|^HTTP 403') {
        [Console]::Error.WriteLine('Send the text above to the owner.')
    }
    exit 1
}
