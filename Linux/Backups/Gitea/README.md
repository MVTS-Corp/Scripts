README.md v4.2.2 (Last Rev: 2026-08-12)

# Gitea Backup and Restore

## Overview

`gitea-backup.sh` runs Gitea's built-in `gitea dump` inside the running
Gitea container (bundling repos, LFS data, the database dump, and config
into one archive), verifies the result, and ships it to a NAS. This gives
Gitea an independent recovery path separate from the Docker host's
full-container-set backup: a bad host backup, a host rebuild, or an
environmental event at the primary site does not take out your only copy
of Gitea.

`gitea dump` is used instead of a hand-rolled DB dump + volume tar because
it bundles repos, LFS data, a database dump, and app config into one
archive using Gitea's own DB connection from `app.ini` - the backup script
never needs to independently know or store database credentials.

`gitea-restore.sh` is the other half: it can fetch an archive back from
the NAS (or use a local file), verify it, and either run a real restore
into the production container or an on-demand test-restore into an
isolated, throwaway container that never touches production data, volumes,
or network - so "can we actually restore from this backup" is a fact you
can check on a schedule, not an assumption. See "Restore" below.

How the two scripts actually talk to the NAS is pluggable - see
"Transport" below.

## Transport

`TRANSFER_METHOD` in the config selects how both scripts reach the NAS.
All three options are implemented in `lib/transport.sh`, which both
scripts source; neither script has its own per-method logic.

- **`sftp` (default).** Runs over SSH but needs no remote command
  execution capability at all. This matters because many NAS platforms
  (Synology DSM confirmed) restrict full interactive/command SSH access to
  administrator accounts, while SFTP is commonly a separate,
  permission-scoped service that a normal least-privilege account can use
  even though it can't get a shell. Still encrypted in transit, still uses
  a dedicated key and known_hosts file.
- **`rsync-ssh`.** Full rsync over SSH. Needs an account with real SSH
  command-execution access - use this on targets where that access is
  actually available (many non-NAS Linux SSH hosts, or a NAS without the
  admin-only SSH restriction above). Gets rsync's delta/resume transfer
  behavior that the other two methods don't have.
- **`rsync-daemon`.** The NAS's own native rsync service (no SSH at all -
  a separate daemon-specific username/password, commonly what a NAS's
  built-in "rsync account" feature sets up). Transmits file contents
  unencrypted unless separately tunneled - only use this where that is an
  accepted tradeoff, e.g. staying entirely on a trusted internal network.

Not implemented: SMB, NFS, and FTP. SMB support would need a different
architecture (mount the share, then operate on local paths, rather than
remote batch commands) rather than fitting this same interface; NFS has no
practical encryption without a full Kerberos setup; FTP is strictly worse
than SFTP wherever SFTP is available. Worth revisiting if a real need for
one of these comes up, but none were needed for what this tool actually
does.

**Tradeoffs that apply regardless of which method you pick:** `sftp` and
`rsync-daemon` have no delta/resume transfer the way `rsync-ssh`'s
`--partial` does - a retry after a failed transfer re-sends the whole file
from scratch. And independent post-transfer integrity verification is an
optional, more expensive re-fetch-and-compare (`VERIFY_TRANSFER`) rather
than a cheap remote checksum command, since not every method can run a
remote command at all. Neither matters much for what this tool actually
does - one full new file per run, not an incremental sync of an existing
large tree - which is why both tradeoffs were accepted rather than
avoided.

## Files

- `gitea-backup.sh` - the backup script. Run with `--check` for a
  dependency/pre-flight/connectivity test only, `--dry-run` to run the dump
  and verification but skip the NAS transfer and any deletions, or with no
  arguments for a normal run.
- `gitea-restore.sh` - the restore script. Run with `--check`, `--list`
  (show archives on the NAS), `--dry-run` (fetch + verify only),
  `--test-restore` (full restore into an isolated throwaway container -
  safe to run any time, including on a schedule), or `--restore --confirm`
  for the real, disruptive restore into the production container. See
  "Restore" below.
- `lib/transport.sh` - the NAS transport backend for all three
  `TRANSFER_METHOD` options (see "Transport" above). Sourced by both
  scripts; must be deployed alongside them, not left behind - see Quick
  Start step 5.
- `gitea-backup.conf` - all site-specific values shared by both scripts
  (container name, NAS host, paths, retention, restore settings,
  notification settings). See "Configuration Reference" below for every
  variable; never edit either script for a new deployment, only this
  file.

## Configuration Reference

