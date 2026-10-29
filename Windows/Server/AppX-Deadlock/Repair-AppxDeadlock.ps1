<#
.SYNOPSIS
    Repair-AppxDeadlock.ps1

.DESCRIPTION
    Applies, or with -Status only checks, the settings that prevent the
    AppX Deployment Service (AppXSvc) and Service Control Manager deadlock
    seen on Windows Server 2019, 2022 and 2025.

    The failure: AppXSvc is left on Automatic instead of its Windows default
    of Manual (trigger start). Scheduled Store and license tasks wake up
    around midnight, start the Microsoft Account Sign-in Assistant (wlidsvc)
    and the Geolocation Service (lfsvc), and on a domain-joined server that
    blocks Microsoft accounts the ALPC calls between them and AppXSvc never
    return. AppXSvc sits in StartPending, and because it runs as a protected
    process it cannot be killed. From then on every reboot, console unlock
    and RDP logon waits on it forever: the screen goes black, scheduled
    reboots log event 1074 but never shut down, and only ping and already
    open remote PowerShell sessions keep working.

    What it sets (each one is checked first and only written if it differs):
      - wlidsvc, lfsvc and the Xbox services (XblAuthManager, XblGameSave,
        XboxNetApiSvc, XboxGipSvc) disabled and stopped, where present.
      - AppXSvc back to Manual (Start = 3) if it is set to Automatic.
      - Store policy: no automatic app downloads, no OS upgrade offers.
      - Consumer features (suggested apps) off.
      - The \Microsoft\Windows\InstallService\ and \Microsoft\XblGameSave\
        scheduled tasks disabled.
      - DeleteUserAppContainersOnLogoff = 1, so per-user app firewall rules
        are removed at logoff instead of piling up (worst on RDS hosts).
      - WaitToKillServiceTimeout lowered to -ShutdownTimeoutMs (default 10000)
        if it is higher. It is never raised. -SkipShutdownTimeout leaves it
        alone, which is right for Hyper-V hosts and SQL Server.

    It also reports any service stuck in StartPending or StopPending and the
    size of the firewall rule registry keys.

    UNATTENDED USE: run it as its own process so the exit code is captured:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File Repair-AppxDeadlock.ps1
    It never prompts. The last line printed is "RESULT: changed",
    "RESULT: unchanged", "RESULT: compliant", "RESULT: drift" or
    "RESULT: failed".

    Exit codes:
      0  success (changes applied, nothing needed changing, or -Status found
         everything compliant)
      1  runtime failure (not elevated, or a setting could not be written)
      2  invalid parameters, or not Windows Server 2019 or later; nothing
         was touched
      3  -Status only: one or more settings are not compliant

.PARAMETER Status
    Check every setting and report, change nothing.

.PARAMETER SkipShutdownTimeout
    Leave WaitToKillServiceTimeout alone.

.PARAMETER ShutdownTimeoutMs
    The WaitToKillServiceTimeout ceiling in milliseconds (2000 - 60000,
    default 10000). A higher current value is lowered to this.

.PARAMETER AllowClient
    Run on a Windows client OS (normally refused; the tool targets Server).

.NOTES
    Version: v1.0.0
    Last Edit Date: 2026-10-28

    CHANGELOG:
      v1.0.0 - Initial release.
#>

[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$SkipShutdownTimeout,
    [int]$ShutdownTimeoutMs = 10000,
    [switch]$AllowClient
)

$ScriptVersion = 'v1.0.0'
$ErrorActionPreference = 'Stop'

