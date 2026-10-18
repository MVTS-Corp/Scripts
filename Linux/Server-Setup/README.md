README.md v1.7.0 (Last Rev: 2026-10-18)

# Server-Setup

## Overview

Baseline provisioning for a freshly installed Linux server, so every new
box starts from the same known-good state instead of being set up by
hand from memory each time. One run of `setup-server.sh` does everything
below, detecting the host distro and adapting package names/mechanisms
accordingly. Supports Debian-based distros (Debian, Ubuntu, Mint, ...)
today, with Fedora and RHEL-family distros (RHEL, CentOS, Rocky,
AlmaLinux) also detected and supported.

- Runs a full operating system update first (`apt full-upgrade`, or `dnf upgrade`), so everything after it installs against current packages. `--skip-os-update` skips it. The final summary tells you if the host needs a reboot afterward.
- Installs what a daily-use production server needs, including `curl` itself
  (some minimal images ship without it, so it is installed first). The
  essentials must install: `curl`, `ca-certificates`, `sudo`, `tar`, `unzip`,
  `openssh-server`, `acl`, `net-tools`, DNS lookup tools (`dnsutils` or
  `bind-utils`), `NetworkManager`, `iproute`, `procps`. A newly installed SSH
  server is started; one already there is left as the admin set it. Then the
  usual admin tools, best effort (one a repository lacks is skipped with a
  note): `wget`, `gnupg`, `zip`, `bzip2`, `xz`, `vim`, `nano`, `less`, `htop`,
  `tmux`, `git`, `rsync`, `jq`, `lsof`, `psmisc`, `ping`, `traceroute`, `mtr`,
  `tcpdump`, `pciutils`, bash completion, man pages, `logrotate`, and
  `smartmontools` on real hardware. `--skip-extra-tools` installs only the
  essentials.
