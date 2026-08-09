README.md v1.0.0 (Last Rev: 2026-08-09)

## Overview

This is the root directory for scripts used on Microsoft Windows. Each
subfolder is a self-contained tool with its own README.

## Files

- **Development-Tools/** - portable installer for the core Windows
  development toolchain (Claude Code, Git, Node.js, Gitea, GitHub CLI/
  Desktop, VS Code, Notepad++). See `Development-Tools/README.md`.
- **MVTS/** - installs the MVTS brand fonts system-wide. See
  `MVTS/README.md`.
- **Server/** - placeholder for Windows Server specific scripts; empty for
  now. See `Server/README.md`.

## Quick Start

Each subfolder is independently usable; see that subfolder's README for
exact instructions (either a remote one-liner or copying files locally).
To work with more than one, clone the whole repo instead:

```powershell
git clone https://github.com/MVTS-Corp/Scripts.git
cd Scripts\Windows
```