`gitea-backup.conf` is the single source of truth for every site-specific
value both scripts use - nothing else is hardcoded. Every path below
(SSH key or password file, known_hosts, staging directories, log file)
can point anywhere you like; the values in the shipped template and in
the Quick Start walkthrough below are just the suggested default layout:
everything for this tool - scripts, `lib/`, config, SSH key, known_hosts,
rsync-daemon password file - lives together under `/opt/gitea-backup`,
with only staging (`/var/backups`) and logs (`/var/log`) outside it. The
only rule is consistency: wherever you actually put a file, set the
matching variable to that exact path.

The config file's own location is equally flexible. Both scripts default
to reading `/opt/gitea-backup/gitea-backup.conf`, but this is overridable
with the `GITEA_BACKUP_CONF` environment variable:

```bash
GITEA_BACKUP_CONF=/etc/gitea-backup/gitea-backup.conf /opt/gitea-backup/gitea-backup.sh --check
```

If you'd rather follow the traditional Linux convention of config/secrets
under `/etc` and code under `/opt` (what this repo's other tools -
Notifications, Updates - do), that works exactly as well: put
`gitea-backup.conf`, the SSH key, and known_hosts under `/etc/gitea-backup`
instead, point `NAS_SSH_KEY`/`NAS_KNOWN_HOSTS`/`RSYNC_DAEMON_PASSWORD_FILE`
at that path, and set `GITEA_BACKUP_CONF` (as a prefix on manual runs, or
exported in the crontab line) accordingly. Whichever layout you pick,
**pick one and use it consistently** - pointing some files at `/opt` and
others at `/etc` for the same deployment is what actually causes
`Config file not found` errors, since each script only ever looks in the
one place `GITEA_BACKUP_CONF` (or its default) tells it to.

### Container Identity

| Variable | Required? | What It Controls |
|---|---|---|
| `GITEA_CONTAINER_NAME` | Required, no default | Name (not ID) of the running Gitea container, e.g. `gitea`. |
| `GITEA_CONTAINER_USER` | Optional (`git`) | User `gitea dump` runs as inside the container - must match what the image actually uses. |
| `GITEA_APP_INI` | Optional (`/data/gitea/conf/app.ini`) | Path to `app.ini` inside the container. |
| `GITEA_CONTAINER_TMP` | Optional (`/data/gitea-dump-tmp`) | Scratch path inside the container where the dump is written before `docker cp` pulls it out. |
| `GITEA_REPO_ROOT` | Required for `gitea-restore.sh` only | Where Gitea stores repositories inside the container. See Quick Start step 1b - confirm, don't guess. |
| `DUMP_TIMEOUT` | Optional (`21600`, 6h) | Bounds the `gitea dump` step. See "Reliability" below. |

### Local Staging (on the Docker host, not the NAS)

| Variable | Required? | What It Controls |
|---|---|---|
| `STAGING_DIR` | Required (`/var/backups/gitea-staging`) | Where dumps are staged locally before transfer. Any writable path - created automatically if missing. |
| `STAGING_RETENTION_DAYS` | Required (`3`) | How long staged copies are kept locally. See "Retention" below. |

### NAS Transport - Common to Every Method

| Variable | Required? | What It Controls |
|---|---|---|
| `TRANSFER_METHOD` | Optional (`sftp`) | `sftp`, `rsync-ssh`, or `rsync-daemon`. See "Transport" above. |
| `NAS_SSH_HOST` | Required, no default | NAS hostname or IP. Used by every method - the "SSH" in the name is historical, not a claim about which protocol is in use. |
| `NAS_REMOTE_PATH` | Required, no default | For `sftp`/`rsync-ssh`: filesystem path on the NAS, not the SMB share name - see Quick Start step 1. For `rsync-daemon`: a path INSIDE `RSYNC_DAEMON_MODULE`, must NOT start with `/` - leave blank for the module's root. |
| `TRANSFER_TIMEOUT` | Required (`120`) | Per-attempt transfer stall timeout, seconds. |
| `MAX_TRANSFER_ATTEMPTS` | Required (`3`) | Bounded retry count for the NAS transfer. Each retry re-transfers the whole file except under `rsync-ssh` - see "Transport" above. |
| `VERIFY_TRANSFER` | Optional, blank by default | Set to `"yes"` to independently verify each transfer by re-fetching it and comparing checksums locally. Off by default - doubles the transfer. See "Transport" above and Troubleshooting. |

### `sftp` / `rsync-ssh` Only - SSH Connection