$DisableServices = @('wlidsvc', 'lfsvc', 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc')
$DisableTaskPaths = @('\Microsoft\Windows\InstallService\', '\Microsoft\XblGameSave\')
$ServicesRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'
$FirewallPolicyKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy'
$FirewallRuleWarnThreshold = 2000

# ==========================================================================
# Helpers
# ==========================================================================
function Write-Step([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "  [ok]      $Message" -ForegroundColor Green }
function Write-Changed([string]$Message) { Write-Host "  [changed] $Message" -ForegroundColor Yellow }
function Write-Drift([string]$Message) { Write-Host "  [drift]   $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "  [failed]  $Message" -ForegroundColor Red }
function Write-Note([string]$Message) { Write-Host "  [note]    $Message" -ForegroundColor Gray }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RegValue([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return $item.$Name
}

function Set-RegValue([string]$Path, [string]$Name, $Value, [string]$Type) {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# Stop without blocking forever: a service caught in the deadlock never
# reaches Stopped, and Stop-Service would wait on it indefinitely.
function Stop-ServiceBounded([string]$Name, [int]$TimeoutSeconds = 20) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $svc -or $svc.Status -eq 'Stopped') { return $true }
    try {
        $svc.Stop()
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($TimeoutSeconds))
        return $true
    } catch {
        return $false
    }
}

# Each check has a description, a Test that returns $true when compliant,
# and a Fix that makes it compliant. -Status runs only the Tests. Both get
# the check's Data hashtable as their only argument (rather than being
# closures, which would lose sight of the helper functions above).
$Checks = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$Description, [hashtable]$Data, [scriptblock]$Test, [scriptblock]$Fix) {
    $Checks.Add([pscustomobject]@{ Description = $Description; Data = $Data; Test = $Test; Fix = $Fix })
}

# ==========================================================================
# Parameter and platform checks (before anything is touched)
# ==========================================================================
if ($ShutdownTimeoutMs -lt 2000 -or $ShutdownTimeoutMs -gt 60000) {
    Write-Host "ERROR: -ShutdownTimeoutMs must be between 2000 and 60000 (got $ShutdownTimeoutMs)." -ForegroundColor Red
    Write-Host 'RESULT: failed'
    exit 2
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
if ([int]$os.BuildNumber -lt 17763) {
    Write-Host "ERROR: $($os.Caption) (build $($os.BuildNumber)) is older than Windows Server 2019 (build 17763)." -ForegroundColor Red
    Write-Host 'RESULT: failed'
    exit 2
}
if ($os.ProductType -eq 1 -and -not $AllowClient) {
    Write-Host "ERROR: $($os.Caption) is a client OS. This tool targets Windows Server; pass -AllowClient to run it anyway." -ForegroundColor Red
    Write-Host 'RESULT: failed'
    exit 2
}
if (-not $Status -and -not (Test-IsAdmin)) {
    Write-Host 'ERROR: run this from an elevated (Administrator) PowerShell.' -ForegroundColor Red
    Write-Host 'RESULT: failed'
    exit 1
}

$mode = 'apply'
if ($Status) { $mode = 'status (no changes)' }
Write-Host "Repair-AppxDeadlock.ps1 $ScriptVersion on $env:COMPUTERNAME - $($os.Caption) build $($os.BuildNumber), mode: $mode"
Write-Host ''

# ==========================================================================
# Checks
# ==========================================================================
foreach ($name in $DisableServices) {
    $key = Join-Path $ServicesRoot $name
    if (-not (Test-Path -LiteralPath $key)) { continue }
    Add-Check "Service $name disabled and stopped" @{ Name = $name; Key = $key } {
        param($d)
        $svc = Get-Service -Name $d.Name -ErrorAction SilentlyContinue
        ((Get-RegValue $d.Key 'Start') -eq 4) -and ($null -eq $svc -or $svc.Status -eq 'Stopped')
    } {
        param($d)
        # The registry write is used instead of Set-Service because it also
        # works on services whose security descriptor rejects a config change
        # through the Service Control Manager.
        Set-RegValue $d.Key 'Start' 4 'DWord'
        if (-not (Stop-ServiceBounded $d.Name)) {
            throw "disabled, but it did not stop within 20 seconds; it stays stopped after the next reboot"
        }
    }
}

$appxKey = Join-Path $ServicesRoot 'AppXSvc'
if (Test-Path -LiteralPath $appxKey) {
    Add-Check 'AppXSvc on Manual (trigger start), not Automatic' @{ Key = $appxKey } {
        param($d)
        $start = Get-RegValue $d.Key 'Start'
        if ($start -eq 4) { Write-Note 'AppXSvc is Disabled; left as is, but the Start menu and Settings need it' }
        $start -ne 2
    } {
        param($d)
        # Only the start type changes. A running AppXSvc is left running:
        # stopping it here could be exactly the call that hangs.
        Set-RegValue $d.Key 'Start' 3 'DWord'
    }
}

$policyValues = @(
    @{ Desc = 'Store policy: no automatic app downloads (AutoDownload = 2)'; Key = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; Name = 'AutoDownload'; Value = 2 },
    @{ Desc = 'Store policy: no OS upgrade offers (DisableOSUpgrade = 1)'; Key = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; Name = 'DisableOSUpgrade'; Value = 1 },
    @{ Desc = 'Consumer features off (DisableWindowsConsumerFeatures = 1)'; Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; Value = 1 },
    @{ Desc = 'Per-user app firewall rules removed at logoff (DeleteUserAppContainersOnLogoff = 1)'; Key = $FirewallPolicyKey; Name = 'DeleteUserAppContainersOnLogoff'; Value = 1 }
)
foreach ($pv in $policyValues) {
    Add-Check $pv.Desc $pv {
        param($d)
        (Get-RegValue $d.Key $d.Name) -eq $d.Value
    } {
        param($d)
        Set-RegValue $d.Key $d.Name $d.Value 'DWord'
    }
}

foreach ($taskPath in $DisableTaskPaths) {
    $tasks = @(Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue)
    if ($tasks.Count -eq 0) { continue }
    Add-Check "Scheduled tasks under $taskPath disabled ($($tasks.Count) found)" @{ Path = $taskPath } {
        param($d)
        @(Get-ScheduledTask -TaskPath $d.Path -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' }).Count -eq 0
    } {
        param($d)
        Get-ScheduledTask -TaskPath $d.Path -ErrorAction SilentlyContinue |
            Where-Object { $_.State -ne 'Disabled' } |
            Disable-ScheduledTask | Out-Null
    }
}

if (-not $SkipShutdownTimeout) {
    Add-Check "Service shutdown timeout at most $ShutdownTimeoutMs ms (WaitToKillServiceTimeout)" @{ Key = 'HKLM:\SYSTEM\CurrentControlSet\Control'; Ceiling = $ShutdownTimeoutMs } {
        param($d)
        $cur = Get-RegValue $d.Key 'WaitToKillServiceTimeout'
        $n = 0
        # Only a present value that is higher than the ceiling counts as
        # drift, so this tool lowers the timeout but never raises it.
        ($null -eq $cur) -or (-not [int]::TryParse([string]$cur, [ref]$n)) -or ($n -le $d.Ceiling)
    } {
        param($d)
        Set-RegValue $d.Key 'WaitToKillServiceTimeout' ([string]$d.Ceiling) 'String'
    }
}

# ==========================================================================
# Run
# ==========================================================================
Write-Step 'Settings'
$changed = 0
$drift = 0
$failed = 0
foreach ($check in $Checks) {
    $ok = $false
    try { $ok = [bool](& $check.Test $check.Data) } catch { $ok = $false }
    if ($ok) { Write-Ok $check.Description; continue }
    if ($Status) { Write-Drift $check.Description; $drift++; continue }
    try {
        & $check.Fix $check.Data
        Write-Changed $check.Description
        $changed++
    } catch {
        Write-Fail "$($check.Description): $($_.Exception.Message)"
        $failed++
    }
}

Write-Host ''
Write-Step 'Health report'
$stuck = @(Get-CimInstance -ClassName Win32_Service | Where-Object { $_.State -ne 'Running' -and $_.State -ne 'Stopped' })
if ($stuck.Count -eq 0) {
    Write-Ok 'No service is stuck in a pending state'
} else {
    foreach ($s in $stuck) { Write-Fail "Service $($s.Name) ($($s.DisplayName)) is $($s.State), PID $($s.ProcessId)" }
}
$appxStuck = $stuck | Where-Object { $_.Name -eq 'AppXSvc' }
if ($appxStuck) {
    Write-Host ''
    Write-Host '  AppXSvc is already deadlocked. It cannot be stopped, so the next reboot will hang' -ForegroundColor Red
    Write-Host '  one last time: after this run, do a hard reset (power or hypervisor reset). Reboots' -ForegroundColor Red
    Write-Host '  after that one complete normally.' -ForegroundColor Red
}

foreach ($rel in @('FirewallRules', 'RestrictedServices\AppIso\FirewallRules')) {
    $path = Join-Path $FirewallPolicyKey $rel
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $count = (Get-Item -LiteralPath $path).Property.Count
    if ($count -gt $FirewallRuleWarnThreshold) {
        Write-Fail "$rel holds $count rules (over $FirewallRuleWarnThreshold); logons and AppXSvc starts get slow at this size"
    } else {
        Write-Note "$rel holds $count rules"
    }
}

Write-Host ''
if ($Status) {
    if ($drift -gt 0) {
        Write-Host "$drift setting(s) not compliant. Run without -Status to fix them."
        Write-Host 'RESULT: drift'
        exit 3
    }
    Write-Host 'RESULT: compliant'
    exit 0
}
if ($failed -gt 0) {
    Write-Host "$failed setting(s) could not be applied; $changed changed."
    Write-Host 'RESULT: failed'
    exit 1
}
if ($changed -gt 0) {
    Write-Host "$changed setting(s) changed. They take full effect after the next reboot."
    Write-Host 'RESULT: changed'
    exit 0
}
Write-Host 'RESULT: unchanged'
exit 0
