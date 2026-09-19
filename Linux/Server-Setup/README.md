README.md v1.4.0 (Last Rev: 2026-09-19)

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
- Shows the current time server configuration and asks whether it needs
  to change (default: no). If yes, it hands off to
  `Linux/NTP-Config/configure-ntp-server.sh` so the server gets accurate
  time sources; if no, setup moves on. See
  [Time Synchronization](#time-synchronization-ntp) below.
- Installs and enables Cockpit, opening the firewall for it if a host
  firewall (`firewalld` or `ufw`) is active.
- On Debian/Ubuntu hosts using netplan, sets `renderer: NetworkManager`
  in the netplan config so Cockpit's networking UI can actually manage
  the interfaces. No-op on Fedora/RHEL (no netplan there) and on hosts
  not using netplan at all. On hosts that build their initramfs with
  dracut (Ubuntu 26.04), it also keeps networking out of the initramfs
  (see [netplan](#netplan-debianubuntu-only) below for why).
- Enables unattended OS updates (`unattended-upgrades` on Debian/Ubuntu,
  `dnf-automatic` with `apply_updates = yes` on Fedora/RHEL).
- Creates the `usr_admin` group (GID 3000) and adds `root` plus the
  admin user you specify, with recursive read/write/execute ACLs on
  `/opt` (including a default ACL so new files inherit it). This step
  delegates to `Linux/Group-MGMT/create-usr_admin-group.sh` rather than
  duplicating that logic - see that folder's README for details. If the
  group doesn't already exist, you're asked to confirm creating it
  specifically (separate from the one overall "Proceed?" prompt);
  declining skips just this step - every other part of provisioning
  still runs. If the group already exists, no prompt is shown and
  membership is just ensured, since nothing new is being created.
- Logs every run to a file, not just the terminal, so a failure during
  an unattended/RMM invocation still leaves a record. The log directory
  is root-only (mode 750) by default; `usr_admin` (once created, above)
  is also granted read access, alongside the `adm` group where present.

Every step is idempotent - safe to re-run against a host that's already
been set up, whether to pick up a change or just to confirm nothing
drifted.

Exit codes: `0` success, `1` failure (or you chose to exit after an NTP
error), `3` completed but one or more items are flagged for review (see
[Time Synchronization](#time-synchronization-ntp)).

## Files

- `bootstrap.sh` - remote-install entry point: downloads a repo snapshot
  to a temp directory and hands off to `setup-server.sh`. This is what
  the 1-click install command runs.
- `setup-server.sh` - the provisioning script itself.
- `lib/distro.sh` - distro/package-manager detection.
- `lib/common.sh` - shared logging/prompt helpers.

It also calls two sibling tools in this repo rather than duplicating them:
`../Group-MGMT/create-usr_admin-group.sh` (the `usr_admin` step) and
`../NTP-Config/configure-ntp-server.sh` (the time synchronization step).
Both are used from the sibling folder when present (the 1-click install and
a full clone always have them) and fetched from GitHub otherwise.

Options for the time synchronization step (see `--help` for all options):

| Option | Meaning |
| --- | --- |
| `--skip-ntp` | Skip the step entirely. |
| `--ntp-sources V` | Set the time sources without prompting: `native`, `usa`, `preferred`, or a comma separated list of hostnames/IPs. |
| `--ntp-allow CIDRS` | Set the subnets allowed to query this host for time (comma separated), or `none`. Repeatable. |
| `--ntp-stratum N` | Set the local stratum lock (0-15), or `none`. |

The three `--ntp-*` options go straight to `configure-ntp-server.sh`'s
own unattended interface (see `NTP-Config/README.md`, "Calling From Another
Script"), which checks them before changing anything and does nothing if the
host already matches.

## Quick Start

**1-click install** - downloads the repo and runs the provisioner in one
command. The user who ran `sudo` is added to `usr_admin` automatically
(pass `--admin-user` to name someone else; if run directly as root with no
`--admin-user`, it prompts for the username instead):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Server-Setup/bootstrap.sh)"
```

Or naming a different admin user (`bootstrap` is just the script's `$0`
placeholder and must be there):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Server-Setup/bootstrap.sh)" bootstrap --admin-user jsmith
```

Non-interactive (RMM/automation), admin username and confirmation given
up front:

```bash
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Server-Setup/bootstrap.sh | sudo bash -s -- --admin-user jsmith --yes
```

Do not use `curl ... | sudo bash` without `--yes`. Piping into sudo leaves
the script outside its terminal's foreground process group on newer sudo
(seen on Ubuntu 26.04), so any prompt hangs or is refused. With `--yes`
nothing ever prompts (the admin user comes from `--admin-user`, or from
the invoking sudo user), so the pipe form is safe there.

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

### Time Synchronization (NTP)

This step runs right after the timezone, so the clock is right for the TLS
and package operations that follow. It first prints the current state: the
active time daemon, whether the clock is synchronized, and (when chrony is
installed) NTP-Config's full status report of sources, allowed subnets,
stratum lock, and `chronyc` output. If chrony is not installed yet, it says
so and shows what `systemd-timesyncd` is using instead.

Then, in an interactive run, it asks **"Do you need to change the time
server configuration?"** (default: no).

- **No:** nothing is changed or installed, and setup moves on.
- **Yes:** it starts NTP-Config's interactive menu. Installing chrony (if
  missing), choosing upstream sources, allowed subnets, and a stratum lock
  all happen there. When you choose Exit with changes still pending, the
  tool offers to apply them and restart chrony (default yes), restoring its
  backup if chrony rejects the new config.

Unattended runs (`--yes`, or no terminal) have nobody to ask, so by default
they only show the configuration and leave it as it is. Pass `--ntp-sources`,
`--ntp-allow`, and/or `--ntp-stratum` to configure it unattended, or
`--skip-ntp` to leave the step out.

`configure-ntp-server.sh` is run from where it is found and is **not
installed** on the host by this step. Use the sibling copy in the repo
snapshot when present; otherwise it is fetched from the NTP-Config `stable`
channel. To keep it installed with self-updates, use the one-liner in
`NTP-Config/README.md`. Note that the 1-click install downloads `main`, so
the sibling copy there is the `main` version of the tool.

**If the NTP step fails** (the tool cannot be fetched, chrony will not start
on the new config, the arguments are rejected, and so on), the error is shown
and you are asked to **Exit** setup right there or **Skip** NTP and continue.
Either way a record is appended to `/var/log/server-setup/audit.log`: when it
happened, the host, who ran it (the sudo user and login user) and the admin
user, what failed, the exit code, the NTP tool's version and where it came
from, and the last 20 lines of the run log. Unattended runs always skip. A
skipped NTP step is flagged under "FLAGGED FOR REVIEW" in the final summary
and the run exits `3` instead of `0`, so an RMM or wrapper can tell a clean
run from one that needs a look. Re-running the script retries the step.

### netplan (Debian/Ubuntu only)

If the host uses netplan, the renderer change is validated (`netplan
generate`) but **not applied automatically** - applying a network config
change unattended, especially over a remote SSH session, risks losing
connectivity if something about the change is wrong for this host. Run
`sudo netplan apply` yourself when ready, or it takes effect on next
reboot. A timestamped backup of each edited YAML file is left alongside
the original.

**Initramfs (dracut hosts, e.g. Ubuntu 26.04).** The default dracut
initramfs contains `systemd-networkd` and a DHCP-everything default
network file, so it DHCPs the NIC before the real system starts and that
address survives into the running system. With the NetworkManager
renderer, nothing in netplan overrides it: NetworkManager adopts the
leftover DHCP address instead of applying your static netplan profile,
and the host boots on a DHCP address until someone runs `netplan apply`.
To prevent this, the script copies Ubuntu's own dracut profile
(`/usr/lib/dracut/dracut.conf.d/no-network/10-no-network.conf`) to
`/etc/dracut.conf.d/10-no-network.conf` and rebuilds the initramfs with
`update-initramfs -u`, so kernel updates keep building it that way. It
takes effect on the next boot. It is skipped, with a warning, if the host
looks like it needs the network in early boot (network root, iSCSI/NFS,
`ip=`/`rd.neednet` on the kernel command line, or network settings in
dracut's own config), or if `/etc/dracut.conf.d/10-no-network.conf`
already exists with different content. To undo it, delete that file and
run `sudo update-initramfs -u`.

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
| `/var/log/server-setup/audit.log` | Append-only record of items flagged for review (NTP step failures); created on the first one, never pruned automatically |
| `/etc/dracut.conf.d/10-no-network.conf` | dracut hosts only: keeps networking out of the initramfs (see netplan above) |

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
- **"NTP configuration failed: ..." and an Exit/Skip prompt** - see
  `/var/log/server-setup/audit.log` (the newest block at the bottom) for the
  full record, and the run log for the tool's own output. Common causes: no
  route to `raw.githubusercontent.com` on a standalone run ("Failed to fetch
  configure-ntp-server.sh"), or chrony rejecting the new config (the tool
  restores its backup and says so). Fix the cause and re-run.
- **Run exited with code 3** - not a failure: everything else completed, but
  the NTP step was skipped after an error and is listed under "FLAGGED FOR
  REVIEW" in the final summary. Check `audit.log`, then re-run.
- **"No active time synchronization daemon was detected"** - setup found no
  running chrony, `systemd-timesyncd`, or ntpd. Re-run and answer yes to the
  time server question, or pass `--ntp-sources`.
- **Group/ACL step fails** - see `Group-MGMT/README.md`'s
  Troubleshooting section; the same `create-usr_admin-group.sh` runs
  underneath this step.
- **"usr_admin: not configured (declined when prompted...)" in the final
  summary** - not an error; you answered "n" when asked to create the
  usr_admin group. Every other step still completed. Re-run the script
  (or just `Group-MGMT/create-usr_admin-group.sh` directly) any time to
  set it up later - see `Group-MGMT/README.md`.
- **"Failed to fetch create-usr_admin-group.sh"** - this only happens on
  a standalone run of `setup-server.sh` outside a full repo clone (the
  1-click `bootstrap.sh` install always has the whole repo already, so
  this path is not used there). Check network connectivity to
  raw.githubusercontent.com, or clone the full repo instead.
- **Where's the run log?** - `/var/log/server-setup/setup-<timestamp>.log`,
  one per run, kept 180 days. Readable by root, `usr_admin`, and (where
  present) `adm`; nobody else.