| Variable | Required? | What It Controls |
|---|---|---|
| `NAS_SSH_PORT` | Required (`22`) | SSH port on the NAS. |
| `NAS_SSH_USER` | Required (`gitea-backup`) | The dedicated NAS account from Quick Start step 2. |
| `NAS_SSH_KEY` | Required, no default | Path to the private key from Quick Start step 3. Any path - just keep it readable only by whoever runs this script, mode 600 or 400. |
| `NAS_KNOWN_HOSTS` | Required, no default | Path to the dedicated known_hosts file from Quick Start step 4. Any path. |
| `RSYNC_REMOTE_BIN` | `rsync-ssh` only, optional, blank by default | Full path to `rsync` on the NAS. Needed on platforms that don't put it on the SSH session's PATH (Synology DSM is a known case - try `/usr/bin/rsync`). Ignored for `sftp`. See Troubleshooting. |

### `rsync-daemon` Only

| Variable | Required? | What It Controls |
|---|---|---|
| `RSYNC_DAEMON_USER` | Required when `TRANSFER_METHOD=rsync-daemon` | Daemon-specific username from the NAS's own rsync service account management - separate from any SSH/login account. |
| `RSYNC_DAEMON_PASSWORD_FILE` | Required when `TRANSFER_METHOD=rsync-daemon` | Path to a file containing ONLY that account's password, mode 600 or 400. Never put the password directly in `gitea-backup.conf`. |
| `RSYNC_DAEMON_MODULE` | Required when `TRANSFER_METHOD=rsync-daemon` | The module name configured in the NAS's rsync service - not a filesystem path. |
| `RSYNC_DAEMON_PORT` | Optional (`873`) | Port the NAS's rsync daemon listens on. |

### Retention and Sanity Checks

| Variable | Required? | What It Controls |
|---|---|---|
| `RETENTION_DAYS` | Required (`30`) | How long dumps are kept on the NAS. See "Retention" below. |
| `MIN_DUMP_SIZE_BYTES` | Required (`1048576`) | A dump smaller than this is treated as suspicious and rejected. Roughly half your smallest known-good dump size. |

### Restore Only (`gitea-restore.sh`)

| Variable | Required? | What It Controls |
|---|---|---|
| `RESTORE_STAGING_DIR` | Optional (`${STAGING_DIR}/restore`) | Local staging for fetched/extracted archives during a restore. Any path. |
| `RESTORE_TIMEOUT` | Optional (`21600`) | Bounds each disruptive restore step. |
| `DB_RESTORE_CMD` | Optional, blank by default | Real `--restore` DB import hook. See "Restore" below - deliberately not guessed at. |
| `TEST_RESTORE_DB_CMD` | Optional, blank by default | `--test-restore`-only DB import hook, deliberately separate from `DB_RESTORE_CMD`. See "Restore" below. |
| `RESTORE_TEST_CONTAINER_PREFIX` | Optional (`gitea-test-restore`) | Name prefix for the throwaway `--test-restore` container. |
| `RESTORE_TEST_PORT` | Optional (`3080`) | Host port the throwaway `--test-restore` web UI is published on. |
| `RESTORE_TEST_DATA_MOUNT` | Optional (`/data`) | Volume mount point used for `--test-restore`. Adjust if your image doesn't use a single `/data` volume. |
| `RESTORE_TEST_IMAGE` | Optional, blank by default | Overrides which image `--test-restore` uses. Blank reuses whatever image the production container is currently running. |
| `RESTORE_TEST_HEALTH_GRACE_SECONDS` | Optional (`60`) | How long to wait after starting a restored container before checking it's still running. |

### Notifications

| Variable | Required? | What It Controls |
|---|---|---|
| `NOTIFY_EMAIL` | Optional, blank by default | Recipient for failure alerts. Blank disables email entirely. See "Notifications" below. |
| `MAIL_FROM` | Optional, blank by default | From address for alert emails. |
| `HEARTBEAT_URL` | Optional, blank by default | Uptime Kuma (or similar) push monitor URL. See "Notifications" below. |

### Logging

| Variable | Required? | What It Controls |
|---|---|---|
| `LOG_FILE` | Optional (`/var/log/gitea-backup.log`) | Where both scripts log, in addition to stdout. Any writable path; leave blank to log to stdout only. |

## Quick Start

The steps below deploy to the suggested default layout: everything under
one directory, `/opt/gitea-backup` (scripts, library, config, SSH key,
known_hosts), with `/var/...` for staging and logs. See "Configuration
Reference" above if you'd rather split config/secrets into `/etc` instead
- the same steps apply, just with your own paths and `GITEA_BACKUP_CONF`
set accordingly.

### 0. Get the Files

No clone needed - fetch just the files in this folder (including the
`lib/` subfolder both scripts require):

```bash
mkdir -p gitea-backup/lib && cd gitea-backup
BASE="https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Backups/Gitea"
for f in gitea-backup.sh gitea-restore.sh gitea-backup.conf README.md; do
    curl -fsSL "$BASE/$f" -o "$f"
done
curl -fsSL "$BASE/lib/transport.sh" -o lib/transport.sh
chmod +x gitea-backup.sh gitea-restore.sh
```

