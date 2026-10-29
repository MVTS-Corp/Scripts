README.md v1.0.0 (Last Rev: 2026-10-28)

# Server-Setup (Windows)

## Overview

Baseline provisioning for a freshly installed Windows Server 2019, 2022 or
2025, so every new server starts from the same known-good state instead of
being set up by hand from memory. It works on domain controllers, RDS
session hosts, Hyper-V hosts, SQL and other application servers, both
Desktop Experience and Server Core. It detects the server's role and adjusts
the few steps that are not safe for it, so there is one script for every
kind of server.

Steps, in the order they run:

1. **AppX deadlock prevention**, through
   [`../AppX-Deadlock`](../AppX-Deadlock/README.md). This is the fix for
   servers that stop rebooting, accepting RDP or unlocking the console after
   a midnight Store task deadlocks `AppXSvc`. On Hyper-V hosts and SQL
   servers the service shutdown timeout is left as it is, so VMs and
   databases still get time to shut down cleanly.
2. **Time zone**, default `Eastern Standard Time` (`-TimeZone`).
3. **Time synchronization**, through
   [`../../NTP-Config`](../../NTP-Config/README.md) with `-TimeSource Default`:
   the domain hierarchy on domain members and secondary DCs, an external
   source on standalone servers and the forest root PDC emulator. If Group
   Policy manages time settings, the step is left alone.
4. **Server Manager does not open at logon** (Desktop Experience only), set
   through the same policy value Group Policy uses, so it applies to every
   user.
5. **Event log sizes**: Application and System at least 64 MB, Security at
   least 256 MB (1 GB on a domain controller). Logs are only grown, never
   shrunk, and a log whose size Group Policy sets is left alone.
6. **High Performance power plan.** If the image has no High Performance
   plan, it is recreated from its built-in template.
7. **Inbound ping**: one firewall rule, `MVTS-ICMPv4-Echo-In`, allows ICMPv4
   echo requests on the Domain and Private profiles (not Public), for
   monitoring.

Opt-in steps:

- `-EnableRdp` - Remote Desktop on, Network Level Authentication required,
  and the built-in Remote Desktop firewall rules enabled.
- `-DisableShutdownTracker` - no "why did the computer shut down
  unexpectedly" prompt at logon (`ShutdownReasonOn = 0`). The prompt also
  appears after a perfectly clean restart started from the Settings app,
  because that restart is recorded as unplanned. Turning it off also loses
  the reboot reason it would have recorded.

What the role detection changes:

| Detected | Effect |
| --- | --- |
| Domain controller | Security log minimum 1 GB. NTP-Config picks the right time source for the PDC emulator or a secondary DC. |
| Hyper-V host (`vmms` service) | Shutdown timeout left alone. The summary reminds you to run the AppX fix inside each Windows Server guest too. |
| SQL Server (`MSSQLSERVER` or `MSSQL$*` service) | Shutdown timeout left alone. |
| RDS session host | Nothing extra; the AppX step's firewall rule cleanup at logoff matters most here. |
| Server Core | Server Manager step skipped. |

Every step checks the current state first and changes only what differs, so
re-running the script is safe. Nothing reboots the server or changes its
network configuration.

## Files

- **bootstrap.ps1** - the one-line install entry point. Downloads a snapshot
  of this repo from GitHub as a zip into a new temp folder (no git needed),
  checks that `Setup-WindowsServer.ps1` parses, runs it under Windows
  PowerShell 5.1 with every argument you gave, and deletes the snapshot
  afterward. Its own options: `-Ref <branch or tag>` (default `main`) and
  `-ArchiveUrl <url>` (download from a fork or mirror instead).
- **Setup-WindowsServer.ps1** - the provisioning script itself. It calls
  `..\AppX-Deadlock\Repair-AppxDeadlock.ps1` and
  `..\..\NTP-Config\Configure-NtpConfig.ps1` from the same snapshot as
  separate processes, rather than repeating their logic.

| Parameter | Meaning |
| --- | --- |
| `-Yes` | No plan, no "Proceed?" prompt. Required when there is no terminal (RMM, scheduled task). |
| `-TimeZone ID` | Windows time zone ID (`Get-TimeZone -ListAvailable`). Default `Eastern Standard Time`. |
| `-NtpTimeSource V` | Passed to NTP-Config: `Default`, `Windows`, `UsaPool`, `Preferred`, `DomainHierarchy`. Default `Default`. |
| `-EnableRdp` | Turn on Remote Desktop with NLA. |
| `-DisableShutdownTracker` | Turn off the Shutdown Event Tracker prompt. |
| `-SkipAppx`, `-SkipTimeZone`, `-SkipNtp`, `-SkipServerManager`, `-SkipEventLogs`, `-SkipPowerPlan`, `-SkipPing` | Leave that step out. |
| `-LogDir PATH` | Where run logs go. Default `%ProgramData%\MVTS\Server-Setup\Logs`. |

