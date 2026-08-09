README.md v1.0.0 (Last Rev: 2026-08-09)

## Overview

MVTS brand asset scripts for Windows. Currently holds the font installer
that puts the MVTS brand Google Fonts on a Windows host system-wide.

## Files

- `MVTS-Fonts.ps1` - installs Permanent Marker, Archivo Black, Outfit, and
  Inter (regular and italic) to `%WINDIR%\Fonts` and registers them under
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts` so they persist
  and are visible to every user. Idempotent; already-registered families are
  skipped unless `-Force` is given.

## Quick Start

Remote, run straight from the repo (in an elevated PowerShell session):

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
irm https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Windows/MVTS/MVTS-Fonts.ps1 | iex
```

With `-Force` (`iex` cannot take parameters, so wrap it in a scriptblock):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Windows/MVTS/MVTS-Fonts.ps1))) -Force
```

Or from a cloned copy of this repo (elevated PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File .\MVTS-Fonts.ps1
```

## After Install Configuration

The script broadcasts `WM_FONTCHANGE` after a successful install so most
already-running applications pick up the new fonts without a reboot.
Applications that cache their font list at startup (some Office and Adobe
products) may still need to be closed and reopened.

## Troubleshooting

- **"Run this from an elevated (Administrator) PowerShell session."** - the
  script writes to `%WINDIR%\Fonts` and `HKLM`, both of which require
  Administrator rights.
- **A font shows as missing in the final verification** - re-run with
  `-Force` to force a fresh download and re-registration.
- **"download failed" warning for a specific family** - the google/fonts
  repo may have renamed or restructured that file. Check the `$Fonts` array
  at the top of `MVTS-Fonts.ps1` against the current path in
  https://github.com/google/fonts.