Prefer a full clone instead (e.g. to track future updates with `git
pull`, or to browse the rest of the repo)?

```bash
git clone https://github.com/MVTS-Corp/Scripts.git
cd Scripts/Linux/Backups/Gitea
```

### 1. Confirm the Remote Path

For `TRANSFER_METHOD=sftp` or `rsync-ssh`: if what you have is an SMB
share path (e.g. `\\nas-host\backups\Gitea`), the transport needs the
underlying filesystem path instead, which is usually different from the
share name. SSH into the NAS as an admin account and find it, for example:

```bash
ssh admin@<nas-host>
# Synology: shares typically live under /volume<N>/<ShareName>
ls -la "/volume1/backups/Gitea"
```

If that path doesn't exist, check the share's configured location in the
NAS admin UI (DSM: Control Panel > Shared Folder > admin$ > Edit, look at
the "Location" field) rather than guessing further. Once confirmed, set
`NAS_REMOTE_PATH` in the config to the real path.

For `TRANSFER_METHOD=rsync-daemon`: there is no separate path to confirm
here - `NAS_REMOTE_PATH` is a path inside `RSYNC_DAEMON_MODULE` (or blank
for the module's root), not a filesystem path. See step 2's rsync-daemon
section for where the module itself comes from.

### 1b. Confirm the Repository Root (needed for restore, not backup)

`gitea-restore.sh` needs to know exactly where Gitea stores repositories
inside the container (`GITEA_REPO_ROOT` in the config) so it can restore
into the right place. Confirm it against the running container rather
than guessing:

```bash
docker exec -u git <container> grep -A5 '^\[repository\]' /data/gitea/conf/app.ini
```

If `ROOT` isn't explicitly set there, Gitea's own default is
`%(APP_DATA_PATH)s/gitea-repositories` (i.e. under the same data directory
as `app.ini`); some older docker-image layouts instead used
`/data/git/repositories`. Set `GITEA_REPO_ROOT` in the config to whichever
one actually applies. This step is only needed if you plan to use
`gitea-restore.sh` - `gitea-backup.sh` does not need it.

### 2. Set Up NAS-Side Access

**For `TRANSFER_METHOD=sftp` or `rsync-ssh`:** create a dedicated NAS user
(for example `gitea-backup`) whose permissions are restricted to
read/write on the Gitea backup folder only, with no access to other
shares. Do not use an admin account. On Synology this is done through
Control Panel > User & Group > permissions, per shared folder. Whatever
username you create, use that exact spelling and case for `NAS_SSH_USER`
in the config - SSH account names are case-sensitive, and a mismatched
case reads as a completely different (nonexistent) account.

**Synology-specific:** DSM restricts full interactive SSH login to
accounts in the administrators group - a non-admin account will accept
the password/key and then the connection closes immediately with no error
message. This does **not** block SFTP, though: DSM exposes it as a
separate service (Control Panel > File Services > FTP/SFTP) that a
normal, permission-scoped account can use even though it can't get a
shell. That's the whole reason `sftp` is this tool's default rather than
`rsync-ssh` - see "Transport" above. Enable SFTP there if it isn't
already, or use `rsync-ssh` only if this account genuinely has full SSH
access (e.g. non-Synology target, or an account already in the
administrators group where that tradeoff is acceptable).

Continue to step 3 for either of these methods.

**For `TRANSFER_METHOD=rsync-daemon`:** create a dedicated account in the
NAS's own rsync service management instead (on Synology: Control Panel >
File Services > rsync > Rsync Account > Add). Scope it (via whatever
group/module restriction the NAS offers - Synology calls this an "rsync
group") to exactly the folder this backup should write to, nothing else.
Set `RSYNC_DAEMON_USER` to that account's username and `RSYNC_DAEMON_MODULE`
to the module name it's scoped to. Then store its password in its own
file:

```bash
sudo mkdir -p /opt/gitea-backup
sudo tee /opt/gitea-backup/rsync_daemon_password > /dev/null
# (paste the password, then press Ctrl-D)
sudo chmod 600 /opt/gitea-backup/rsync_daemon_password
```

Set `RSYNC_DAEMON_PASSWORD_FILE` in the config to that path. Skip
directly to step 5 - steps 3 and 4 (SSH key, known_hosts) don't apply,
since this method uses no SSH at all.

### 3. Generate a Dedicated SSH Key Pair (`sftp` / `rsync-ssh` only)

On the Docker host, as the user that will run cron:

```bash
sudo mkdir -p /opt/gitea-backup
sudo ssh-keygen -t ed25519 -f /opt/gitea-backup/id_ed25519_gitea-backup -N "" -C "gitea-backup@$(hostname)"
sudo chmod 600 /opt/gitea-backup/id_ed25519_gitea-backup
sudo chmod 644 /opt/gitea-backup/id_ed25519_gitea-backup.pub
```

Install the public key on the NAS for the dedicated account. Recent DSM 7
releases removed the old per-user "Advanced > SSH Public Key" GUI option
(if your DSM still has it, use it and skip the rest of this paragraph) -
where it's gone, add it to `authorized_keys` directly instead. This needs
a real admin-group SSH session (not the dedicated account itself, which
by design can't get one - see step 2), and User Home Service enabled
first (Control Panel > User & Group > Advanced > User Home):

```bash
ssh <admin-account>@<nas-host>
sudo mkdir -p <home-dir-of-dedicated-account>/.ssh
sudo nano <home-dir-of-dedicated-account>/.ssh/authorized_keys   # paste the .pub file's contents, save
sudo chown -R <dedicated-account>:users <home-dir-of-dedicated-account>/.ssh
sudo chmod 700 <home-dir-of-dedicated-account>/.ssh
sudo chmod 600 <home-dir-of-dedicated-account>/.ssh/authorized_keys
sudo chmod 750 <home-dir-of-dedicated-account>
```

That last `chmod` on the home directory itself (not just `.ssh`) matters:
DSM's default "homes" shared folder ACL leaves new home directories
world-writable, and OpenSSH's `StrictModes` setting (on by default)
silently refuses pubkey auth - no useful log line, just a generic
rejection - if the home directory is writable by anyone but its owner,
even when `.ssh` and `authorized_keys` themselves are permissioned
correctly. If key auth still fails after installing the key, this is the
first thing to check. On Synology specifically, the home directory's
real path is commonly reachable through several names that all point at
the same place (e.g. `/var/services/homes/<user>`, `/volume<N>/homes/<user>`,
and a `homes` share visible over SFTP/SMB) - use whichever one your admin
shell actually shows as real, `/var/services/homes/<user>` is the one
DSM's own sshd resolves a user's home from.

Everything after `-C` in the `ssh-keygen` command above is just a label
(the key's comment field) - it has no effect on authentication and can
be anything, or omitted.

**Recommended hardening:** add these SSH options in front of the key in
`authorized_keys` (comma-separated, no spaces around the commas):

```
no-port-forwarding,no-X11-forwarding,no-pty,no-agent-forwarding ssh-ed25519 AAAA... gitea-backup@dockerhost
```

For `sftp` specifically, these don't restrict SFTP itself - the NAS's own
SFTP-only account access already does that (see step 2) - but they close
off other things a leaked key could otherwise be used for on the same
connection: tunneling traffic through the NAS, allocating a terminal, or
relaying SSH-agent authentication elsewhere. Do not add a `command=`
forced-command option on top of these for `sftp` - the NAS's own
account-level SFTP restriction is what actually gates the account, and a
competing forced command could conflict with it rather than add anything.
For `rsync-ssh`, where the account has real command-execution access by
necessity, these same options are still worth adding as a baseline, but
provide less protection than they do for `sftp` - the account can still
run whatever it's permitted to run.

If your account still can't connect at all after installing the key (same
symptom as above: connects, then closes with no error), it's not yet in
whatever group/permission the NAS requires for the method you're using
either - double check step 2.

**Test with the exact same options the scripts actually use, not a plain
`sftp` command** - a plain `sftp -i <key> <user>@<host>` will silently
fall back to a password prompt if key auth fails, which can make a
broken key setup look like it's working (you type the password, it
connects, and you conclude the key is fine when it never actually got
used). The scripts always connect with `BatchMode=yes` (fail immediately
on any auth problem, never prompt), so that's what to test with too:

```bash
sftp -i <key> -P <port> -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<known_hosts path> <user>@<host>
```

Landing at an `sftp>` prompt with **no password prompt at all** is the
only result that actually confirms the scripts will work.

### 4. Pre-Seed the Known Hosts File (`sftp` / `rsync-ssh` only)

Using a dedicated known_hosts file (rather than the system-wide one) keeps
this job's trust in the NAS's host key independent and easy to audit:

```bash
sudo ssh-keyscan -p 22 <nas-host> | sudo tee /opt/gitea-backup/known_hosts
```

Verify the fingerprint printed matches the NAS's actual key (check the NAS
admin UI or console) before trusting it - `ssh-keyscan` itself does not
verify anything, it just fetches whatever key is offered.

