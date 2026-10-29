<#
.SYNOPSIS
    Setup-WindowsServer.ps1

.DESCRIPTION
    Baseline provisioning for a freshly installed Windows Server 2019, 2022
    or 2025, so every new server starts from the same known-good state. Works
    on domain controllers, RDS session hosts, Hyper-V hosts, SQL and other
    application servers, and Server Core. The role is detected and the few
    steps that are not safe for a role are adjusted automatically.

    Steps, in order (each is idempotent and has a -Skip switch):
      1. AppX deadlock prevention, through ..\AppX-Deadlock\Repair-AppxDeadlock.ps1.
         On Hyper-V hosts and SQL servers the service shutdown timeout is
         left alone, since VMs and databases need time to shut down cleanly.
      2. Time zone (default Eastern Standard Time).
      3. Time synchronization, through ..\..\NTP-Config\Configure-NtpConfig.ps1
         -TimeSource Default: the domain hierarchy on members, an external
         source on standalone servers and the forest root PDC emulator.
      4. Server Manager no longer opens at logon (Desktop Experience only).
      5. Event logs: Application and System at least 64 MB, Security at least
         256 MB (1 GB on a domain controller). Logs are only ever grown, and
         a log whose size is set by Group Policy is left alone.
      6. High Performance power plan.
      7. Inbound ping (ICMPv4 echo) allowed on the Domain and Private
         firewall profiles, through one rule named MVTS-ICMPv4-Echo-In.
    Opt-in steps:
      -EnableRdp               Remote Desktop on, Network Level Authentication
                               required, built-in Remote Desktop firewall rules on.
      -DisableShutdownTracker  No "why did the computer shut down" prompt at logon.

    Nothing reboots the server. The AppX settings take full effect after the
    next reboot, and the final summary says so.

    Every run is logged (a PowerShell transcript) to -LogDir, default
    %ProgramData%\MVTS\Server-Setup\Logs, kept 180 days.

    Exit codes:
      0  success
      1  failure (not elevated, or a required step failed)
      2  invalid parameters, unsupported OS, or a prompt with no terminal
         (pass -Yes); nothing was touched
      3  completed, but one or more steps are flagged for review in the
         final summary

.PARAMETER Yes
    Do not show the plan or ask "Proceed?". Required when there is no terminal.

.PARAMETER TimeZone
    Windows time zone ID (see Get-TimeZone -ListAvailable). Default
    "Eastern Standard Time".

.PARAMETER NtpTimeSource
    Passed to Configure-NtpConfig.ps1 -TimeSource: Default, Windows, UsaPool,
    Preferred, or DomainHierarchy. Default "Default".

.PARAMETER EnableRdp
    Turn on Remote Desktop with Network Level Authentication.

.PARAMETER DisableShutdownTracker
    Turn off the Shutdown Event Tracker prompt (ShutdownReasonOn = 0).

.PARAMETER LogDir
    Folder for run logs. Default %ProgramData%\MVTS\Server-Setup\Logs.

.NOTES
    Version: v1.0.0
    Last Edit Date: 2026-10-28

    CHANGELOG:
      v1.0.0 - Initial release.
#>

[CmdletBinding()]
param(
    [switch]$Yes,
    [string]$TimeZone = 'Eastern Standard Time',
    [ValidateSet('Default', 'Windows', 'UsaPool', 'Preferred', 'DomainHierarchy')]
    [string]$NtpTimeSource = 'Default',
    [switch]$EnableRdp,
    [switch]$DisableShutdownTracker,
    [switch]$SkipAppx,
    [switch]$SkipTimeZone,
    [switch]$SkipNtp,
    [switch]$SkipServerManager,
    [switch]$SkipEventLogs,
    [switch]$SkipPowerPlan,
    [switch]$SkipPing,
    [string]$LogDir
)

$ScriptVersion = 'v1.0.0'
$ErrorActionPreference = 'Stop'
$LogRetentionDays = 180
$HighPerformanceGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$PingRuleName = 'MVTS-ICMPv4-Echo-In'
# The Remote Desktop rule group by its resource ID, which does not change
# with the OS display language the way the group's display name does.
$RdpRuleGroup = '@FirewallAPI.dll,-28752'

