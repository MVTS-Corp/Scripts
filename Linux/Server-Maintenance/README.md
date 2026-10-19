README.md v1.0.0 (Last Rev: 2026-10-18)

# Server-Maintenance

## Overview

Scheduled maintenance for Linux servers, on premises or in the cloud, with
a human in control of every disruptive change:

- **OS updates** in a maintenance window (`apt-get full-upgrade`, or
  `dnf`/`yum upgrade`), all updates or security only.
- **Container image updates** for images pinned in Docker Compose files.
  A release has to be out for a soak period (default 7 days), and by default
  you approve the exact tag first. Projects are updated **one at a time**,
  each is health checked, and a failure rolls the tag back automatically.
- **Controlled reboots**: only when the OS says one is required, only when
  nothing else failed, and only after every DKMS module (for example a
  backup agent's snapshot driver) built for the new kernel. After the
  reboot, a post-boot check confirms the containers came back.
- **Never silent**: failures are emailed through `send-alert`
  (Linux/Notifications), every job pings an Uptime Kuma push monitor on
  success (a missed ping catches a job that stopped running), and a status
  file plus `server-maintenance status --oneline` give an RMM tool a one-line
  summary.

It does not use Watchtower, floating `latest` tags, or any image's own
self-update. Every version change is recorded in a compose file, a backup,
and a history log.

Supported: Debian/Ubuntu family and Fedora/RHEL family (same detection as
Linux/Updates), with systemd. Docker is optional; without it only the OS
side runs.

## Files

- `bootstrap.sh` - one-line remote installer: downloads a snapshot of this
  repo at a release channel or tag and runs `install.sh`.
- `install.sh` - installs dependencies (`jq`, `curl`, `acl`, the
  reboot-required helper), deploys `bin/` and `lib/` to
  `/opt/server-maintenance`, writes the config, installs the systemd units.
  Idempotent; re-run it to change settings. `--defaults` for unattended
  installs.
- `uninstall.sh` - removes the units, scripts and command; asks before
  deleting config, state and logs. Never touches compose files or
  containers.
- `config.conf.example` - every setting, commented. Installed as
  `/etc/server-maintenance/config.conf`.
- `bin/server-maintenance.sh` - the command (linked as
  `/usr/local/sbin/server-maintenance`).
- `lib/` - `common.sh` (logging, file safety, HTTP), `config.sh`
  (defaults and validation), `notify.sh` (alerts and heartbeats), `os.sh`
  (packages, reboot-required, DKMS), `containers.sh` (releases, approvals,
  compose edits, health checks, rollback), `distro.sh` (same as
  Linux/Updates).
- `systemd/` - unit templates (`OnCalendar` filled in by `install.sh`).
- `examples/` - sanitized compose layouts that work with this tool: a shared
  cloudflared definition extended by one project per tunnel, and a
  Vaultwarden project with a literally pinned tag.

### Commands

| Command | What It Does |
| --- | --- |
| `check` | Daily, read-only. Pending OS updates, reboot state, disk space, failed systemd units, container releases. Emails only when something needs attention or an update newly passed its soak period. |
| `run [--no-reboot] [--skip-os] [--skip-containers]` | Maintenance window. OS updates, then approved (or eligible) image updates, then a reboot if required. |
| `post-boot` | Runs at every boot; does nothing unless verifying a reboot this tool started. |
| `os-update [--no-reboot]` | Same as `run --skip-containers`. |
| `containers status` | Pinned, newest, eligible and approved tag per image, containers per project, recent history. |
| `containers approve <image> <tag>` | Allows `run` to apply `<tag>` once it is past the soak period. Checks the tag is a real release, newer than the pinned one, and present in the registry. |
| `containers revoke <image>` | Removes an approval. |
| `containers apply [--now <image> [tag]]` | Applies now. `--now` skips the soak period and approval (for a security advisory) but keeps the health check and rollback. |
| `status [--oneline]` | Last results from the status file. No network, no root needed if the file is readable. |
| `validate` | Checks the config, compose files, project discovery and release lookup. |
| `test-alert [--heartbeat]` | Sends a test email through the real alert path (and test heartbeats). |

Exit codes: `0` success, or another job holds the lock (the second run exits
without changes); `1` failure; `2` invalid command line.

## Quick Start

Install Linux/Notifications first so failures can be emailed:

```bash
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Notifications/bootstrap.sh | sudo bash
```

Then this tool, from the `stable` release channel:

```bash
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/stable/Linux/Server-Maintenance/bootstrap.sh | sudo bash
```

The installer asks for the update mode, reboot policy, maintenance window,
daily check time, container settings and the Uptime Kuma push URLs. Every
prompt defaults to the current value on a re-run.

To inspect the code before running it as root, clone and run it instead:

```bash
git clone https://github.com/MVTS-Corp/Scripts.git
cd Scripts/Linux/Server-Maintenance
sudo ./install.sh
```

Unattended install (an RMM script with no terminal; keeps an existing config
or writes the default one):

```bash
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/stable/Linux/Server-Maintenance/bootstrap.sh | sudo bash -s -- --defaults
```

### Release Channel

This tool runs as root and restarts production containers, so hosts install
it from the `stable` channel (or a pinned `server-maintenance-vX.Y.Z` tag),
never from `main`. See the root README's "Releases and Channels". It does
**not** update itself: a new release reaches a host only when someone
re-runs the bootstrap command there. Re-running it keeps whatever channel or
tag the host already follows; pass `--ref <tag>` to move it.

Until the first `server-maintenance-v1.0.0` release is cut, `stable` does not
contain this folder. Test from a clone, or with `--ref main` on a test host
only.

## After Install Configuration

### Managing Container Images

Add each image to `MANAGED_IMAGES` with an `IMAGE_<id>_*` block in
`/etc/server-maintenance/config.conf` (commented examples are in the file),
then run:

```bash
sudo server-maintenance validate
sudo server-maintenance containers status
```

Requirements for a managed image:

1. The tag is pinned **literally** in exactly one compose file
   (`image: cloudflare/cloudflared:2026.10.1`), never through a
   `${VARIABLE}` from `.env`. The tool never reads `.env` files, so secrets
   stay with Docker Compose.
2. The upstream project publishes GitHub releases whose tags match the image
   tags (optionally after removing a prefix such as `v`).
3. A health check that proves the service works, not just that the
   container exists: `log-match:<count>:<text>`, `docker-health`,
   `http:<url>` or `running:<seconds>`.

Projects are found automatically: every compose file under
`PROJECT_SEARCH_DIRS` that `extends` the pinned file (relative or absolute
path), or the pinned file's own project when nothing extends it. Set
`IMAGE_<id>_PROJECTS` to list them explicitly (and fix the update order).
Every project is validated with `docker compose config -q` before and after
the tag edit; the output of `docker compose config` is never printed or
logged, because it contains interpolated secrets.

### Approval Workflow

With `REQUIRE_APPROVAL=true` (the default):

1. `check` (daily) emails once when a release is past the soak period,
   including the exact approve command.
2. Review the release notes, then:
   ```bash
   sudo server-maintenance containers approve cloudflared 2026.10.2
   ```
3. The next maintenance window applies it. An approval given during the
   soak period waits for the soak period to end.

For a security advisory, skip the wait (the health check and rollback still
apply):

```bash
sudo server-maintenance containers apply --now cloudflared 2026.10.3
```

### What A Failed Image Update Does

For the failing project: the compose file is restored from its backup,
every project already updated in that run is brought back up on the old tag
and health checked again, projects not yet reached are never touched, and
the run stops with an alert that includes the health check detail, the
container's last log lines and network diagnostics. If the rollback itself
fails, the alert subject says so. Backups of the last 10 edits are kept in
`/var/lib/server-maintenance/backups/<id>/`, and the previous image tag is
kept locally (`KEEP_OLD_IMAGES`) for a quick manual rollback.

Network diagnostics distinguish a local DNS filter returning a different
answer from a public resolver (compared when `dig` is installed) from a TCP
connection that fails, since the fixes differ (allow-list the name versus
open the network path). List the names to check in `IMAGE_<id>_DIAG_HOSTS`.

### Schedules

Set by the installer, stored in the config as `CHECK_CALENDAR`,
`RUN_CALENDAR` and `RUN_RANDOM_DELAY` (re-run `install.sh` after a hand
edit). systemd matches a weekday and a date range together, so
`Sun *-*-01..07 03:00` is the first Sunday of each month (cron would read
that as every Sunday plus days 1 to 7). Check the next runs with:

```bash
systemctl list-timers 'server-maintenance-*'
```

The maintenance window timer is deliberately not `Persistent`: a window
missed while the host was off waits for the next one, rather than updating
and rebooting at a random time after boot. The daily check is persistent.

Give hosts that back each other up different windows, or use
`RUN_RANDOM_DELAY` so they do not reboot at the same moment.

### Heartbeats (Uptime Kuma)

Create two **Push** monitors per host and paste their URLs at the installer
prompts (stored as `HEARTBEAT_URL_CHECK` and `HEARTBEAT_URL_RUN`; treat them
as secrets). Set each monitor's interval longer than its job's schedule plus
`RUN_RANDOM_DELAY` and slack, for example 26 hours for the daily check and
the window length plus a day for the maintenance window. Jobs send
`status=down` on failure, so a failure shows at once rather than at the next
missed interval. After a reboot, the run heartbeat is sent by the post-boot
check, once the host is verified.

### Snapshots Before Changes

`PRE_CHANGE_HOOK` runs once before the first change of a run (OS packages
or an image). A non-zero exit stops the run with nothing changed. It is
meant for a host-level container snapshot tool once one is ready; leave it
empty until then.

### RMM Integration (Action1 And Similar)

`/var/lib/server-maintenance/status.env` holds the last results, and
`server-maintenance status --oneline` prints them on one line, exiting 1
when the last check, run or post-boot failed:

```
OK | server-maintenance v1.0.0 | check ok 2026-10-18 07:04:12 EDT | run ok ... | OS pending 0 (0 security) | reboot no | images cloudflared=2026.10.2
```

An RMM can run that as a scheduled script and show or alert on the output.
Action1's documented way to set a custom attribute from a script is a
PowerShell cmdlet; whether its Linux agent can set one from Bash is not
confirmed (see Tested Versus Assumed), so the status command is the
integration point for now.

### Coexistence Notes

- **unattended-upgrades** (Ubuntu default) can stay enabled. It applies
  security updates daily and does not reboot by default; this tool waits up
  to `APT_LOCK_TIMEOUT_SECONDS` for its apt lock.
- **Linux/Updates** also patches the OS from cron. Use one or the other on a
  host, not both.
- **Linux/Firewall-Config** and **Linux/Server-Setup** are unrelated to this
  tool, but note that they apply ufw and open Cockpit; do not run them on a
  host that uses its own nftables table alongside Docker, or that keeps
  Cockpit on localhost only.

### Tested Versus Assumed

Tested (2026-10-18, Ubuntu 26.04 under WSL, in a private mount namespace,
with Docker, apt, curl, send-alert, shutdown and systemctl replaced by
stubs, plus shellcheck 0.11.0 on every script):

- `check`: no newer release (exit 0, no email, heartbeat up); release in
  soak (reported with its eligible date, nothing changed); prereleases and
  drafts ignored; eligible release emailed once, not repeated; GitHub
  unreachable (exit 1, alert with diagnostics, heartbeat down); low disk
  and failed units alerted.
- `run`/`apply`: no approval (nothing changed); approve validation (unknown,
  older, unsafe, unmanaged tags refused); approved release still in soak not
  applied; success (both tunnel projects updated in order, backup, approval
  cleared, old images pruned, comments and quoting preserved); a broken
  release (first project fails, rolled back, second never touched, alert);
  tag missing from the registry; validation failure; failing HTTP health
  check; overlapping runs; pre-change hook failure; OS update failure (no
  image changes, no reboot); config refused when group/other readable or
  invalid; variable tags refused.
- Reboot path: OS updates, reboot scheduled with a marker, post-boot success
  and post-boot with a container that did not come back.
- `status --oneline`, `containers status`, `validate`.

Assumed (not yet verified on a real host):

- Behavior against a real Docker daemon and Compose plugin, including
  `docker manifest inspect` against Docker Hub and the log text
  `Registered tunnel connection` from current cloudflared releases.
- `install.sh` and `bootstrap.sh` end to end on a real systemd host, and the
  rendered timers firing at the expected times.
- The DKMS check against a real out-of-tree module.
- The Fedora/RHEL paths (logic shared with Linux/Updates, not run here).
- Action1 custom attributes from a Bash script on its Linux agent.

Run it first on a test VM: `validate`, `check`, `containers apply --now` on
a non-critical image, then one `run` with `--no-reboot`, then a full `run`.

## Troubleshooting

- **Logs** - one file per job run in `/var/log/server-maintenance/`
  (`check-*.log`, `run-*.log`, `post-boot-*.log`, `apply-*.log`), kept
  `LOG_RETENTION_DAYS` days. systemd also keeps the output:
  `journalctl -u server-maintenance-run`.
- **History** - `/var/lib/server-maintenance/history.log` records every
  image update and rollback.
- **"Refusing to load an unsafe config file"** - the config must be
  root-owned and mode 600: `sudo chmod 600 /etc/server-maintenance/config.conf`.
- **"the tag ... is set through a variable"** - pin the tag literally on the
  `image:` line; this tool never reads `.env`.
- **"could not fetch releases ... from the GitHub API"** - check outbound
  HTTPS to `api.github.com`; the alert includes a DNS versus network
  diagnosis. Unauthenticated API calls are limited to 60 per hour per IP;
  set `GITHUB_TOKEN_FILE` if many hosts share one address.
- **"Another server-maintenance job holds the lock"** - a job is already
  running (`systemctl status 'server-maintenance-*'`); the second one exits
  without changes.
- **Reboot required but not rebooting** - see the run email: the policy is
  `never`, `--no-reboot` was given, something failed, or a DKMS module did
  not build for the new kernel (`dkms status`).
- **No emails** - `send-alert --self-test`, then
  `sudo server-maintenance test-alert`; see Linux/Notifications.
- **A host should not run a window** - `sudo systemctl disable --now
  server-maintenance-run.timer`; re-run `install.sh` to enable it again.