### 5. Deploy the Config and Scripts

Everything goes in one directory - `/opt/gitea-backup` - alongside the
SSH key and known_hosts file from steps 3 and 4:

```bash
sudo mkdir -p /opt/gitea-backup
sudo cp -r gitea-backup.sh gitea-restore.sh lib gitea-backup.conf /opt/gitea-backup/
sudo chmod +x /opt/gitea-backup/gitea-backup.sh /opt/gitea-backup/gitea-restore.sh
sudo chmod 600 /opt/gitea-backup/gitea-backup.conf
sudo nano /opt/gitea-backup/gitea-backup.conf   # fill in every value
```

`lib/` must be copied along with the two scripts (`cp -r ... lib
/opt/gitea-backup/` above does this) - both scripts look for it relative
to their own location, so copying only the two `.sh` files without `lib/`
leaves them unable to find their transport backend.

Both scripts default to reading `gitea-backup.conf` from this same
directory, so no `GITEA_BACKUP_CONF` override is needed with this layout
- see "Configuration Reference" above if you're using a different one.

### 6. Test Before Scheduling

Run each stage manually and confirm it's clean before trusting it to cron:

```bash
sudo /opt/gitea-backup/gitea-backup.sh --check      # deps + NAS connectivity + write test
sudo /opt/gitea-backup/gitea-backup.sh --dry-run     # full dump + verification, no transfer
sudo /opt/gitea-backup/gitea-backup.sh               # full run, transfers to the NAS
```

