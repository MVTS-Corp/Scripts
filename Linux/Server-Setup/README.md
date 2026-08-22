README.md v1.1.0 (Last Rev: 2026-08-22)

# Server-Setup

## Overview

Baseline provisioning for a freshly installed Linux server, so every new
box starts from the same known-good state instead of being set up by
hand from memory each time. One run of `setup-server.sh` does everything
below, detecting the host distro and adapting package names/mechanisms
accordingly. Supports Debian-based distros (Debian, Ubuntu, Mint, ...)
today, with Fedora and RHEL-family distros (RHEL, CentOS, Rocky,
AlmaLinux) also detected and supported.

- Installs base tooling: `net-tools`, DNS lookup tools (`dnsutils` on
  Debian/Ubuntu, `bind-utils` on Fedora/RHEL), `NetworkManager`, `acl`,
  `unzip`.
- Sets the system timezone (default `America/New_York`, overridable).
- Installs and enables Cockpit, opening the firewall for it if a host
  firewall (`firewalld` or `ufw`) is active.
- On Debian/Ubuntu hosts using netplan, sets `renderer: NetworkManager`
  in the netplan config so Cockpit's networking UI can actually manage
  the interfaces. No-op on Fedora/RHEL (no netplan there) and on hosts
  not using netplan at all.
- Enables unattended OS updates (`unattended-upgrades` on Debian/Ubuntu,
  `dnf-automatic` with `apply_updates = yes` on Fedora/RHEL).
- Creates the `usr_admin` group (GID 3000) and adds `root` plus the
  admin user you specify, with recursive read/write/execute ACLs on
  `/opt` (including a default ACL so new files inherit it). This step
  delegates to `Linux/Group-MGMT/create-usr_admin-group.sh` rather than
  duplicating that logic - see that folder's README for details.
- Logs every run to a file, not just the terminal, so a failure during
  an unattended/RMM invocation still leaves a record. The log directory
  is root-only (mode 750) by default; `usr_admin` (once created, above)
  is also granted read access, alongside the `adm` group where present.

Every step is idempotent - safe to re-run against a host that's already
been set up, whether to pick up a change or just to confirm nothing
drifted.

## Files

- `bootstrap.sh` - remote-install entry point: downloads a repo snapshot
  to a temp directory and hands off to `setup-server.sh`. This is what
  the 1-click install command runs.
- `setup-server.sh` - the provisioning script itself.
- `lib/distro.sh` - distro/package-manager detection.
- `lib/common.sh` - shared logging/prompt helpers.

## Quick Start

**1-click install** - downloads the repo and runs the provisioner in one
command (prompts for the admin username if not given):

```bash
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Server-Setup/bootstrap.sh | sudo bash
```

Non-interactive (RMM/automation), admin username and confirmation given
up front:

```bash
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Server-Setup/bootstrap.sh | sudo bash -s -- --admin-user jsmith --yes
```

If you'd rather inspect the code before running it as root, clone and
run manually instead:

```bash
git clone https://github.com/MVTS-Corp/Scripts.git
cd Scripts/Linux/Server-Setup
sudo ./setup-server.sh --admin-user jsmith
```

The admin user must already exist on the host - this script does not
create local user accounts, only the `usr_admin` group and its
permissions. Create the account first if it doesn't exist yet.

## After Install Configuration

### Cockpit

Reachable at `https://<host>:9090` once the script completes. If a host
firewall is active, TCP 9090 was opened automatically; if you add a
firewall later, allow that port for Cockpit yourself.

### netplan (Debian/Ubuntu only)

If the host uses netplan, the renderer change is validated (`netplan
generate`) but **not applied automatically** - applying a network config
change unattended, especially over a remote SSH session, risks losing
connectivity if something about the change is wrong for this host. Run
`sudo netplan apply` yourself when ready, or it takes effect on next
reboot. A timestamped backup of each edited YAML file is left alongside
the original.

### Re-running

Every step is safe to run again - already-installed packages are
no-ops, the timezone can be set to the same value repeatedly, the
netplan renderer edit is skipped if already present, and the usr_admin
group/ACL step is idempotent (see `Group-MGMT/README.md`).

### Timezone

Override with `--timezone <IANA name>`, e.g. `--timezone
America/Chicago`. Run `timedatectl list-timezones` on the host to see
valid values.

### Files It Manages on the Host

| Path | Purpose |
|---|---|
| `/var/log/server-setup/` | Per-run logs, `setup-<timestamp>.log` (kept 180 days) |

`/var/log/server-setup/` is root-only (mode 750) by default. It's locked
down as soon as it's created - before `usr_admin` exists - so the `adm`
group (if present on the host) is granted read access first; once
`usr_admin` is created later in the same run, its permissions are
reapplied to also grant that group read access, matching the same
Debian/Ubuntu log-reading convention `Linux/Updates` and
`Linux/Notifications` use.

## Troubleshooting

- **"Could not determine a supported package manager"** - the host's
  distro isn't Debian/Ubuntu-family, Fedora, or RHEL-family (see
  `lib/distro.sh` for the exact ID/ID_LIKE matches).
- **"User '<name>' does not exist on this system"** - create the local
  account first; this script intentionally does not create user
  accounts, only the `usr_admin` group and its permissions.
- **Cockpit install fails on Debian with an apt/backports error** - the
  script adds the `<codename>-backports` source automatically on Debian
  (Ubuntu already has it by default), but confirm `VERSION_CODENAME` in
  `/etc/os-release` matches a codename that actually has a `-backports`
  suite upstream (very new/old releases sometimes don't yet or don't
  anymore).
- **"cockpit.socket did not become active"** - check `systemctl status
  cockpit.socket` and `journalctl -u cockpit.socket` for the underlying
  error.
- **"netplan generate failed after editing renderer config"** - a syntax
  error was introduced (or already present) in a file under
  `/etc/netplan`. A timestamped `.bak-<timestamp>` copy of each file was
  saved before editing; compare against it or restore it, fix, and
  re-run.
- **"dnf-automatic.timer did not become active"** - check `systemctl
  status dnf-automatic.timer` for the underlying error.
- **Group/ACL step fails** - see `Group-MGMT/README.md`'s
  Troubleshooting section; the same `create-usr_admin-group.sh` runs
  underneath this step.
- **"Failed to fetch create-usr_admin-group.sh"** - this only happens on
  a standalone run of `setup-server.sh` outside a full repo clone (the
  1-click `bootstrap.sh` install always has the whole repo already, so
  this path is not used there). Check network connectivity to
  raw.githubusercontent.com, or clone the full repo instead.
- **Where's the run log?** - `/var/log/server-setup/setup-<timestamp>.log`,
  one per run, kept 180 days. Readable by root, `usr_admin`, and (where
  present) `adm`; nobody else.
