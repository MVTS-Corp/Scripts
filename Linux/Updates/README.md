README.md v1.2.0 (Last Rev: 2026-08-09)

# linux-updates

## Overview

Automated OS patching for Linux servers with email alerting, deployed as a
cron job. Supports Debian-based distros (Debian, Ubuntu, Mint, ...) today,
with Fedora and RHEL-family distros (RHEL, CentOS, Rocky, AlmaLinux) also
detected and supported.

- Detects the host distro and its package manager (`apt-get`, `dnf`, or `yum`).
- Walks you through picking an update schedule (daily / weekly / monthly /
  custom cron expression).
- Walks you through configuring an SMTP relay (via `msmtp`) so the host can
  send alert emails after each update run.
- Deploys itself to `/opt/linux-updates` and installs an `/etc/cron.d`
  entry that runs updates on your chosen schedule.
- Each run emails a summary (success/failure, whether a reboot is required,
  and a tail of the log) to the address(es) you configure.

## Files

- `bootstrap.sh` - remote-install entry point: downloads a repo snapshot to
  a temp directory and hands off to `install.sh`. This is what the 1-click
  install command runs.
- `install.sh` - interactive installer: detects the distro, configures
  everything, and deploys the cron job.
- `bin/run-updates.sh` - the script actually run by cron. Can also be run
  manually to test: `sudo /opt/linux-updates/bin/run-updates.sh`.
- `lib/distro.sh` - distro/package-manager detection.
- `lib/notify.sh` - sends the alert email via `msmtp`.
- `lib/common.sh` - shared logging/prompt helpers.
- `uninstall.sh` - removes the cron job, deployed scripts, and config.

## Quick Start

**1-click install** - downloads a snapshot of the Scripts repo and
launches the interactive installer in one command:

```bash
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Updates/bootstrap.sh | sudo bash
```

If you'd rather inspect the code before running it as root, clone and
install manually instead:

```bash
git clone https://github.com/MVTS-Corp/Scripts.git
cd Scripts/Linux/Updates
sudo ./install.sh
```

Either way you'll be prompted for the update mode, schedule, and SMTP relay
settings.

## After Install Configuration

Re-run the installer at any time to change the update mode, schedule, or
SMTP settings - it's idempotent and will overwrite its own config, not
anything else on the host. `install.sh` itself is not deployed to
`/opt/linux-updates` (only `bin/` and `lib/` are), so reconfigure with
whichever install method you used originally:

```bash
# 1-click:
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Updates/bootstrap.sh | sudo bash

# from a kept clone:
sudo ./install.sh
```

### Update Modes

- **All updates** - full `upgrade` via the native package manager.
- **Security only** - `dnf`/`yum --security` on Fedora/RHEL; on Debian,
  packages are filtered by checking which candidates come from a repo with
  "security" in its origin (a best-effort heuristic, not a guarantee).

### Files It Manages on the Host

| Path | Purpose |
|---|---|
| `/opt/linux-updates/` | Deployed copy of `bin/` and `lib/` |
| `/etc/linux-updates/config.conf` | Update mode + alert recipient |
| `/etc/linux-updates/msmtprc` | SMTP relay config (mode 600) |
| `/etc/cron.d/linux-updates` | Cron schedule |
| `/var/log/linux-updates/` | Per-run logs (kept 30 days) |

### Uninstall

`uninstall.sh` is not deployed to the host either, so it needs a clone of
the repo (the 1-click install's temp download is removed once `install.sh`
finishes):

```bash
git clone https://github.com/MVTS-Corp/Scripts.git
cd Scripts/Linux/Updates
sudo ./uninstall.sh
```

Leaves `cron`/`msmtp` themselves installed, since other things on the host
may use them.

## Troubleshooting

- **"No controlling terminal (/dev/tty) available"** - the 1-click install
  command needs an interactive terminal for its prompts (update mode,
  schedule, SMTP credentials). Run it from an interactive SSH session, not
  from a non-interactive automation context; or use the manual clone
  install instead.
- **"Could not determine a supported package manager"** - the host's distro
  isn't Debian/Ubuntu-family, Fedora, or RHEL-family (see `lib/distro.sh`
  for the exact ID/ID_LIKE matches).
- **Alert emails not arriving** - check `/var/log/linux-updates/msmtp.log`
  for the relay error, then re-run `install.sh` to fix the SMTP settings.
- **Per-run logs** - `/var/log/linux-updates/update-<timestamp>.log`,
  retained for 30 days.
