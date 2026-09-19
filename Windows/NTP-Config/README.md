README.md v2.2.0 (Last Rev: 2026-09-18)

# Windows NTP Config

## Overview

Interactive tool to view and configure Windows time synchronization
(w32time) on:

- Standalone / workgroup clients and servers
- Domain-joined clients and member servers
- Domain Controllers (PDC emulator and secondary DCs)
- Hyper-V hosts

It replaces per-distro time source lists (the Linux tool's approach) with
Windows' own default (`time.windows.com`) plus an NTP Pool USA option and
the same "Preferred servers" set used on the Linux side
(`time.cloudflare.com`, `us.pool.ntp.org`, `time.nist.gov`), so both
platforms offer the same preferred upstream sources.

**Domain-aware defaults:**

- **Not domain-joined** - operator picks an explicit upstream time source
  (Windows default, NTP Pool USA, Preferred, or Custom).
- **Domain-joined, not a DC** - defaults to the domain hierarchy (syncing
  from the nearest domain controller), which is what Windows already does
  on its own and is almost always correct. The operator can override this
  with an explicit source, with a warning that doing so is atypical.
- **Domain Controller, PDC emulator of the forest root domain** - defaults
  to an explicit external time source, per Microsoft's guidance, since
  it's the authoritative time source for the whole forest. Also marks
  itself as a reliable time source (`/reliable:yes`).
- **Domain Controller, PDC emulator of a child domain** - defaults to the
  domain hierarchy instead (following its parent, which eventually reaches
  the forest root), since only the forest root's PDC emulator should sync
  externally - a child-domain PDC emulator overriding to an external
  source becomes its own disconnected time island. The operator can still
  override to an explicit external source, with a warning.
- **Domain Controller, not the PDC emulator** - defaults to the domain
  hierarchy like a normal member, so it does not become a second,
  independent time island inside the domain. Overriding this is possible
  but flagged as atypical.
- **Hyper-V host** - treated like whatever role above applies to it
  (standalone server, domain member, or DC). If detected, the tool adds a
  reminder that any guest VM which is itself a domain controller should
  have the Hyper-V "Time synchronization" integration service disabled
  inside the guest, since it can otherwise fight with that guest's own
  domain-hierarchy sync.

**Group Policy enforcement:** if Group Policy is managing Windows Time
Service settings on this machine (Computer Configuration > Administrative
Templates > System > Windows Time Service > Time Providers), the tool
detects this by checking for the corresponding
`HKLM:\SOFTWARE\Policies\Microsoft\W32Time\...` registry keys GPO writes.
When present, the tool shows the enforced values and refuses to make any
local configuration change, since a background policy refresh would just
overwrite it again. Change the GPO instead.

The tool installs itself via an HTTPS zip download (no git required - a
domain controller or hardened member server should not need a dev tool
like Git for Windows installed just for this) and checks for and applies
its own updates on every run. There are no scheduled tasks involved
anywhere in this tool. All Windows components it relies on (w32time, the
NetSecurity module for firewall rules, and Microsoft.PowerShell.Archive for
`Expand-Archive`) ship with Windows itself, so there is no
dependency-install step like the Linux tool's chrony install.

The Linux equivalent lives in [Linux/NTP-Config](../../Linux/NTP-Config/README.md).

## Files

- **Install-NtpConfig.ps1** - bootstrap installer. Downloads the repo from
  GitHub as a zip archive (GitHub cannot serve a single subfolder as an
  archive, so the whole repo is downloaded) but installs only the
  *contents* of `Windows\NTP-Config`, flattened directly into
  `C:\DATA\Tools\NTP-Config` (override with `-InstallDir`). Verifies
  `Configure-NtpConfig.ps1` with a syntax check before it is ever placed
  where operators will run it, and adds the install directory to the
  machine `PATH` so it can be run from any elevated PowerShell prompt as
  `Configure-NtpConfig.ps1`. Parameters: `-Repo`, `-Ref`, `-InstallDir`,
  `-Insecure`, `-CaCertPath`.
- **Configure-NtpConfig.ps1** - the interactive tool itself. Menu options
  (when not Group Policy-managed): view current configuration, configure
  time source(s) (role-aware, see above), configure the NTP server role
  and allowed subnets (adding/removing/replacing a subnet automatically
  creates or revokes the matching Windows Firewall rule for it), apply
  changes and restart `w32time` (auto-restores the last backup and
  retries if the service fails to come up on the new config). Run with
  `-NoUpdate` (or set `NTP_SKIP_SELF_UPDATE=1`) to skip the self-update
  check for a single run, useful when testing an in-progress change to
  the script itself. It can also run unattended (`-TimeSource`,
  `-AllowSubnet`) or just report with `-Status`; see Calling From Another
  Script.
- **runme.cmd** - double-click launcher for `Configure-NtpConfig.ps1`.
  Re-launches itself elevated (UAC prompt) if not already running as
  Administrator, then runs the tool from whatever folder it lives in -
  useful for an operator working from Explorer instead of an elevated
  PowerShell prompt, and does not require the install directory to be on
  the PATH.
- **.ntp-config-state.json** (in the install directory) - written by the
  installer. Holds `Repo`, `Ref`, `TlsMode` (`Default`, `Insecure`, or
  `Cacert`) and `CaCertPath` for update checks. Validated before every use.

`Install-NtpConfig.ps1` and `Configure-NtpConfig.ps1` each carry their own
version number in their header; check the header of the specific script for
its version and changelog.

## Quick Start

The installer downloads from `github.com` and `raw.githubusercontent.com`,
which present publicly trusted certificates, so on most hosts no TLS options
are needed. The initial download of `Install-NtpConfig.ps1` and the zip
download it runs internally are two independent TLS handshakes, so a host
that needs a TLS workaround needs it in both places; `-Insecure` and
`-CaCertPath` handle the second, and the saved choice covers later updates.

**Without any certificate workaround (normal case), from an elevated
PowerShell prompt:**

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/MVTS-Corp/Scripts/stable/Windows/NTP-Config/Install-NtpConfig.ps1" -OutFile "$env:TEMP\Install-NtpConfig.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\Install-NtpConfig.ps1"
```

**With a certificate workaround** (for a host behind a TLS-inspecting proxy
whose CA the host does not trust yet; pick one):

```powershell
# Correct long-term option - verify TLS against your organization's CA.
# Obtain the CA certificate (PEM/CER, the CA itself rather than the server
# certificate) from whoever runs the proxy.
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\Install-NtpConfig.ps1" -CaCertPath "C:\path\to\ca.cer"
```

```powershell
# Quick / trusted network only - skips TLS verification entirely
[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/MVTS-Corp/Scripts/stable/Windows/NTP-Config/Install-NtpConfig.ps1" -OutFile "$env:TEMP\Install-NtpConfig.ps1"
[Net.ServicePointManager]::ServerCertificateValidationCallback = $null

powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\Install-NtpConfig.ps1" -Insecure
```

For the `-CaCertPath` form, `Install-NtpConfig.ps1` has to be on the host
already (copy it over, or fetch it on another machine); the download itself
is the step that cannot verify TLS without the CA.

The TLS choice made on first install is saved into
`C:\DATA\Tools\NTP-Config\.ntp-config-state.json` (a CA file passed with
`-CaCertPath` is copied to `C:\DATA\Tools\NTP-Config\ca-cert.pem`), so it
does not need to be supplied again for later updates.

Once installed, run it from any elevated PowerShell prompt:

```powershell
Configure-NtpConfig.ps1
```

Or double-click `C:\DATA\Tools\NTP-Config\runme.cmd`, which self-elevates
(UAC prompt) if needed.

## After Install Configuration

### Updating

Nothing to do manually. On every run, `Configure-NtpConfig.ps1`:

1. Downloads the published copy of itself (one small file) and reads its
   version. If that version is not strictly newer than the running one it
   stops here; an older or equal published version is never applied.
2. Otherwise downloads the repo as a zip archive and extracts it to a temp
   folder, and confirms the archive holds the same version that was just
   checked.
3. Runs a syntax check (`[System.Management.Automation.Language.Parser]::ParseFile`,
   PowerShell's equivalent of `bash -n`) against the downloaded
   `Configure-NtpConfig.ps1` **before** touching anything under the
   install directory.
4. If the check passes, swaps the new files into place (via rename, not a
   slow in-place overwrite) and re-executes itself with the new version.
5. If any step fails, or GitHub cannot be reached, it logs a warning and
   keeps running the version already in memory. Nothing under the install
   directory is touched in that case.

Re-running `Install-NtpConfig.ps1` does the same download-verify-then-swap
on demand and is also the way to change the saved TLS choice.

### Release Channels and Pinning

Every install follows one git *ref*, saved as `Ref` in
`.ntp-config-state.json`:

| Ref | What it means |
| --- | --- |
| `stable` (default) | A branch that only ever points at a tagged release. The machine updates when a new release is promoted, and never sees unfinished work on `main`. |
| `ntp-config-vX.Y.Z` | A release tag. The machine is **pinned** to exactly that release and never moves. |
| any other branch or tag | Allowed (for testing a branch, for example), at your own risk. |

Check what a machine follows, and which version it runs:

```powershell
(Get-Content C:\DATA\Tools\NTP-Config\.ntp-config-state.json | ConvertFrom-Json).Ref
(Select-String -Path C:\DATA\Tools\NTP-Config\Configure-NtpConfig.ps1 -Pattern '^    Version:').Line
```

Change it by re-running the installer with `-Ref`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\Install-NtpConfig.ps1" -Ref ntp-config-v1.0.0   # pin
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\Install-NtpConfig.ps1" -Ref stable              # back on the channel
```

Re-running the installer **without** `-Ref` (or without a TLS option) keeps
what the machine already uses, so a pinned machine stays pinned. To install
pinned from the start, download the installer from the tag and pass `-Ref`:

```powershell
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/MVTS-Corp/Scripts/ntp-config-v1.0.0/Windows/NTP-Config/Install-NtpConfig.ps1" -OutFile "$env:TEMP\Install-NtpConfig.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\Install-NtpConfig.ps1" -Ref ntp-config-v1.0.0
```

The self-update never installs a version older than the one running, so if a
release turns out to be bad, publish a fixed newer release rather than
moving `stable` backwards; to put one machine back on an older release
immediately, re-run the installer with `-Ref <older tag>`. How releases are
cut is described in the repository's top-level README.

### Calling From Another Script

The tool can be driven by a larger setup script with no prompts at all.
Run it as its own process (so its exit code and output are captured cleanly)
from an elevated context:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\DATA\Tools\NTP-Config\Configure-NtpConfig.ps1" -TimeSource Default -AllowSubnet 192.168.1.0/24
```

| Parameter | Meaning |
| --- | --- |
| `-TimeSource` | `Default` (the recommended choice for this machine's role, see Overview), `Windows`, `UsaPool`, `Preferred`, `Custom` (with `-CustomSource`), or `DomainHierarchy` |
| `-CustomSource` | Hostnames or IPs for `-TimeSource Custom` (array, or comma/space separated) |
| `-AllowSubnet` | The complete list of subnets allowed to query this machine's NTP server role (CIDR, comma/space separated), or `none`. It replaces the current list, and matching firewall rules are added and removed to follow. |
| `-AllowAtypical` | Permit an explicit external source where the role would normally follow the domain hierarchy (domain members, secondary DCs, child-domain PDC emulators) |
| `-Status` | Print the current configuration and change nothing (does not start or re-enable w32time) |
| `-Update` | Also check for a self-update (off by default when unattended, so the caller decides which version runs) |
| `-Unattended` | Never prompt (implied by `-TimeSource` or `-AllowSubnet`) |

How it behaves, so a caller can rely on it:

- **Role-aware.** `-TimeSource Default` picks what the Overview describes for
  this machine: an external source for a standalone machine or the forest
  root PDC emulator, the domain hierarchy for everything else. A request that
  does not suit the role is refused (exit 3) instead of applied.
- **Idempotent.** Each setting is compared with what the registry and
  firewall already hold and only written if it differs. Repeating the same
  command changes nothing and does not restart w32time. A change to firewall
  rules alone never restarts the service. The last line printed is
  `RESULT: changed`, `RESULT: unchanged`, or `RESULT: refused`.
- **One registry backup per run**, taken before the first write, so the
  automatic restore always returns to the state the run started from.
- **Parameters are checked first.** A bad value exits with code 2 before
  anything is touched, and without needing elevation.

| Exit code | Meaning |
| --- | --- |
| 0 | Success (changes applied, or nothing needed changing) |
| 1 | Runtime failure (not elevated, w32time would not start, `w32tm` failed) |
| 2 | Invalid parameters; nothing was touched |
| 3 | Refused: the request does not suit this machine's role; nothing changed |
| 4 | Time settings are enforced by Group Policy; nothing changed |

```powershell
$p = Start-Process powershell.exe -Wait -PassThru -NoNewWindow -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\DATA\Tools\NTP-Config\Configure-NtpConfig.ps1','-TimeSource','Default','-AllowSubnet','192.168.1.0/24'
switch ($p.ExitCode) {
    0 { 'NTP configured' }
    3 { 'NTP: request does not suit this machine role' }
    4 { 'NTP: managed by Group Policy, left alone' }
    default { throw "NTP configuration failed (exit $($p.ExitCode))" }
}
```

A caller does not have to install the tool at all: run
`Windows\NTP-Config\Configure-NtpConfig.ps1` straight out of a repo snapshot
it already has (self-update only applies to an installed copy). To install it
on the target first, call `Install-NtpConfig.ps1` (also non-interactive; exit
codes 0 installed, 1 runtime failure, 2 invalid parameters). `runme.cmd` is
for double-clicking; a script should call the `.ps1` directly.

### Migrating From an Earlier Self-Hosted Install

Hosts that were set up from an earlier self-hosted copy of this tool keep
updating from that server until re-installed. Re-run the Quick Start
commands once on each such host. The installer overwrites the old state
file, and until then the tool prints a warning on each run (it will not
follow a state file from the older layout) and continues with the version
already installed. Time settings live in the registry (`w32tm`) and the
`NTP-SCRIPT-ALLOW-*` firewall rules, not in the install directory, so a
re-install does not change them.

### Configuration Storage

There is no separate config file. All settings (time source, sync type,
reliable-time-source flag) are written directly into the registry via
`w32tm /config`, the same place Windows itself stores them. A timestamped
registry export backup (`Backups\W32Time.<timestamp>.reg`) is created
before every change made through this tool.

Allowed subnets for the NTP server role are tracked purely as Windows
Firewall rules named `NTP-SCRIPT-ALLOW-<subnet>` - there is no separate
allow-list file to fall out of sync with the firewall, so (unlike the
Linux tool) there is no separate "re-create firewall rules" menu item;
the firewall rule set is the allow-list.

## Troubleshooting

**TLS / Certificate Errors During Install or Update**
See the Quick Start section above (`-Insecure` / `-CaCertPath`). If the CA
has since been installed into the Windows trust store, no flag is needed
going forward. `-CaCertPath` needs the certificate of the CA itself (the
root or issuing CA), not the server's own certificate: the check looks for
that CA's thumbprint in the certificate chain the server presents.

**"Could not reach GitHub to check for updates" on every run**
Non-fatal; the tool keeps working on the installed version. Check outbound
HTTPS to `raw.githubusercontent.com` and `github.com`, or set
`NTP_SKIP_SELF_UPDATE=1` on hosts that are intentionally offline.

**"The install state file is from an older version of this tool"**
The host was installed from an earlier self-hosted copy. Re-run
`Install-NtpConfig.ps1` (see Migrating From an Earlier Self-Hosted Install).

**w32time fails to start after a change**
Menu option 4 (apply changes and restart) automatically restores the
backup taken just before the change and retries the restart if the first
attempt fails, so the service should already be back up on the
last-known-good config. Check `Get-WinEvent -LogName System -MaxEvents 50
| Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Time-Service' }`.
Every backup taken this run is at
`C:\DATA\Tools\NTP-Config\Backups\W32Time.<timestamp>.reg` if a different
one needs restoring manually (`reg import <path>` then restart the
service). This tool writes no log file of its own; service events are in
the System event log.

**This machine's settings show as Group Policy-managed but I need to
change them**
Change the GPO (Computer Configuration > Administrative Templates >
System > Windows Time Service > Time Providers) rather than the local
config - a local change would just be overwritten by the next policy
refresh, which is why this tool refuses to make one. Use `gpresult /h
report.html` on the target machine to find which GPO is applying the
setting.

**No NTP clients showing up**
Adding or replacing a subnet under menu option 3 automatically creates
its firewall rule, so first confirm the querying device is actually in a
subnet that was added there (`Get-NetFirewallRule -DisplayName
'NTP-SCRIPT-ALLOW-*' | Get-NetFirewallAddressFilter`). Also confirm UDP
123 is not being blocked by anything upstream of this host (a router ACL
or another firewall) if the clients are not on the exact same broadcast
domain.
