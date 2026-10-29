README.md v1.1.0 (Last Rev: 2026-10-28)

## Overview

This is the root directory for scripts used on Microsoft Windows Server
2019 and later. Each subfolder is a self-contained tool with its own README.

## Files

- **Server-Setup/** - baseline provisioning for a new Windows Server
  (domain controllers, RDS, Hyper-V, application servers, Server Core). Runs
  the AppX deadlock fix, sets the time zone and time sync, and applies a
  small set of defaults. One-line install. See `Server-Setup/README.md`.
- **AppX-Deadlock/** - prevents, or checks for, the `AppXSvc` deadlock that
  stops a server from rebooting or accepting RDP. Runs on its own against
  existing servers, and is also the first step of Server-Setup. See
  `AppX-Deadlock/README.md`.

## Quick Start

For a new server, use the Server-Setup one-liner in `Server-Setup/README.md`.
For an existing server, run `AppX-Deadlock/Repair-AppxDeadlock.ps1 -Status`
first; see `AppX-Deadlock/README.md`.