Confirm the archive actually landed on the NAS and that
`/var/log/gitea-backup.log` shows a clean run with no WARN/ERROR lines.

## After Install Configuration

### Scheduling

```bash
sudo crontab -e
# Daily at 02:15
15 2 * * * /opt/gitea-backup/gitea-backup.sh >> /var/log/gitea-backup-cron.log 2>&1
```

### Notifications

Set `NOTIFY_EMAIL` and `MAIL_FROM` in the config to route failure alerts
through your existing msmtp relay. No email is sent on a routine success -
only on failure, or via the optional `HEARTBEAT_URL` (Uptime Kuma push
monitor) if you want a dead man's switch that also catches the case where
cron itself silently stops running the job.

### Retention

`RETENTION_DAYS` controls how long dumps are kept on the NAS,
`STAGING_RETENTION_DAYS` controls the short-lived local staging copy on
the Docker host. Retention cleanup failures are logged as warnings and
never fail an otherwise-successful run.

### Reliability

`DUMP_TIMEOUT` bounds the `gitea dump` step itself (seconds, default
21600 / 6 hours). If a run ever logs "did not complete within
DUMP_TIMEOUT", either something inside the container genuinely hung (a
locked DB, a full disk - check `docker logs` and disk space on the host),
or the instance has grown large enough that the dump legitimately needs
longer, in which case raise the value. Both `gitea-backup.sh` and
`gitea-restore.sh` also take an exclusive lock before doing anything
disruptive, so a slow run and a cron-triggered overlap can never race each
other; the second invocation just logs a WARN and exits cleanly.

### Restore

`gitea-restore.sh` shares `gitea-backup.conf`. Gitea has no built-in
single "restore" command upstream, so this automates everything that is
safely automatable and stops with clear instructions for the one thing it
will not guess at: importing the database dump (see `DB_RESTORE_CMD` /
`TEST_RESTORE_DB_CMD` in the config).

```bash
sudo /opt/gitea-backup/gitea-restore.sh --check              # deps + NAS connectivity
sudo /opt/gitea-backup/gitea-restore.sh --list                # what's on the NAS
sudo /opt/gitea-backup/gitea-restore.sh --dry-run              # fetch + verify only, touches nothing
sudo /opt/gitea-backup/gitea-restore.sh --test-restore         # full restore into an isolated,
                                                                  # throwaway container - safe any time
sudo /opt/gitea-backup/gitea-restore.sh --restore --confirm    # the real, disruptive restore
```

All modes default to the most recent archive on the NAS; pass
`--archive gitea-dump-YYYYMMDD-HHMMSS.zip` for a specific one, or
`--local-file /path/to/archive.zip` to use an archive that isn't on the
NAS at all.

**`--test-restore` is the important one to run regularly.** It always
creates a brand-new container on its own isolated Docker network with its
own throwaway volume - it never touches the production container, its
volumes, or `DB_RESTORE_CMD` - so it is safe to schedule (e.g. weekly) the
same way the backup itself is scheduled. Put it on its own cron entry:

```bash
sudo crontab -e
# Weekly test-restore, Sundays at 03:00
0 3 * * 0 /opt/gitea-backup/gitea-restore.sh --test-restore >> /var/log/gitea-restore-cron.log 2>&1
```

