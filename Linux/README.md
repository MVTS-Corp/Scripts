README.md v1.6.0 (Last Rev: 2026-11-14)

## Overview

This is the root directory for scripts used on Linux. Each subfolder is a
self-contained tool with its own README.

## Files

- **Backups/** - backup and restore tooling for self-hosted services, one
  subfolder per service. See `Backups/README.md`.
- **Firewall-Config/** - applies a baseline host firewall (ufw or firewalld):
  default-deny inbound, SSH and Cockpit allowed, lockout protection. See
  `Firewall-Config/README.md`.
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
- **RustDesk-Server/** - installs, verifies, and upgrades the open source
  RustDesk server (hbbs + hbbr) under Docker Compose with a pinned image,
  host firewall rules for only the needed ports, enforced key, and rollback.
  See `RustDesk-Server/README.md`.
- **Server-Maintenance/** - scheduled maintenance for servers on premises or
  in the cloud: OS updates, container image updates with a soak period,
  approval, health checks and rollback, controlled reboots with a post-boot
  check, alerts and Uptime Kuma heartbeats. See `Server-Maintenance/README.md`.
- **Server-Setup/** - baseline provisioning for a freshly installed
  server (OS update, packages, host name, timezone, firewall, time
  synchronization via NTP-Config, Cockpit, SSH hardening, fail2ban, journald,
  scheduled updates, usr_admin permissions). See `Server-Setup/README.md`.
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
