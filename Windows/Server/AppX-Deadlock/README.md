README.md v1.0.0 (Last Rev: 2026-10-28)

# AppX-Deadlock

## Overview

Prevents, and checks for, the AppX Deployment Service (`AppXSvc`) and
Service Control Manager deadlock on Windows Server 2019, 2022 and 2025.

**What it looks like when it hits:**

- The local console goes black (or spins on "Restarting...") and will not
  wake or unlock.
- RDP connections hang on a black or initializing screen.
- Scheduled or `Restart-Computer` reboots log event 1074 ("has initiated the
  restart") but the OS never shuts down (no event 6006 or 13) until the
  server is hard reset.
- Ping still answers, and PowerShell or WinRM sessions that were already
  open keep working.

**Why it happens:** `AppXSvc` ends up on Automatic (`Start = 2`) instead of
its Windows default of Manual, trigger start (`Start = 3`). This comes from
the OS image or servicing, not from anyone changing it: there is no event
7040 for it. Around midnight the Store and license scheduled tasks
(`InstallService`, `ClipSVC`, `LicenseManager`) wake up to check provisioned
apps, which starts the Microsoft Account Sign-in Assistant (`wlidsvc`) and the
Geolocation Service (`lfsvc`). On a domain-joined server where Group Policy
blocks Microsoft accounts ("Accounts: Block Microsoft accounts",
`NoConnectedUser = 3`), `wlidsvc` hangs in StopPending while `AppXSvc` hangs
in StartPending, with every worker thread waiting on `LpcReply` or
`EventPairLow` (an ALPC deadlock). `AppXSvc` runs as a protected process, so
not even an elevated `Stop-Process -Force` can kill it. Winlogon, the Service
Control Manager and the shell all call `AppXSvc` at logon, unlock, RDP connect
and shutdown, so all of those wait on it forever.

A related problem makes it worse on RDS hosts: every RDP logon creates
per-user app firewall rules, which are never removed at logoff unless
`DeleteUserAppContainersOnLogoff` is set. Once thousands pile up, `AppXSvc`
is slow or hangs on every logon and reboot.

It has also been seen with `AppXSvc` on Automatic on a current Windows 11
build, so the tool can be run on clients too (`-AllowClient`).

## Files

- **Repair-AppxDeadlock.ps1** - applies the settings below, or reports on
  them with `-Status`. Each setting is checked first and written only if it
  differs, so re-running it changes nothing.

| Setting | Value |
| --- | --- |
| `wlidsvc`, `lfsvc`, `XblAuthManager`, `XblGameSave`, `XboxNetApiSvc`, `XboxGipSvc` | Disabled and stopped (only those present) |
| `AppXSvc` | Manual (`Start = 3`) when it is on Automatic. Not stopped if running. Left alone and noted if Disabled. |
| `HKLM\SOFTWARE\Policies\Microsoft\WindowsStore` | `AutoDownload = 2`, `DisableOSUpgrade = 1` |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent` | `DisableWindowsConsumerFeatures = 1` |
| Scheduled tasks under `\Microsoft\Windows\InstallService\` and `\Microsoft\XblGameSave\` | Disabled |
| `...\SharedAccess\Parameters\FirewallPolicy` | `DeleteUserAppContainersOnLogoff = 1` |
| `HKLM\SYSTEM\CurrentControlSet\Control\WaitToKillServiceTimeout` | Lowered to 10000 ms if higher; never raised |

It also prints a health report: any service stuck in StartPending or
StopPending, and how many rules the firewall rule registry keys hold (flagged
above 2000).

| Parameter | Meaning |
| --- | --- |
| `-Status` | Check and report only. Does not need elevation. |
| `-SkipShutdownTimeout` | Leave `WaitToKillServiceTimeout` alone. Use on Hyper-V hosts and SQL Server, where a short timeout can cut off VMs or databases that are still shutting down. `Server-Setup` passes this automatically on those roles. |
| `-ShutdownTimeoutMs N` | The timeout ceiling, 2000 to 60000 ms (default 10000). |
| `-AllowClient` | Run on a Windows client OS. |

## Quick Start

On an existing server, from an elevated PowerShell, download the script and
check it first:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Windows/Server/AppX-Deadlock/Repair-AppxDeadlock.ps1" -OutFile "$env:TEMP\Repair-AppxDeadlock.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\Repair-AppxDeadlock.ps1" -Status
```

Then apply it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\Repair-AppxDeadlock.ps1"
```

Add `-SkipShutdownTimeout` on a Hyper-V host or SQL server. Then reboot.

On a new server you do not need to run it by hand: `Windows/Server/Server-Setup`
runs it as its first step.

## After Install Configuration

### Rebooting

The service start types take full effect at the next boot. Reboot when
convenient.

**If `AppXSvc` is already stuck** (the health report says so in red), the
next reboot will hang one last time, because the stuck process cannot be
killed. Apply the settings, then do one hard reset (power button, or reset
from the hypervisor). Every reboot after that completes normally.

### Applying It Across a Domain With Group Policy

The settings can also be pushed to every member server from the GPO that
already holds server-wide settings:

- **Services** (Computer Configuration > Preferences > Control Panel
  Settings > Services): `wlidsvc` Disabled, `lfsvc` Disabled, `AppXSvc`
  Manual.
- **Registry** preference items, or the matching Administrative Templates,
  for the Store, consumer features and `DeleteUserAppContainersOnLogoff`
  values above.

This tool and Group Policy do not conflict as long as they agree. If a GPO
sets one of these services to a different start type, the GPO wins at the
next refresh and `-Status` reports it as drift.

### Calling From Another Script

Run it as its own process so its `exit` cannot end the caller:

```powershell
$p = Start-Process powershell.exe -Wait -PassThru -NoNewWindow -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\path\to\Repair-AppxDeadlock.ps1'
if ($p.ExitCode -ne 0) { throw "AppX deadlock fix failed (exit $($p.ExitCode))" }
```

It never prompts. The last line printed is `RESULT: changed`,
`RESULT: unchanged`, `RESULT: compliant`, `RESULT: drift` or `RESULT: failed`.

## Troubleshooting

| Exit code | Meaning |
| --- | --- |
| 0 | Success: changes applied, nothing needed changing, or `-Status` found everything compliant |
| 1 | Runtime failure: not elevated, or a setting could not be written (the `[failed]` line says which) |
| 2 | Invalid parameters, or not Windows Server 2019 or later; nothing was touched |
| 3 | `-Status` only: one or more settings are not compliant |

**Diagnostics to run by hand** when a server shows the symptoms above:

```powershell
# Services stuck in a pending state
Get-CimInstance Win32_Service | Where-Object { $_.State -ne 'Running' -and $_.State -ne 'Stopped' } |
    Select-Object Name, DisplayName, State, ProcessId, StartMode

# Thread wait reasons of the stuck services (LpcReply / EventPairLow = the deadlock)
$stuck = (Get-CimInstance Win32_Service | Where-Object { $_.State -ne 'Running' -and $_.State -ne 'Stopped' }).ProcessId | Select-Object -Unique
foreach ($id in $stuck) { if ($id -gt 0) { (Get-Process -Id $id).Threads | Select-Object Id, ThreadState, WaitReason } }

# Reboots that started (1074) but never shut down (no 6006 / 13 after them)
Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1074, 6005, 6006, 12, 13, 41 } -MaxEvents 20 |
    Select-Object TimeCreated, Id, ProviderName, Message

# Did anything change AppXSvc's start type? (no result = it came from the image or servicing)
Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7040 } |
    Where-Object { $_.Message -match 'AppX' }
```

**"... is disabled, but it did not stop within 20 seconds"** - the service is
itself hung. It is already disabled, so it stays stopped after the next
reboot (which may need a hard reset, see Rebooting).

**A setting keeps coming back as drift** - Group Policy is setting it.
`gpresult /h report.html` shows which GPO; change it there.

**FirewallRules holds thousands of rules** - with
`DeleteUserAppContainersOnLogoff = 1`, new per-user rules are removed at
logoff from now on. Rules already there are not removed by this tool.

This tool writes no log of its own. When run by `Server-Setup`, its output is
in that run's log.