$AppxScript = Join-Path (Split-Path -Parent $PSScriptRoot) (Join-Path 'AppX-Deadlock' 'Repair-AppxDeadlock.ps1')
$NtpScript = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) (Join-Path 'NTP-Config' 'Configure-NtpConfig.ps1')

$Results = New-Object System.Collections.Generic.List[object]

# ==========================================================================
# Helpers
# ==========================================================================
function Write-Step([string]$Message) { Write-Host ''; Write-Host "== $Message" -ForegroundColor Cyan }
function Write-Info([string]$Message) { Write-Host "   $Message" }
function Write-Warn([string]$Message) { Write-Host "   WARNING: $Message" -ForegroundColor Yellow }

# Outcome is one of: changed, unchanged, skipped, flagged.
function Add-Result([string]$Step, [string]$Outcome, [string]$Detail = '') {
    $Results.Add([pscustomobject]@{ Step = $Step; Outcome = $Outcome; Detail = $Detail })
    $color = 'Gray'
    if ($Outcome -eq 'changed') { $color = 'Yellow' }
    if ($Outcome -eq 'unchanged') { $color = 'Green' }
    if ($Outcome -eq 'flagged') { $color = 'Red' }
    $line = "   -> $Outcome"
    if ($Detail) { $line += ": $Detail" }
    Write-Host $line -ForegroundColor $color
}

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

