README.md v1.3.1 (Last Rev: 2026-09-19)

## Overview

This is the root directory for scripts used on Linux. Each subfolder is a
self-contained tool with its own README.

## Files

- **Backups/** - backup and restore tooling for self-hosted services, one
  subfolder per service. See `Backups/README.md`.
- **Group-MGMT/** - provisions fixed-GID groups consistently across the
  MVTS Linux fleet. See `Group-MGMT/README.md`.
- **MVTS/** - installs the MVTS brand fonts system-wide. See
  `MVTS/README.md`.
- **NTP-Config/** - interactive tool to configure a host as a chrony-based
  NTP server (upstream sources, allowed subnets with matching firewall
  rules, stratum lock). Installs and updates itself from GitHub. See
  `NTP-Config/README.md`.
- **Notifications/** - installs and configures an SMTP relay (via `msmtp`)
  so a host can send alert emails, independent of any other tool. See
  `Notifications/README.md`.
- **Server-Setup/** - baseline provisioning for a freshly installed
  server (packages, timezone, time synchronization via NTP-Config, Cockpit,
  unattended updates, usr_admin permissions). See `Server-Setup/README.md`.
- **Updates/** - automated OS patching with email alerting, deployed as a
  cron job. See `Updates/README.md`.

## Quick Start

Each subfolder is independently installable with its own one-line curl
command; see that subfolder's README for the exact command. To work with
more than one, clone the whole repo instead:

```bash
git clone https://github.com/MVTS-Corp/Scripts.git
cd Scripts/Linux
```