## Quick Start

From an **elevated** PowerShell on the new server. The interactive form shows
a numbered plan for this server and asks "Proceed?" before changing anything:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Windows/Server/Server-Setup/bootstrap.ps1)))
```

Arguments after the script block go to `Setup-WindowsServer.ps1`. For
example, unattended with Remote Desktop turned on:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Windows/Server/Server-Setup/bootstrap.ps1))) -Yes -EnableRdp
```

The download comes from `raw.githubusercontent.com` and `github.com`, which
use publicly trusted certificates, so no certificate workaround is normally
needed. On a host behind a TLS-inspecting proxy whose CA it does not trust
yet, install that CA into the machine's Trusted Root store first, or clone
the repo on another machine and copy it over (below).

To read the code before running it as Administrator, clone and run it
directly instead:

```powershell
git clone https://github.com/MVTS-Corp/Scripts.git
cd Scripts\Windows\Server\Server-Setup
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-WindowsServer.ps1
```

`Setup-WindowsServer.ps1` needs the rest of the repo next to it (the
`AppX-Deadlock` and `NTP-Config` folders), so copy the whole repo, not just
this folder.

## After Install Configuration

### Reboot

Reboot when convenient after the first run so the AppX service start types
take full effect. If the AppX step reports that `AppXSvc` is already stuck,
that reboot needs a hard reset; see the AppX-Deadlock README.

### Re-Running

Every step compares first and only changes what differs, so the script can
be re-run on a configured server to confirm nothing drifted. A step that has
nothing to do shows as `unchanged` in the summary.

### Hyper-V Guests

Running this on a Hyper-V host does not reach its guests. Run it (or just
`Repair-AppxDeadlock.ps1`) inside each Windows Server guest as well. For
guests that are domain controllers, NTP-Config also reminds you to turn off
the Hyper-V "Time synchronization" integration service for that guest.

### Files It Manages on the Host

| Path | Purpose |
| --- | --- |
| `%ProgramData%\MVTS\Server-Setup\Logs\setup-<timestamp>.log` | Transcript of each run, kept 180 days |
| Firewall rule `MVTS-ICMPv4-Echo-In` | Inbound ping, Domain and Private profiles |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\Server\ServerManager` `DoNotOpenAtLogon` | Server Manager at logon |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Reliability` `ShutdownReasonOn` | Only with `-DisableShutdownTracker` |

The AppX step's registry values are listed in the AppX-Deadlock README.

## Troubleshooting

| Exit code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Failure: not elevated, or a step failed (the error and line number are printed and logged). Also returned by PowerShell itself for an unknown parameter name. |
| 2 | Invalid parameters (for example an unknown time zone), a client OS, an OS older than Server 2019, a missing sibling tool, or a prompt with no terminal (pass `-Yes`). Nothing was touched. |
| 3 | Completed, but one or more steps are listed under "FLAGGED FOR REVIEW" in the summary |

When run through `bootstrap.ps1`, the exit code is left in `$LASTEXITCODE`
(the bootstrap does not call `exit`, since it runs inside your own session),
and a failed download also leaves `1`.

- **Where is the log?** - `%ProgramData%\MVTS\Server-Setup\Logs\`, newest
  `setup-<timestamp>.log`. The output of the AppX and NTP tools is in it too,
  indented with `|`.
- **"Time synchronization: flagged ... does not suit this machine's role"** -
  the `-NtpTimeSource` you passed is refused by NTP-Config for this role (for
  example `DomainHierarchy` on a standalone server). Use `Default`.
- **"Time synchronization: skipped, enforced by Group Policy"** - not an
  error. Change time settings in the GPO.
- **"Power plan: flagged"** - run `powercfg /list`; some hardened images
  remove the plans and block recreating them.
- **"Repair-AppxDeadlock.ps1 was not found"** - the script was copied without
  the rest of the repo. Use the one-liner, or copy the whole repo.
- **Hangs at "Proceed?" in an RMM or remote session** - there is nobody to
  answer it. Pass `-Yes`.