Unless `TEST_RESTORE_DB_CMD` is set to a real non-production test
database, a test-restore does not exercise the database import step (that
would require reaching a real DB, which isolation deliberately prevents by
default) - it validates that the archive is fetchable and intact and that
repository/data files place correctly into a real Gitea container layout,
which is most of what actually goes wrong in a real restore. The
completion email states whether the DB step was exercised.

**`--restore --confirm`** is the real thing: it stops the production
container (`GITEA_CONTAINER_NAME`), renames its existing repository and
app-data directories aside (`*.pre-restore-<timestamp>` - never deleted),
copies in the restored files, runs `DB_RESTORE_CMD` if configured, and
restarts it. Run `--dry-run` or `--test-restore` first. After a real
restore, manually verify: the web UI is reachable, SSO login works if
configured (redirect URI and any internal CA trust as applicable), a
known repo clones successfully, and any CI runner (e.g. `act_runner`) can
still authenticate - none of that is safely automatable without touching
things this project doesn't manage.

## Troubleshooting

**`gitea-backup.sh` fails with "mkdir: can't create directory
'.../gitea-dump-tmp': Permission denied" (fails at the "Running gitea
dump inside container" step)** - `GITEA_CONTAINER_TMP` points at a path
the `git` user inside the container can't write to. On the official
`gitea/gitea` image, `/data` itself is commonly root-owned `755` (root
can write, nobody else can), while `/data/gitea` (Gitea's own app data
directory, alongside `GITEA_APP_INI`) is `git`-owned and always
writable - which is why the shipped default is
`/data/gitea/gitea-dump-tmp`, not directly under `/data`. If you changed
this or your image's layout differs, confirm the real ownership first
rather than guessing: `docker exec <container> ls -la /data` (and
`docker exec <container> id git` to confirm the UID it's compared
against), then point `GITEA_CONTAINER_TMP` at anywhere writable by that
UID.