- Offers to change the host name. You enter the full name including the
  domain in one line (for example `server01.example.com`), or pass
  `--hostname`. Unattended runs leave the name alone unless `--hostname`
  is given. See [Host name](#host-name) below.
- Sets the system timezone (default `America/New_York`, overridable).
- Sets the time servers to the preferred set by default (Cloudflare, the
  NTP Pool, NIST), through `Linux/NTP-Config/configure-ntp-server.sh`. An
  interactive run asks first and lets you decline or open NTP-Config's menu
  to choose something else, such as a pool for your own country. See
  [Time Synchronization](#time-synchronization-ntp) below.
- Installs and enables Cockpit, opening the firewall for it if a host
  firewall (`firewalld` or `ufw`) is active.
- On Debian/Ubuntu hosts using netplan, sets `renderer: NetworkManager`
  in the netplan config so Cockpit's networking UI can actually manage
  the interfaces. No-op on Fedora/RHEL (no netplan there) and on hosts
  not using netplan at all. On hosts that build their initramfs with
  dracut (Ubuntu 26.04), it also keeps networking out of the initramfs
  (see [netplan](#netplan-debianubuntu-only) below for why).
- Applies a baseline host firewall through `Linux/Firewall-Config`: all inbound
  traffic blocked except SSH (rate limited) and Cockpit, with an optional
  management subnet. See [Security baselines](#security-baselines).
- Hardens SSH with a drop-in, installs fail2ban with an sshd jail, keeps the
  journal across reboots, and installs hypervisor guest tools on VMs.
- Enables unattended OS updates (`unattended-upgrades` on Debian/Ubuntu,
  `dnf-automatic` with `apply_updates = yes` on Fedora/RHEL).
- Creates the `usr_admin` group (GID 3000) and adds `root` plus the
  admin user (optional; `root` only if none), with recursive read/write/execute ACLs on
  `/opt` (including a default ACL so new files inherit it). This step
  delegates to `Linux/Group-MGMT/create-usr_admin-group.sh` rather than
  duplicating that logic - see that folder's README for details. If the
  group doesn't already exist, you're asked to confirm creating it
  specifically (separate from the one overall "Proceed?" prompt);
  declining skips just this step - every other part of provisioning
  still runs. If the group already exists, no prompt is shown and
  membership is just ensured, since nothing new is being created. An interactive run then shows who is in the group and which other local
  users exist, and asks whether to add more of them (usernames, or `all`) or
  carry on as is; `--usr-admin-user NAMES` gives them up front.
- Logs every run to a file, not just the terminal, so a failure during
  an unattended/RMM invocation still leaves a record. The log directory
  is root-only (mode 750) by default; `usr_admin` (once created, above)
  is also granted read access, alongside the `adm` group where present.

Every step is idempotent - safe to re-run against a host that's already
been set up, whether to pick up a change or just to confirm nothing
drifted.

In an interactive run, it first prints a numbered plan of the steps in the
order they will run, tailored to the host (packages for its distro family,
what the time step will do given any `--ntp-*` flags, whether a firewall
port will be opened, whether netplan/dracut apply, whether `usr_admin`
already exists), and asks "Proceed?" before changing anything. `--yes`
skips the plan and the prompt.

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

It also calls sibling tools in this repo rather than duplicating them:
`../Group-MGMT/create-usr_admin-group.sh` (the `usr_admin` step),
`../NTP-Config/configure-ntp-server.sh` (the time synchronization step), and
`../Firewall-Config/configure-firewall.sh` (the firewall step); the optional
`../Updates/install.sh` and `../Notifications/install.sh` are handed off to
only on request. The first three are used from the sibling folder when present (the 1-click install and
a full clone always have them) and fetched from GitHub otherwise.

Options for the time synchronization step (see `--help` for all options):

| Option | Meaning |
| --- | --- |
| `--skip-ntp` | Skip the step entirely. |
| `--ntp-sources V` | Set the time sources without prompting: `native`, `preferred` (the default), `pool:ZONE` (a country code such as `pool:de`, or a continent such as `pool:europe`), or a comma separated list of hostnames/IPs. |
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
`--admin-user`, it asks, and a blank answer means `root` only):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Server-Setup/bootstrap.sh)"
```

Or naming a different admin user (`bootstrap` is just the script's `$0`
placeholder and must be there):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Server-Setup/bootstrap.sh)" bootstrap --admin-user jsmith
```

Non-interactive (RMM/automation), confirmation given up front (add
`--admin-user`, `--hostname`, and `--ntp-sources` as needed):

```bash
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Server-Setup/bootstrap.sh | sudo bash -s -- --yes --hostname web01.example.com
```

Do not use `curl ... | sudo bash` without `--yes`. Piping into sudo leaves
the script outside its terminal's foreground process group on newer sudo
(seen on Ubuntu 26.04), so any prompt hangs or is refused. With `--yes`
nothing ever prompts (the admin user comes from `--admin-user`, or from
the invoking sudo user), so the pipe form is safe there.

On a host without `curl`, use `wget` for the one-liner instead (the
installer then installs `curl` itself):

```bash
wget -qO- https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Server-Setup/bootstrap.sh | sudo bash -s -- --yes
```

If you'd rather inspect the code before running it as root, clone and
run manually instead:

```bash
git clone https://github.com/MVTS-Corp/Scripts.git
cd Scripts/Linux/Server-Setup
sudo ./setup-server.sh --admin-user jsmith
```

The admin user is optional. If you name one, it must already exist on the
host - this script does not create local user accounts, only the
`usr_admin` group and its permissions. With none, `usr_admin` holds `root`
only; re-run with `--admin-user NAME` later to add someone.

## After Install Configuration

### Cockpit

Reachable at `https://<host>:9090` once the script completes. If a host
firewall is active, TCP 9090 was opened automatically; if you add a
firewall later, allow that port for Cockpit yourself.

### Host name

The step runs after the base packages. It shows the current name, and in an
interactive run asks **"Do you want to change the host name of this
server?"** (default: no). If yes, type the full name including the domain in
one line, for example `server01.example.com`; it is checked (letters, digits
and hyphens in each part, parts separated by dots) and you are asked again if
it is not valid. A blank answer keeps the current name. `--hostname FQDN`
gives the answer up front and is how an unattended run changes it.

The static host name is set to the full name you gave. On Debian/Ubuntu the
`127.0.1.1` line in `/etc/hosts` is updated to match (a timestamped backup is
left alongside it) so the new name still resolves locally. Nothing reboots;
open shell sessions show the new name after the next login.

### Time Synchronization (NTP)

This step runs right after the timezone and the host name, so the clock is right for the TLS
and package operations that follow. It first prints the current state: the
active time daemon, whether the clock is synchronized, and (when chrony is
installed) NTP-Config's full status report of sources, allowed subnets,
stratum lock, and `chronyc` output. If chrony is not installed yet, it says
so and shows what `systemd-timesyncd` is using instead.

Then, in an interactive run, it asks **"Set the time servers to the preferred
set (time.cloudflare.com, us.pool.ntp.org, time.nist.gov)?"** (default: yes).

- **Yes:** the preferred set is applied through NTP-Config (installing chrony
  first if it is missing).
- **No:** it asks whether you want to change the configuration yourself
  (default: yes) and, if so, starts NTP-Config's interactive menu. Installing
  chrony (if missing), choosing upstream sources (OS default, a NTP Pool
  for any country or region, the preferred set, or your own servers),
  allowed subnets, and a stratum lock all happen there. Answer no to that
  too and nothing is changed or installed. When you choose Exit with changes still pending, the
  tool offers to apply them and restart chrony (default yes), restoring its
  backup if chrony rejects the new config.

Unattended runs (`--yes`, or no terminal) have nobody to ask, so they apply
the preferred set unless `--ntp-sources` names something else (`native`,
`pool:de`, `pool:europe`, your own servers, ...). `--ntp-allow` and
`--ntp-stratum` add to it. Pass `--skip-ntp` to leave the time configuration
alone, for example on a re-run of a host you customized by hand.

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

### Security baselines

Each of these is its own step with a `--skip-*` flag, and a failure in one is
flagged in the final summary (exit code `3`) without stopping the run.

**Firewall** (`--skip-firewall`, `--mgmt-subnet`, `--allow-port`). Runs right
after the timezone, before Cockpit and NTP, so their rules land in an active
firewall. It calls `Linux/Firewall-Config/configure-firewall.sh` (see its
README): ufw on Debian/Ubuntu, firewalld on RHEL/Fedora; default-deny inbound;
SSH allowed on the port `sshd` really uses, rate limited on ufw; Cockpit
allowed. An interactive run asks **"Limit SSH and Cockpit to a management
subnet?"** (blank means reachable from anywhere); `--mgmt-subnet 10.0.0.0/24`
gives the answer up front, and `--allow-port 443/tcp` opens more ports. The SSH
rules go in before the firewall is switched on, and it refuses to apply a
restriction that would cut off a session that is open now. Docker publishes
ports around the firewall; see the Firewall-Config README.

**SSH hardening** (`--skip-ssh-hardening`, `--ssh-disable-passwords`). Writes
`/etc/ssh/sshd_config.d/00-mvts-hardening.conf` (never an edit of
`sshd_config`): 4 authentication attempts, 30 second login grace, no X11
forwarding, no empty passwords, keepalives. The `00-` name matters: sshd keeps
the first value it reads, so this must sort ahead of files like cloud-init's
`50-cloud-init.conf`. Two settings can lock people out, so they are guarded:
root SSH login is turned off only when the admin user can use sudo, and
password logins only when you ask (`--ssh-disable-passwords`, or yes at the
prompt, default no) and the admin user already has an SSH key. The file is
checked with `sshd -t` and reverted if rejected, the service is reloaded (open
sessions are not interrupted), and the settings are confirmed in `sshd -T`.

**fail2ban** (`--skip-fail2ban`). Installs fail2ban with an sshd jail: 5
failures within 10 minutes bans the address for 1 hour, and each repeat
offense doubles the ban up to 1 week. The management subnet is never banned.
Bans go through ufw when ufw is active. On RHEL it needs the EPEL repository.

**Guest tools** (`--skip-guest-tools`). Detects the hypervisor with
`systemd-detect-virt` and installs `qemu-guest-agent` (KVM/Proxmox),
`open-vm-tools` (VMware), or the Hyper-V daemons. Nothing on physical hosts or
containers.

**Logging** (`--skip-logging`). Keeps the systemd journal across reboots,
capped at 1G and 3 months, in `/etc/systemd/journald.conf.d/`.

**Scheduled updates** (`--updates auto|reporting|skip`). `auto` (default) is
unattended-upgrades or dnf-automatic with no email. `reporting` runs the
`Linux/Updates` installer instead, for scheduled updates with an emailed
report; it asks its own questions, so it needs a terminal. Do not run both
updaters: with `reporting`, remove unattended-upgrades. An interactive run then
offers to install `Linux/Notifications` (the `send-alert` command), default no.

### Operating system update

The first step. On Debian/Ubuntu it refreshes the package lists and runs
`apt-get full-upgrade` non-interactively (keeping the local version of any
configuration file you changed, and waiting for the package lock if cloud-init
or unattended-upgrades holds it). On Fedora/RHEL it runs `dnf upgrade`. On a
fresh install this is where most of the run's time goes. Pass
`--skip-os-update` to leave it out. The host is not rebooted; if updates need
one, the final summary says so.

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
| `/etc/ssh/sshd_config.d/00-mvts-hardening.conf` | SSH hardening drop-in (see Security baselines) |
| `/etc/fail2ban/jail.d/50-mvts-baseline.local` | fail2ban baseline: sshd jail, escalating bans |
| `/etc/systemd/journald.conf.d/50-mvts-baseline.conf` | Persistent journal with a size and age cap |

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

## Release Notes

Newest first. Versions are `setup-server.sh` versions; the full technical
detail for each is in the changelog at the top of the script. Server-Setup
runs straight from `main` and is not tagged; the release channels described
in the top-level README apply to NTP-Config, which this tool calls.

### v1.7.0 (2026-10-18)

- `usr_admin`: an interactive run asks whether to add other local users to the
  group (or carry on as is); `--usr-admin-user` does it unattended. Before, only
  root and the admin user were ever added.
- `curl` is installed first when the host lacks it, instead of stopping. The
  four `bootstrap.sh` installers (Server-Setup, NTP-Config, Updates,
  Notifications) also install `curl` and `tar` themselves.
- Base packages are now a production baseline: essentials that must install
  (including `sudo` and `openssh-server`) plus best-effort admin tools (`htop`,
  `tmux`, `git`, `vim`, `rsync`, `jq`, ...). `--skip-extra-tools` keeps it to the
  essentials.

### v1.6.0 (2026-10-17)

- Firewall step: baseline ufw or firewalld through the new
  `Linux/Firewall-Config` tool (default-deny inbound, SSH rate limited, Cockpit,
  optional `--mgmt-subnet` and `--allow-port`, lockout protection).
- SSH hardening drop-in, fail2ban with an escalating-ban sshd jail, persistent
  journald, and hypervisor guest tools, each with a `--skip-*` flag.
- `--updates reporting` hands off to `Linux/Updates` for emailed update reports;
  an interactive run can also install `Linux/Notifications`.
- Optional-step failures are flagged for review (exit code `3`) instead of
  stopping the run.

### v1.5.0 (2026-10-17)

Fixes from issue #3, found on Ubuntu Server 2026 LTS.

- The admin user is optional. Without `--admin-user` (and no sudo user to
  default to) the run no longer stops: a blank answer, or no terminal, means
  `usr_admin` holds `root` only.
- New first step: a full operating system update, before anything else is
  installed. `--skip-os-update` skips it, and the final summary says when the
  host needs a reboot.
- New step: offers to change the host name, entered as one full name with the
  domain (`server01.example.com`), or `--hostname`.
- The time servers default to the preferred set. Interactive runs ask first
  and can decline or open NTP-Config's menu; unattended runs apply it unless
  `--ntp-sources` or `--skip-ntp` says otherwise. Previously `--yes` alone left
  the time servers untouched.
- Pairs with NTP-Config v1.8.0, which replaces its USA-only pool choice with a
  pool for any country or region.

### v1.4.1 (2026-09-19)

- The "Proceed?" dialog is now a numbered plan of the steps in the order
  they run, tailored to the host: which packages, what the time step will do
  (including any `--ntp-*` flags), whether a firewall port is opened for
  Cockpit, whether netplan and dracut apply, and whether `usr_admin` already
  exists. It also states that nothing reboots the host or applies a network
  change live.

### v1.4.0 (2026-09-19)

- New time synchronization (NTP) step after the timezone: shows the current
  time server configuration, asks whether to change it (default: no), and if
  yes hands off to NTP-Config's menu. Needs NTP-Config `ntp-config-v1.1.0`
  or later, which makes the menu offer to apply pending changes on exit.
- New options: `--skip-ntp`, `--ntp-sources`, `--ntp-allow`, `--ntp-stratum`.
  `--yes` alone only shows the time configuration and changes nothing.
- If the NTP step fails, you choose to exit or skip it. Either way a record
  is appended to `/var/log/server-setup/audit.log`. A skipped step is flagged
  in the final summary and the run exits `3` instead of `0`.

### v1.3.0 (2026-09-19)

- On dracut hosts (Ubuntu 26.04), networking is kept out of the initramfs
  when netplan is switched to NetworkManager, so the host boots on its static
  address instead of a leftover DHCP one.

### v1.2.2 (2026-09-18)

- The netplan renderer edit keeps the file's original mode and owner, which
  stops netplan warning that permissions are too open.

### v1.2.1 (2026-09-18)

- Fixed a hang at the Cockpit install: `timeout` calls now run in the
  script's own process group so Ctrl+C works.

### v1.2.0 (2026-09-18)

- `--admin-user` defaults to the user who ran `sudo`, so an unattended run
  can pass `--yes` alone.

### v1.1.2 (2026-09-15)

- Fixed a hang where apt-listchanges or needrestart waited on a prompt
  nothing could answer.

### v1.1.1 (2026-08-22)

- Creating the `usr_admin` group can be declined without skipping the rest of
  provisioning.

### v1.1.0 (2026-08-22)

- Every run is logged to `/var/log/server-setup/`, kept 180 days, root-only by
  default with read access for `usr_admin` and `adm`.

### v1.0.1 (2026-08-10)

- Failures inside functions now stop the run; remaining external calls have
  timeouts; fixed a case where the netplan renderer edit could report success
  without making the change.

### v1.0.0 (2026-08-09)

- Initial release: base packages, timezone, Cockpit, netplan renderer,
  unattended updates, and the `usr_admin` group with ACLs on `/opt`.
