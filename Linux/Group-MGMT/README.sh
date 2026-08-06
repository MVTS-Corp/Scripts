README.md v1.0.0 (Last Rev: 2026-08-05)

## Overview

Scripts for provisioning fixed-GID groups consistently across the MVTS
Linux fleet, so a given group name always maps to the same GID on every
host regardless of local install order. Each group gets its own
dedicated, self-contained script in this folder.

## Files

- **create-usr_admin-group.sh** - Creates the `usr_admin` group at GID
  3000 (or verifies it if the group already exists), then optionally adds
  one or more local users to it. Supports both an interactive numbered
  prompt and a non-interactive `--users` flag for RMM/orchestration use.
  Run `./create-usr_admin-group.sh --help` for full usage.
  (Additional group scripts will be added here as they're built.)

## Quick Start

Interactive, on a box you are logged into directly:

```bash
sudo ./create-usr_admin-group.sh
```

Unattended, from an RMM or orchestration tool:

```bash
sudo ./create-usr_admin-group.sh --users jsmith,tzh-freepbx-admin --yes
```

Pulling and running directly from GitHub in one line (useful for a quick
one-off on a box without the repo cloned):

```bash
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Group-MGMT/create-usr_admin-group.sh | sudo bash -s -- --users jsmith --yes
```

## After Install Configuration

Once the group exists on a host, apply the actual directory permissions
separately with `setfacl`, for example:

```bash
sudo setfacl -R -m g:usr_admin:rwX /path/to/directory
sudo setfacl -R -d -m g:usr_admin:rwX /path/to/directory
```

The `-d` (default) rule is what makes access durable: anything created in
that directory afterward, including by root, inherits `usr_admin` access
automatically.

Any user newly added to `usr_admin` must log out and back in (or run
`newgrp usr_admin`) before the new membership applies to their current
session.

## Troubleshooting

- **Script exits with "GID mismatch" and makes no changes.** Something on
  that host already claims GID 3000 under a different group name. Run
  `getent group 3000` to identify it before deciding whether to
  reconcile it or point this script at a different GID with `--gid`.
- **Script exits with "no interactive terminal is attached" when run
  from an RMM.** Expected and intentional; the script will not guess who
  to add to the group. Pass `--users` explicitly in the RMM job.
- **Newly added user still cannot access the SFTP directory.** Group
  membership does not apply to an already-open session; the user needs
  to log out and back in, or run `newgrp usr_admin`.