**Script dies immediately with "Config file not found:
/opt/gitea-backup/gitea-backup.conf" (or `/etc/gitea-backup/...`)** - the
config file isn't at the path the script is actually looking in. This
usually means the deployment is split across both `/opt/gitea-backup` and
`/etc/gitea-backup` - e.g. the scripts and conf were all copied to `/opt`
(this README's default, Quick Start step 5), but `GITEA_BACKUP_CONF` is
still set to (or a stale copy of these instructions pointed at) the old
`/etc` path, or vice versa. Pick one directory for everything and use it
consistently - see "Configuration Reference" above - then either move the
conf file to match the script's default, or set `GITEA_BACKUP_CONF`
explicitly to wherever it actually is:
`GITEA_BACKUP_CONF=/opt/gitea-backup/gitea-backup.conf sudo -E /opt/gitea-backup/gitea-backup.sh --check`.

**`--check` fails with "Cannot reach ... or path does not exist / is not
writable"** - either the account/key isn't authorized on the NAS yet, or
`NAS_REMOTE_PATH` is wrong for the `TRANSFER_METHOD` in use (see the
Configuration Reference row for it - it means different things for
`sftp`/`rsync-ssh` vs. `rsync-daemon`). Re-run the path confirmation in
step 1. For `sftp`/`rsync-ssh`, test the connection directly to narrow it
down: `sftp -i <NAS_SSH_KEY> <NAS_SSH_USER>@<NAS_SSH_HOST>`.

**Script dies immediately with "NAS_REMOTE_PATH ... must not start with
/"** - you're on `TRANSFER_METHOD=rsync-daemon` with a value left over
from `sftp`/`rsync-ssh` (which do want a leading `/`, an absolute
filesystem path). For `rsync-daemon`, `NAS_REMOTE_PATH` is a path inside
`RSYNC_DAEMON_MODULE`, not a filesystem path - remove the leading slash,
or leave it blank for the module's root.

**Dependency check fails on `sftp`/`ssh`, or on `rsync`** - install
`openssh-client` (`sftp`/`rsync-ssh` need it) and/or `rsync`
(`rsync-ssh`/`rsync-daemon` need it) on the Docker host: `sudo apt-get
install openssh-client rsync`. Only the packages your `TRANSFER_METHOD`
actually needs are checked, so this depends on which method you're using.

**Testing with `sftp` prompts for a password instead of using the key** -
the public key isn't installed in the account's `authorized_keys` on the
NAS yet (or wasn't added correctly) - see Quick Start step 3. A password
prompt succeeding confirms the account and network path are fine; it's
specifically key-based auth that isn't wired up yet, which the actual
scripts require (`BatchMode=yes` - they never prompt for a password, they
just fail if the key doesn't work). Important: if you answer that
password prompt, the connection will succeed - which can make a broken
key setup look fine, since you never find out the key itself didn't
work. Always test with `-o BatchMode=yes` explicitly (see Quick Start
step 3's testing note) to get an honest answer.

**Key is correctly installed in `authorized_keys` but `-o BatchMode=yes`
still gets "Permission denied (publickey,password)", with nothing useful
in the NAS's own logs** - check the permissions on the account's home
directory itself, not just `.ssh`/`authorized_keys`. OpenSSH's
`StrictModes` setting (on by default) silently refuses pubkey auth if
the home directory is writable by anyone but its owner - on Synology
this is a common trap, since DSM's default "homes" shared folder ACL
leaves new home directories world-writable (`drwxrwxrwx`). Fix:
`sudo chmod 750 <home-dir-of-dedicated-account>`, then retest. See Quick
Start step 3 for the full explanation.

**SSH key works interactively but the dedicated backup account's session
closes immediately after the password/key, with no error** - on Synology
DSM, only accounts in the administrators group can open a full interactive
SSH session at all; this is the exact symptom of a non-admin account being
silently rejected. This is expected and does not affect `sftp` - see the
Synology-specific note under Quick Start step 2. It does affect
`rsync-ssh`, which genuinely needs that access.

**`rsync-ssh` transfer or fetch fails with "Permission denied", but
`--check` passes** - some NAS platforms (Synology DSM is a known case)
don't put `rsync` on the PATH an SSH session gets, so the connection
authenticates fine but rsync still can't find its own binary on the far
end. This won't show up in `--check` (a plain connectivity test) or
`--dry-run` (stops before the transfer), so it can surprise you on the
first real run. Set `RSYNC_REMOTE_BIN` in the config to the full path of
`rsync` on the NAS - `/usr/bin/rsync` on Synology - and re-run.

**Both scripts die immediately with "No such file or directory" naming a
`lib/transport.sh` path** - it wasn't deployed alongside the two scripts.
Both scripts look for it relative to their own location (`SCRIPT_DIR`) -
if you copied only `gitea-backup.sh`/`gitea-restore.sh` somewhere without
also copying the `lib/` folder, this is why. See Quick Start step 5.

**A run fails and the log shows "Checksum mismatch after transfer"** (only
possible with `VERIFY_TRANSFER=yes`) - the script has already deleted the
bad copy from the NAS before failing, so you won't be left trusting a
corrupt backup. Just re-run.

**A backup or restore run logs "Another ... run appears to be in
progress" and exits 0** - a previous run (likely a slow `gitea dump` on a
large instance) is still holding the lock. Not an error; wait for it to
finish. If nothing is actually running, remove the stale lock file
(named `.gitea-backup.lock` / `.gitea-restore.lock` under `STAGING_DIR`) -
this should only happen if the lock file itself was manually tampered
with, since the lock is released automatically on process exit, including
a crash.

**`gitea-restore.sh` dies with "GITEA_REPO_ROOT is not set"** - this value
has no safe default and is required before any restore mode, including
`--check`, will run. See Quick Start step 1b.

**A `--test-restore` run logs a WARN that the HTTP health endpoint didn't
respond** - informational only, not a failure. Expected when Gitea is
normally backed by an external DB it cannot reach from the isolated test
network; the run still confirms the archive is intact and files placed
correctly. Set `TEST_RESTORE_DB_CMD` to a non-production test database if
you want test-restore to validate the full stack.

**A `--test-restore` run logs a WARN that the container "exited because
it could not reach its configured database" and still reports PASSED** -
also informational, not a failure - this is a step further than the HTTP
case above: Gitea itself exits (rather than degrading gracefully) when it
can't reach its configured database at startup, and the isolated
test-restore network deliberately cannot reach an external DB the
restored config normally points at. This is recognized specifically (by
matching the container's own DB-connection-failure log signature) and
does not count against the test-restore, which still confirms
everything it claims to: the archive is fetchable and intact, the
restored config loads correctly (no install-wizard fallback, no missing
files), and the files place correctly into a real container layout. Only
actual DB reachability - which `--test-restore` never claims to prove
without `TEST_RESTORE_DB_CMD` set - goes untested. A real `--restore` is
given no such tolerance: it runs on the real network, so any crash there
is treated as a genuine failure.

**`--restore` completes but the site looks empty or serves stale data** -
check the log for "No DB restore hook configured": if `DB_RESTORE_CMD` is
unset, the database was deliberately not touched and needs a manual
import from the path the log prints (`gitea-db.sql` inside the restore
work directory) before the instance will serve correct data.

**Log location** - `/var/log/gitea-backup.log` (both scripts' log, lines
tagged `[RESTORE]` for gitea-restore.sh) and `/var/log/gitea-backup-cron.log`
/ `/var/log/gitea-restore-cron.log` (cron's stdout/stderr, if configured as
above).
