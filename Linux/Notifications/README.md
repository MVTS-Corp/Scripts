README.md v1.0.0 (Last Rev: 2026-08-09)

# linux-notifications

## Overview

Installs and configures an SMTP relay (via `msmtp`) so a Linux host can
send alert emails, and deploys a `send-alert` command onto PATH so any
other script, cron job, or tool on that host can send an alert with a
single command instead of configuring its own mail relay. Supports
Debian-based distros (Debian, Ubuntu, Mint, ...), Fedora, and RHEL-family
distros (RHEL, CentOS, Rocky, AlmaLinux).

This is intentionally a standalone, general-purpose alerting tool, not
tied to any other script in this repo (including `Linux/Updates`, which
configures its own separate SMTP relay for its own alerts).

- Detects the host distro and its package manager (`apt-get`, `dnf`, or `yum`).
- Walks you through configuring an SMTP relay and a default alert recipient.
- Deploys a `send-alert` command any script or cron job on the host can call.
- Sends with a bounded timeout and a few retries, so a hung or unreachable
  relay cannot hang whatever called `send-alert`.

## Files

- `bootstrap.sh` - remote-install entry point: downloads a repo snapshot to
  a temp directory and hands off to `install.sh`. This is what the 1-click
  install command runs.
- `install.sh` - interactive installer: detects the distro, installs and
  configures `msmtp`, and deploys `send-alert`.
- `bin/send-alert.sh` - the CLI, deployed to `/opt/linux-notifications/bin`
  and symlinked onto PATH as `send-alert`.
- `lib/distro.sh` - distro/package-manager detection.
- `lib/notify.sh` - the `send_alert` function `send-alert.sh` calls.
- `lib/common.sh` - shared logging/prompt helpers.
- `uninstall.sh` - removes the deployed scripts, config, and `send-alert`
  command.

## Quick Start

**1-click install** - downloads the repo and launches the interactive
installer in one command:

```bash
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Notifications/bootstrap.sh | sudo bash
```

If you'd rather inspect the code before running it as root, clone and
install manually instead:

```bash
git clone https://github.com/MVTS-Corp/Scripts.git
cd Scripts/Linux/Notifications
sudo ./install.sh
```

Either way you'll be prompted for the SMTP relay settings and a default
alert recipient.

Once installed, send an alert from anywhere on the host:

```bash
send-alert "Backup failed" "The nightly backup job exited non-zero. See /var/log/backup.log."

# Override the configured default recipient for one message:
send-alert -t oncall@example.com "Disk almost full" "/var is at 94% on $(hostname)."

# Pipe a log tail in as the body:
tail -n 40 /var/log/some-job.log | send-alert "some-job failed"

# Confirm the relay still works, any time:
send-alert --self-test
```

## After Install Configuration

Re-run the installer at any time to change the SMTP settings or default
recipient - it's idempotent and will overwrite its own config, not
anything else on the host. `install.sh` itself is not deployed to
`/opt/linux-notifications` (only `bin/` and `lib/` are), so reconfigure
with whichever install method you used originally:

```bash
# 1-click:
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Notifications/bootstrap.sh | sudo bash

# from a kept clone:
sudo ./install.sh
```

### Per-Call Recipient Override

`DEFAULT_ALERT_TO` in `/etc/linux-notifications/config.conf` is used when
`send-alert` is called with no `-t`. Any caller can send to a different
address for that one message with `send-alert -t someone@example.com ...`,
without changing the host-wide default.

### Files It Manages on the Host

| Path | Purpose |
|---|---|
| `/opt/linux-notifications/` | Deployed copy of `bin/` and `lib/` |
| `/usr/local/bin/send-alert` | Symlink to the deployed `send-alert.sh` |
| `/etc/linux-notifications/config.conf` | Default alert recipient + from address |
| `/etc/linux-notifications/msmtprc` | SMTP relay config (mode 600) |
| `/var/log/linux-notifications/` | `msmtp` delivery log |

`/var/log/linux-notifications/` is root-only (mode 750) by default. The
`adm` group, if it exists on the host, is also granted read access,
matching the usual Debian/Ubuntu convention - `msmtp.log` contains the
subject/body of every alert sent through this host, so it is not left
world-readable.

### Uninstall

`uninstall.sh` is not deployed to the host either, so it needs a clone of
the repo (the 1-click install's temp download is removed once `install.sh`
finishes):

```bash
git clone https://github.com/MVTS-Corp/Scripts.git
cd Scripts/Linux/Notifications
sudo ./uninstall.sh
```

Leaves `msmtp` itself installed, since other things on the host may use it.

## Troubleshooting

- **"No controlling terminal (/dev/tty) available"** - the 1-click install
  command needs an interactive terminal for its prompts (SMTP host,
  credentials). Run it from an interactive SSH session, not from a
  non-interactive automation context; or use the manual clone install
  instead.
- **"Could not determine a supported package manager"** - the host's distro
  isn't Debian/Ubuntu-family, Fedora, or RHEL-family (see `lib/distro.sh`
  for the exact ID/ID_LIKE matches).
- **`send-alert` reports failure after 3 attempts** - check
  `/var/log/linux-notifications/msmtp.log` for the relay error (auth
  failure, TLS/certificate error, connection timeout), then re-run
  `install.sh` to fix the SMTP settings.
- **"Missing config file" from send-alert** - `install.sh` has not been run
  yet, or `uninstall.sh` removed `/etc/linux-notifications/`.
- **Command not found: send-alert** - open a new shell (PATH changes only
  apply to processes started after `/usr/local/bin` was updated), or
  confirm `/usr/local/bin` is on `PATH` for the account running it (true
  by default for interactive shells and cron on virtually every distro).
