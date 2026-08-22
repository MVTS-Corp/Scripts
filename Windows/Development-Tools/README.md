README.md v1.1.0 (Last Rev: 2026-08-09)

## Overview

This folder contains a portable installer for the core Windows development toolchain: Claude
Code, Git for Windows, Node.js LTS, Gitea, Gitea MCP, Tea CLI, GitHub CLI, GitHub Desktop,
Visual Studio Code, and Notepad++, plus a follow-up helper script to finish configuring Gitea
MCP once you have a Gitea instance and token.

Everything is installed under `C:\DATA\Tools` (created automatically, with one subfolder per
tool), and system-wide (Machine scope) PATH entries and environment variables are configured
afterward so every tool works from any new terminal window, for any user on the machine.

`Run-Install-DevTools.cmd` and `Install-DevTools.ps1` are fully portable: neither references
the folder they started in. Copy them together into any folder on any Windows 10/11 machine
and run the `.cmd` file.

## Files

- `Run-Install-DevTools.cmd` - one-click launcher. Self-elevates to Administrator (a UAC
  prompt will appear), then runs `Install-DevTools.ps1` from wherever it actually sits.
- `Install-DevTools.ps1` - the installer itself. Can also be run directly from an elevated
  PowerShell prompt: `powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-DevTools.ps1`
- `setup-gitea-mcp.ps1` - run after you have a Gitea instance and a personal access token.
  Adds the GiteaMCP/Tea folders to your user PATH, sets `GITEA_HOST` /
  `GITEA_ACCESS_TOKEN` as persistent user environment variables, registers `gitea-mcp` with
  Claude Code, and optionally creates a `tea` CLI login profile. Prompts for the PAT via a
  masked `Read-Host`, so it is never typed as a plaintext argument or saved to shell history.
- `C:\DATA\Tools\Logs\install-YYYYMMDD-HHmmss.log` - full timestamped log of every
  `Install-DevTools.ps1` run, created the first time the installer runs.

## Quick Start

1. Copy `Run-Install-DevTools.cmd` and `Install-DevTools.ps1` into any folder on the target
   machine.
2. Double-click `Run-Install-DevTools.cmd`.
3. Approve the UAC (Administrator) prompt.
4. Wait for it to finish; a summary of what installed and what (if anything) failed prints
   at the end and is saved to the log file.
5. Close and reopen any terminal windows before using the newly installed tools (already-open
   windows do not pick up updated system environment variables automatically).

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "Install-DevTools.ps1"
```

Fetching both files straight from the repo instead of cloning it (elevated PowerShell):

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = 'https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Windows/Development-Tools'
irm "$base/Install-DevTools.ps1" -OutFile Install-DevTools.ps1
irm "$base/Run-Install-DevTools.cmd" -OutFile Run-Install-DevTools.cmd
.\Run-Install-DevTools.cmd
```

## After Install Configuration

- **Git identity**: the installer does not set `git config user.name` / `user.email` since
  that is personal to you, not the machine. Set it yourself:
  `git config --global user.name "Your Name"` and `git config --global user.email "you@example.com"`.
- **GitHub CLI**: run `gh auth login` to authenticate.
- **Claude Code**: run `claude` and follow the sign-in prompt.
- **GitHub Desktop**: its official installer only supports a per-user install with no custom
  path (a Squirrel/upstream limitation, not something this script can work around). It installs
  to the standard per-user location for the account that ran the installer; the real path is
  recorded in the `GITHUB_DESKTOP_HOME` environment variable (nothing is left under
  `C:\DATA\Tools` for it, since there is no real location to point at there).
- **Gitea**: only the `gitea.exe` binary is installed (`C:\DATA\Tools\Gitea\gitea.exe`). It is
  not configured or running as a service, since that requires site-specific choices (ports,
  database, HTTPS, data directory) this script cannot guess. See
  https://docs.gitea.com/installation for setting up `app.ini` and running it as a Windows
  service.
- **Gitea MCP**: `C:\DATA\Tools\GiteaMCP\gitea-mcp.exe` needs your Gitea host URL and an access
  token, neither of which `Install-DevTools.ps1` has. Once you have a running Gitea instance
  and a token, run `setup-gitea-mcp.ps1` from this folder to finish the setup:
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-gitea-mcp.ps1 -GiteaHost "https://your-gitea-host"
  ```
  It will prompt for the token, then register `gitea-mcp` with Claude Code. To do it by hand
  instead:
  ```powershell
  claude mcp add gitea -- "C:\DATA\Tools\GiteaMCP\gitea-mcp.exe" --host <your-gitea-url> --token <your-token>
  ```
- **npm global packages** (including Claude Code) install under `C:\DATA\Tools\npm-global`;
  the `NPM_CONFIG_PREFIX` environment variable points there so future `npm install -g` calls
  land in the same place.

## Troubleshooting

- **"winget was not found"**: install "App Installer" from the Microsoft Store
  (https://apps.microsoft.com/detail/9nblggh4nns1), then re-run the installer.
- **"This script must be run as Administrator"**: run `Run-Install-DevTools.cmd`, not the
  `.ps1` file directly, or launch PowerShell as Administrator first.
- **One tool failed but others succeeded**: the installer treats each tool independently, logs
  the failure, and continues with the rest. Check the log file for the specific error, then
  re-run the installer; it is safe to run more than once (already-installed tools are detected
  and only new/failed ones are effectively retried).
- **A tool installed but is not recognized on the command line**: open a brand new terminal
  window. System PATH changes only apply to processes started after the change.
- **Checksum mismatch error during Gitea, Tea, or Gitea MCP install**: this means the
  downloaded file did not match its published checksum and the installer stopped rather than
  use a potentially corrupted or tampered file. Re-run the installer; if it persists, check
  your network connection for interference (proxy, antivirus rewriting downloads).
