#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Dir = Split-Path -Parent $PSCommandPath
$script:SettingsPath = if ($env:AUTOBOX_SETTINGS) { $env:AUTOBOX_SETTINGS } else { Join-Path $script:Dir 'settings.txt' }

function Fail([string]$Text) { throw [System.InvalidOperationException]::new($Text) }
function Read-KvFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { Fail "Cannot read settings file: $Path" }
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
    $messagePath = Join-Path $script:Dir 'message-vm.txt'
    if (-not (Test-Path -LiteralPath $messagePath)) { Fail "Cannot read message file: $messagePath" }
    [IO.File]::ReadAllText($messagePath).TrimEnd([char]13) | Write-Host
    $answer = Read-Host 'Create it now? (y/n)'
    if ($answer -cnotin @('y','Y','yes')) { Write-Host 'Cancelled. Nothing was created.'; exit 0 }

    $defaults = @{
        PVE_HOST=''; PVE_USER='root@pam'; PVE_TOKEN_NAME=''; PVE_TOKEN_SECRET=''; PVE_NODE=''
        LIFETIME_DAYS='2'; VERIFY_SSL='0'; VM_TEMPLATE_ID=''; VM_NAME_PREFIX='vm'
        VM_CORES='2'; VM_MEMORY='2048'; VM_DISK_GB=''; VM_STORAGE=''; VM_USER='root'
        VM_PASSWORD='docker'; VM_IP_MODE='dhcp'; VM_BRIDGE=''; VM_GUEST_OS='linux'
        VM_CLONE_MODE='full'; VM_CLONE_TIMEOUT='1800'
    }
    foreach ($key in $defaults.Keys) { if (-not $settings.ContainsKey($key)) { $settings[$key] = $defaults[$key] } }
    $missing = @('PVE_HOST','PVE_TOKEN_NAME','PVE_TOKEN_SECRET') | Where-Object { -not $settings[$_] }
    if ($missing.Count) { Fail ('Settings are not finished. Fill in: ' + ($missing -join ', ')) }
    if (-not $settings.VM_TEMPLATE_ID) { Fail 'VM_TEMPLATE_ID is not finished. Enter the numeric VMID of the prepared template in settings.txt.' }
    if ($settings.VM_TEMPLATE_ID -notmatch '^\d+$') { Fail 'VM_TEMPLATE_ID must be a number.' }
    if ($settings.VM_PASSWORD.Length -lt 5) { Fail 'VM_PASSWORD must be at least 5 characters.' }
    $settings.VM_GUEST_OS = $settings.VM_GUEST_OS.ToLowerInvariant()
    if ($settings.VM_GUEST_OS -notin @('linux','windows')) { Fail 'VM_GUEST_OS must be linux or windows.' }
    $settings.VM_CLONE_MODE = $settings.VM_CLONE_MODE.ToLowerInvariant()
    if ($settings.VM_CLONE_MODE -notin @('full','linked')) { Fail 'VM_CLONE_MODE must be full or linked.' }
    if ($settings.VM_CLONE_TIMEOUT -notmatch '^\d+$' -or [long]$settings.VM_CLONE_TIMEOUT -lt 1) {
        Fail 'VM_CLONE_TIMEOUT must be a whole number of at least 1.'
    }
    $script:CloneTimeout = [int]$settings.VM_CLONE_TIMEOUT
    if ($settings.LIFETIME_DAYS -notmatch '^\d+$' -or [long]$settings.LIFETIME_DAYS -lt 1) {
        Fail 'LIFETIME_DAYS must be a whole number of at least 1.'
    }
    if ($settings.VM_DISK_GB -and ($settings.VM_DISK_GB -notmatch '^\d+$' -or [long]$settings.VM_DISK_GB -lt 1)) {
        Fail 'VM_DISK_GB must be empty or a whole number of at least 1.'
    }

    $hostName = ($settings.PVE_HOST -replace '^https?://', '').TrimEnd('/')
    if ($hostName -notmatch ':\d+$') { $hostName += ':8006' }
    $script:Base = "https://$hostName/api2/json"
    $script:Verify = $settings.VERIFY_SSL -in @('1','true','yes','TRUE','YES')
    $script:Headers = @{ Authorization = "PVEAPIToken=$($settings.PVE_USER)!$($settings.PVE_TOKEN_NAME)=$($settings.PVE_TOKEN_SECRET)" }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not $script:Verify) {
        if (-not ('AutoBoxVmTrustAllCertsPolicy' -as [type])) {
            Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class AutoBoxVmTrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
        }
        [Net.ServicePointManager]::CertificatePolicy = New-Object AutoBoxVmTrustAllCertsPolicy
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
    function Wait-Task([string]$Upid, [string]$ProgressMessage = '') {
        $encoded = [uri]::EscapeDataString($Upid)
        $deadline = (Get-Date).AddSeconds($script:CloneTimeout)
        if ($ProgressMessage) { Write-Host $ProgressMessage -NoNewline }
        $elapsed = 0
        while ((Get-Date) -lt $deadline) {
            $task = Invoke-Api GET "/nodes/$script:Node/tasks/$encoded/status"
            if ($task.status -eq 'stopped') {
                if ($task.exitstatus -eq 'OK') {
                    if ($ProgressMessage) { Write-Host '' }
                    return
                }
                $lines = @(Invoke-Api GET "/nodes/$script:Node/tasks/$encoded/log" @{ limit='50' } | ForEach-Object { '    ' + $_.t }) -join "`n"
                Fail "Task failed: $($task.exitstatus)`n$lines"
            }
            Start-Sleep -Seconds 2
            $elapsed += 2
            if ($ProgressMessage -and $elapsed % 4 -eq 0) { Write-Host '.' -NoNewline }
        }
        if ($ProgressMessage) { Write-Host '' }
        Fail "Timed out waiting for task $Upid after $script:CloneTimeout seconds"
    }

    $nodes = @(Invoke-Api GET '/nodes')
    $script:Node = $settings.PVE_NODE
    if (-not $script:Node -and $nodes.Count) { $script:Node = [string]$nodes[0].node }
    if (-not $script:Node) { Fail 'No Proxmox node was found.' }
    $templateId = [int]$settings.VM_TEMPLATE_ID
    try { $templateConfig = Invoke-Api GET "/nodes/$script:Node/qemu/$templateId/config" }
    catch { Fail "Could not read VM_TEMPLATE_ID $templateId. Check that the template exists and the token can read it." }
    if ([string]$templateConfig.template -ne '1') {
        Fail "VM_TEMPLATE_ID $templateId is not a Proxmox VM template. Choose a VM marked as a template."
    }

    $status = Invoke-Api GET "/nodes/$script:Node/status"
    $serverTime = [long]$status.time
    $expiry = $serverTime + ([long]$settings.LIFETIME_DAYS * 86400)
    $expiryDate = [DateTimeOffset]::FromUnixTimeSeconds($expiry).UtcDateTime.ToString('yyyy-MM-dd HH:mm UTC')
    $createdDate = [DateTimeOffset]::FromUnixTimeSeconds($serverTime).UtcDateTime.ToString('yyyy-MM-dd HH:mm UTC')
    $prefix = ($settings.VM_NAME_PREFIX.ToLowerInvariant() -replace '[^a-z0-9-]', '')
    if (-not $prefix) { $prefix = 'vm' }
    $creator = "$env:USERNAME@$env:COMPUTERNAME"
    $description = "AutoBox temporary VM. Created by $creator on $createdDate. Auto-deleted after $expiryDate."
    $tags = "autobox;exp-$expiry"
    $baseId = [int](Invoke-Api GET '/cluster/nextid')
    $vmid = $baseId; $cloned = $false; $cloneUpid = ''

    for ($attempt = 0; $attempt -le 6; $attempt++) {
        $name = "$prefix-$vmid"
        $cloneParams = @{ newid=[string]$vmid; name=$name; full=$(if ($settings.VM_CLONE_MODE -eq 'linked') { '0' } else { '1' }) }
        if ($settings.VM_STORAGE) { $cloneParams.storage = $settings.VM_STORAGE }
        try {
            $cloneUpid = [string](Invoke-Api POST "/nodes/$script:Node/qemu/$templateId/clone" $cloneParams)
            $cloned = $true
            break
        }
        catch {
            $text = $_.Exception.Message
            if ($text -notmatch 'already exists|already in use' -or $attempt -ge 6) { throw }
            $probe = $baseId + (Get-Random -Minimum 0 -Maximum 30)
            if ($probe -eq $vmid) { $probe++ }
            $vmid = [int](Invoke-Api GET '/cluster/nextid' @{ vmid=[string]$probe })
        }
    }
    if (-not $cloned) { Fail 'Could not reserve a free VM ID after 6 retries.' }
    if ($cloneUpid.StartsWith('UPID:')) { Wait-Task $cloneUpid 'Cloning a large disk can take several minutes...' }

    $cloneConfig = Invoke-Api GET "/nodes/$script:Node/qemu/$vmid/config"
    $configParams = @{ cores=$settings.VM_CORES; memory=$settings.VM_MEMORY; agent='1'; tags=$tags; description=$description }
    if ($settings.VM_GUEST_OS -eq 'linux') {
        $configParams.ciuser = $settings.VM_USER
        $configParams.cipassword = $settings.VM_PASSWORD
        $configParams.ipconfig0 = "ip=$($settings.VM_IP_MODE)"
    }
    if ($settings.VM_BRIDGE) { $configParams.net0 = "virtio,bridge=$($settings.VM_BRIDGE)" }
    $configResult = Invoke-Api PUT "/nodes/$script:Node/qemu/$vmid/config" $configParams
    if ($configResult -is [string] -and $configResult.StartsWith('UPID:')) { Wait-Task $configResult }

    if ($settings.VM_DISK_GB) {
        $match = [regex]::Match([string]$cloneConfig.scsi0, '(?:^|,)size=(\d+)G(?:,|$)')
        if (-not $match.Success) {
            Write-Host 'NOTE: could not read current scsi0 size; disk resize skipped.'
        } elseif ([long]$settings.VM_DISK_GB -gt [long]$match.Groups[1].Value) {
            $resize = Invoke-Api PUT "/nodes/$script:Node/qemu/$vmid/resize" @{ disk='scsi0'; size="$($settings.VM_DISK_GB)G" }
            if ($resize -is [string] -and $resize.StartsWith('UPID:')) { Wait-Task $resize }
        } elseif ([long]$settings.VM_DISK_GB -lt [long]$match.Groups[1].Value) {
            Write-Host 'WARNING: VM_DISK_GB is smaller than the template disk; disk resize skipped.'
        } else {
            Write-Host 'NOTE: requested disk size matches the template disk; resize skipped.'
        }
    }

    $start = Invoke-Api POST "/nodes/$script:Node/qemu/$vmid/status/start"
    if ($start -is [string] -and $start.StartsWith('UPID:')) { Wait-Task $start 'Starting VM...' }
    $ip = ''
    $ipTimeout = if ($settings.VM_GUEST_OS -eq 'windows') { 300 } else { 120 }
    for ($elapsed = 0; $elapsed -lt $ipTimeout -and -not $ip; $elapsed += 5) {
        try {
            $network = Invoke-Api GET "/nodes/$script:Node/qemu/$vmid/agent/network-get-interfaces"
            foreach ($interface in @($network.result)) {
                foreach ($address in @($interface.'ip-addresses')) {
                    if ($address.'ip-address-type' -eq 'ipv4' -and $address.'ip-address' -notmatch '^127\.') {
                        $ip = [string]$address.'ip-address'
                        break
                    }
                }
                if ($ip) { break }
            }
        } catch {}
        if (-not $ip -and $elapsed -lt 115) { Start-Sleep -Seconds 5 }
    }
    Write-Host ''
    Write-Host '+----------------------------------------------------------+'
    Write-Host (('| VM:        {0,-48} |' -f "$name (ID $vmid)"))
    if ($ip) { Write-Host (('| IP:        {0,-48} |' -f $ip)) } else { Write-Host '| IP:        still starting - the first boot can take a few minutes, ask the owner |' }
    Write-Host (('| User:      {0,-48} |' -f $settings.VM_USER))
    Write-Host (('| Password:  {0,-48} |' -f $settings.VM_PASSWORD))
    Write-Host (('| Delete:    {0,-48} |' -f $expiryDate))
    Write-Host '+----------------------------------------------------------+'
    if ($settings.VM_GUEST_OS -eq 'windows') {
        Write-Host 'Windows credentials must already exist inside the template.'
        if (-not $ip) { Write-Host 'No IP appeared; install qemu-guest-agent from the virtio-win ISO in the template.' }
    }
}
catch {
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
    if ($_.Exception.Message -notmatch '^The Proxmox token|^HTTP 401|^HTTP 403') {
        [Console]::Error.WriteLine('Send the text above to the owner.')
    }
    exit 1
}