# Writes the value only if it differs. Returns $true when it wrote.
function Set-RegValueIfDifferent([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    if ((Get-RegValue $Path $Name) -eq $Value) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    return $true
}

# Runs a sibling tool as its own process (so its exit statement cannot end
# this script) and indents its output into this run's transcript. Returns
# its exit code and the word from its last "RESULT: <word>" line, if any.
function Invoke-ChildScript([string]$Path, [string[]]$Arguments) {
    $exe = (Get-Process -Id $PID).Path
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $result = ''
    try {
        & $exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | ForEach-Object {
            $line = [string]$_
            Write-Host "   | $line"
            if ($line -match '^RESULT:\s*(\S+)') { $result = $Matches[1] }
        }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Result = $result }
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

# ==========================================================================
# Parameter and platform checks (before anything is touched)
# ==========================================================================
function Stop-Invalid([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 2
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
if ($os.ProductType -eq 1) { Stop-Invalid "$($os.Caption) is a client OS. This script is for Windows Server." }
if ([int]$os.BuildNumber -lt 17763) { Stop-Invalid "$($os.Caption) (build $($os.BuildNumber)) is older than Windows Server 2019 (build 17763)." }
if (-not $SkipTimeZone -and -not (Get-TimeZone -ListAvailable | Where-Object { $_.Id -eq $TimeZone })) {
    Stop-Invalid "'$TimeZone' is not a Windows time zone ID. List them with: Get-TimeZone -ListAvailable | Select-Object Id"
}
if (-not $SkipAppx -and -not (Test-Path -LiteralPath $AppxScript)) {
    Stop-Invalid "Repair-AppxDeadlock.ps1 was not found at $AppxScript. Run this from a full copy of the repo (the one-line install does this), or pass -SkipAppx."
}
if (-not (Test-IsAdmin)) {
    Write-Host 'ERROR: run this from an elevated (Administrator) PowerShell.' -ForegroundColor Red
    exit 1
}
if (-not $LogDir) { $LogDir = Join-Path $env:ProgramData (Join-Path 'MVTS' (Join-Path 'Server-Setup' 'Logs')) }

# ==========================================================================
# Role detection
# ==========================================================================
$cs = Get-CimInstance -ClassName Win32_ComputerSystem
$Role = [ordered]@{
    DomainController = ($os.ProductType -eq 2)
    DomainJoined     = [bool]$cs.PartOfDomain
    HyperVHost       = [bool](Get-Service -Name vmms -ErrorAction SilentlyContinue)
    SqlServer        = [bool](Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*' })
    RdsSessionHost   = $false
    ServerCore       = ((Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'InstallationType') -eq 'Server Core')
    VirtualMachine   = ($cs.Model -match 'Virtual|VMware|KVM|QEMU|HVM domU' -or $cs.Manufacturer -match 'QEMU|Xen|VMware|innotek')
}
if (Get-Command -Name Get-WindowsFeature -ErrorAction SilentlyContinue) {
    try { $Role.RdsSessionHost = [bool](Get-WindowsFeature -Name RDS-RD-Server).Installed } catch { $Role.RdsSessionHost = $false }
}
$SkipShutdownTimeout = $Role.HyperVHost -or $Role.SqlServer
$SecurityLogBytes = 256MB
if ($Role.DomainController) { $SecurityLogBytes = 1GB }
$EventLogTargets = [ordered]@{ Application = 64MB; System = 64MB; Security = $SecurityLogBytes }

$roleNames = @()
if ($Role.DomainController) { $roleNames += 'domain controller' } elseif ($Role.DomainJoined) { $roleNames += 'domain member' } else { $roleNames += 'standalone' }
if ($Role.RdsSessionHost) { $roleNames += 'RDS session host' }
if ($Role.HyperVHost) { $roleNames += 'Hyper-V host' }
if ($Role.SqlServer) { $roleNames += 'SQL Server' }
if ($Role.ServerCore) { $roleNames += 'Server Core' }
if ($Role.VirtualMachine) { $roleNames += 'virtual machine' } else { $roleNames += 'physical' }

# ==========================================================================
# Plan and confirmation
# ==========================================================================
$plan = @()
if (-not $SkipAppx) {
    $d = 'AppX deadlock prevention (wlidsvc, lfsvc, Xbox services off; AppXSvc Manual; Store auto-updates off; app firewall rule cleanup at logoff'
    if ($SkipShutdownTimeout) { $d += '; shutdown timeout left alone on this role)' } else { $d += '; service shutdown timeout 10 s)' }
    $plan += $d
}
if (-not $SkipTimeZone) { $plan += "Time zone: $TimeZone" }
if (-not $SkipNtp) {
    if (Test-Path -LiteralPath $NtpScript) { $plan += "Time synchronization through NTP-Config (-TimeSource $NtpTimeSource)" }
    else { $plan += 'Time synchronization: NTP-Config not found next to this script, step will be flagged' }
}
if (-not $SkipServerManager -and -not $Role.ServerCore) { $plan += 'Server Manager does not open at logon' }
if (-not $SkipEventLogs) { $plan += "Event log minimum sizes: Application 64 MB, System 64 MB, Security $([int]($SecurityLogBytes / 1MB)) MB" }
if (-not $SkipPowerPlan) { $plan += 'Power plan: High Performance' }
if (-not $SkipPing) { $plan += "Allow inbound ping on Domain and Private profiles (rule $PingRuleName)" }
if ($EnableRdp) { $plan += 'Remote Desktop on, Network Level Authentication required' }
if ($DisableShutdownTracker) { $plan += 'Shutdown Event Tracker prompt off' }

Write-Host "Setup-WindowsServer.ps1 $ScriptVersion"
Write-Host "Host: $env:COMPUTERNAME - $($os.Caption) build $($os.BuildNumber)"
Write-Host "Role: $($roleNames -join ', ')"
if ($plan.Count -eq 0) { Write-Host 'Every step is skipped; nothing to do.'; exit 0 }

if (-not $Yes) {
    Write-Host ''
    Write-Host 'Plan:'
    for ($i = 0; $i -lt $plan.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $plan[$i]) }
    Write-Host ''
    Write-Host 'Nothing reboots the server or changes its network settings.'
    try { $answer = Read-Host 'Proceed? [y/N]' } catch { Stop-Invalid 'No terminal to answer the prompt. Pass -Yes to run unattended.' }
    if ($answer -notmatch '^(y|yes)$') { Write-Host 'Cancelled; nothing was changed.'; exit 0 }
}

# ==========================================================================
# Logging
# ==========================================================================
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
Get-ChildItem -LiteralPath $LogDir -Filter 'setup-*.log' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } |
    Remove-Item -Force -ErrorAction SilentlyContinue
$LogFile = Join-Path $LogDir ("setup-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
Start-Transcript -LiteralPath $LogFile | Out-Null
Write-Host "Run started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME ($($roleNames -join ', '))"

# ==========================================================================
# Steps
# ==========================================================================
try {
    if (-not $SkipAppx) {
        Write-Step 'AppX deadlock prevention'
        $appxArgs = @()
        if ($SkipShutdownTimeout) {
            $appxArgs += '-SkipShutdownTimeout'
            Write-Info 'Hyper-V or SQL Server detected: the service shutdown timeout is left as it is.'
        }
        $run = Invoke-ChildScript $AppxScript $appxArgs
        if ($run.ExitCode -ne 0) {
            Add-Result 'AppX deadlock prevention' 'flagged' "Repair-AppxDeadlock.ps1 exited $($run.ExitCode)"
        } elseif ($run.Result -eq 'unchanged') {
            Add-Result 'AppX deadlock prevention' 'unchanged' 'already in place'
        } else {
            Add-Result 'AppX deadlock prevention' 'changed' 'applied; reboot to complete'
        }
    }

    if (-not $SkipTimeZone) {
        Write-Step 'Time zone'
        $current = (Get-TimeZone).Id
        if ($current -eq $TimeZone) {
            Add-Result 'Time zone' 'unchanged' $TimeZone
        } else {
            Set-TimeZone -Id $TimeZone
            Add-Result 'Time zone' 'changed' "$current -> $TimeZone"
        }
    }

    if (-not $SkipNtp) {
        Write-Step 'Time synchronization (NTP-Config)'
        if (-not (Test-Path -LiteralPath $NtpScript)) {
            Add-Result 'Time synchronization' 'flagged' "Configure-NtpConfig.ps1 not found at $NtpScript"
        } else {
            $run = Invoke-ChildScript $NtpScript @('-TimeSource', $NtpTimeSource)
            $rc = $run.ExitCode
            switch ($rc) {
                0 {
                    if ($run.Result -eq 'unchanged') { Add-Result 'Time synchronization' 'unchanged' "-TimeSource $NtpTimeSource already in place" }
                    else { Add-Result 'Time synchronization' 'changed' "-TimeSource $NtpTimeSource applied" }
                }
                3 { Add-Result 'Time synchronization' 'flagged' "-TimeSource $NtpTimeSource does not suit this machine's role; nothing changed" }
                4 { Add-Result 'Time synchronization' 'skipped' 'time settings are enforced by Group Policy' }
                default { Add-Result 'Time synchronization' 'flagged' "Configure-NtpConfig.ps1 exited $rc" }
            }
        }
    }

    if (-not $SkipServerManager -and -not $Role.ServerCore) {
        Write-Step 'Server Manager at logon'
        # The same value the "Do not display Server Manager automatically at
        # logon" Group Policy setting writes, so it applies to every user.
        if (Set-RegValueIfDifferent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Server\ServerManager' 'DoNotOpenAtLogon' 1) {
            Add-Result 'Server Manager at logon' 'changed' 'no longer opens at logon'
        } else {
            Add-Result 'Server Manager at logon' 'unchanged' 'already does not open at logon'
        }
    }

    if (-not $SkipEventLogs) {
        Write-Step 'Event log sizes'
        $grown = @()
        foreach ($name in $EventLogTargets.Keys) {
            $target = [long]$EventLogTargets[$name]
            if ($null -ne (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\$name" 'MaxSize')) {
                Write-Info "$name size is set by Group Policy; left alone."
                continue
            }
            $log = Get-WinEvent -ListLog $name
            $mb = [int]($log.MaximumSizeInBytes / 1MB)
            if ($log.MaximumSizeInBytes -ge $target) {
                Write-Info "$name is $mb MB (at least $([int]($target / 1MB)) MB already)."
                continue
            }
            $log.MaximumSizeInBytes = $target
            $log.SaveChanges()
            Write-Info "$name grown from $mb MB to $([int]($target / 1MB)) MB."
            $grown += $name
        }
        if ($grown.Count -gt 0) { Add-Result 'Event log sizes' 'changed' ($grown -join ', ') } else { Add-Result 'Event log sizes' 'unchanged' }
    }

    if (-not $SkipPowerPlan) {
        Write-Step 'Power plan'
        $active = (& powercfg.exe /getactivescheme) -join ' '
        if ($active -match $HighPerformanceGuid) {
            Add-Result 'Power plan' 'unchanged' 'High Performance'
        } else {
            & powercfg.exe /setactive $HighPerformanceGuid | Out-Null
            if ($LASTEXITCODE -ne 0) {
                # Some images ship without the plan; recreate it from its template.
                & powercfg.exe /duplicatescheme $HighPerformanceGuid $HighPerformanceGuid | Out-Null
                & powercfg.exe /setactive $HighPerformanceGuid | Out-Null
            }
            if (((& powercfg.exe /getactivescheme) -join ' ') -match $HighPerformanceGuid) {
                Add-Result 'Power plan' 'changed' 'High Performance'
            } else {
                Add-Result 'Power plan' 'flagged' 'could not activate High Performance (check powercfg /list)'
            }
        }
    }

    if (-not $SkipPing) {
        Write-Step 'Inbound ping'
        $rule = Get-NetFirewallRule -Name $PingRuleName -ErrorAction SilentlyContinue
        if ($null -eq $rule) {
            New-NetFirewallRule -Name $PingRuleName -DisplayName 'MVTS - Allow inbound ping (ICMPv4 echo request)' `
                -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -Profile Domain, Private -Action Allow | Out-Null
            Add-Result 'Inbound ping' 'changed' "rule $PingRuleName created (Domain, Private)"
        } else {
            if ("$($rule.Enabled)" -eq 'True' -and "$($rule.Action)" -eq 'Allow' -and "$($rule.Profile)" -eq 'Domain, Private') {
                Add-Result 'Inbound ping' 'unchanged' "rule $PingRuleName in place"
            } else {
                Set-NetFirewallRule -Name $PingRuleName -Enabled True -Action Allow -Profile Domain, Private
                Add-Result 'Inbound ping' 'changed' "rule $PingRuleName re-enabled (Domain, Private)"
            }
        }
    }

    if ($EnableRdp) {
        Write-Step 'Remote Desktop'
        $c1 = Set-RegValueIfDifferent 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 0
        $c2 = Set-RegValueIfDifferent 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication' 1
        $off = @(Get-NetFirewallRule -Group $RdpRuleGroup -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -ne 'True' })
        if ($off.Count -gt 0) { $off | Enable-NetFirewallRule }
        if ($c1 -or $c2 -or $off.Count -gt 0) { Add-Result 'Remote Desktop' 'changed' 'on, NLA required, firewall rules enabled' }
        else { Add-Result 'Remote Desktop' 'unchanged' 'already on with NLA' }
    }

    if ($DisableShutdownTracker) {
        Write-Step 'Shutdown Event Tracker'
        if (Set-RegValueIfDifferent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' 'ShutdownReasonOn' 0) {
            Add-Result 'Shutdown Event Tracker' 'changed' 'prompt off'
        } else {
            Add-Result 'Shutdown Event Tracker' 'unchanged' 'prompt already off'
        }
    }
} catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -ForegroundColor Red
    Write-Host "Log: $LogFile"
    Stop-Transcript | Out-Null
    exit 1
}

# ==========================================================================
# Summary
# ==========================================================================
Write-Host ''
Write-Host '== Summary' -ForegroundColor Cyan
foreach ($r in $Results) {
    $line = '   {0,-26} {1}' -f $r.Step, $r.Outcome
    if ($r.Detail) { $line += " - $($r.Detail)" }
    Write-Host $line
}
$flagged = @($Results | Where-Object { $_.Outcome -eq 'flagged' })
if ($Role.HyperVHost) {
    Write-Host ''
    Write-Host '   Hyper-V host: run Repair-AppxDeadlock.ps1 inside each Windows Server guest as well; the guests are'
    Write-Host '   affected the same way and this host-level run does not reach them.'
}
if (-not $SkipAppx) {
    Write-Host ''
    Write-Host '   Reboot when convenient so the AppX service changes take full effect.' -ForegroundColor Yellow
}
Write-Host ''
Write-Host "Log: $LogFile"
if ($flagged.Count -gt 0) {
    Write-Host ''
    Write-Host 'FLAGGED FOR REVIEW:' -ForegroundColor Red
    foreach ($f in $flagged) { Write-Host "   $($f.Step): $($f.Detail)" -ForegroundColor Red }
    Stop-Transcript | Out-Null
    exit 3
}
Stop-Transcript | Out-Null
exit 0
