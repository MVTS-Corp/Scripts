README.md v1.1.1 (Last Rev: 2026-09-19)

# Scripts

## Overview

Central repo for MVTS internal automation and fleet-management scripts,
organized by target platform. Each tool lives in its own subfolder with
its own README covering exactly that tool; this file is just the index.

Previously several of these tools lived in their own per-repo GitHub
projects (`Linux-Updates`, an unversioned `Development Tools` folder).
Those have been folded into this repo so everything ships from one
place with one consistent structure.

## Files

- **Linux/** - scripts for Linux hosts. See `Linux/README.md`.
- **Windows/** - scripts for Windows hosts. See `Windows/README.md`.

## Quick Start

Clone the whole repo:

```bash
git clone https://github.com/MVTS-Corp/Scripts.git
```

Most individual tools are also independently installable with a single
curl (Linux) or irm (Windows) one-liner without cloning anything - see
that tool's own README for the exact command.

## Releases and Channels

Most tools here run straight from `main`. Tools that update themselves on
machines nobody is watching (currently **NTP-Config**) follow a release
channel instead, so a half-finished commit on `main` can never reach them.

- **`main`** - where work happens. Never followed by a self-updating tool.
- **`stable`** - a branch that only ever moves forward to a commit that has
  been tagged as a release. This is what installed tools follow by default.
- **`<tool>-vX.Y.Z` tags** (for example `ntp-config-v1.0.0`) - permanent
  markers for exactly what shipped, and the way to pin a machine to one
  release. A tag applies to the whole repository, so the tool name is part of
  the tag, and the number is that tool's *release* number: MAJOR for a change
  that breaks callers (flags, exit codes, install paths), MINOR for a new
  feature, PATCH for a fix. It is separate from the version inside each
  script's header, which changes on every edit.

Releases so far:

| Tag | Linux scripts | Windows scripts |
| --- | --- | --- |
| `ntp-config-v1.0.0` | configure-ntp-server.sh v1.6.0, install.sh v2.2.0, bootstrap.sh v1.1.0 | Configure-NtpConfig.ps1 v1.6.0, Install-NtpConfig.ps1 v2.2.0, runme.cmd v1.1.0 |

### Cutting a Release

From a clean checkout of `main` with the work already committed and pushed:

```bash
git switch main && git pull --ff-only
git tag -a ntp-config-v1.1.0 -m "Short summary of what users will notice"
git push origin ntp-config-v1.1.0
git push origin main:stable
```

Order matters: the commit is pushed first, then tagged, then `stable` is moved
to that same commit. `git push origin main:stable` is a plain fast-forward and
is rejected if it would move `stable` backwards. Installed machines pick the
release up the next time they run.

Do not rewind `stable` or move a tag. The tools refuse to install an older
version than the one running, so a bad release is fixed by publishing a new,
higher release (a revert is fine), never by going back. To put one machine
back on an older release right away, re-run its installer with `--ref` (Linux)
or `-Ref` (Windows) set to the older tag.

These protections are configured on GitHub as repository rulesets, with no
bypass exceptions:

- **Protect stable release channel** - `stable` cannot be deleted or
  force-pushed. Fast-forwarding it to a newly tagged commit still works.
- **Protect NTP-Config release tags** - tags matching `ntp-config-v*`
  cannot be deleted or moved. Creating a new tag still works.
- Two-factor authentication is required for every member of the
  organization.

A tool with a new tag prefix needs that prefix added to the tag ruleset
(repository Settings, Rules, Rulesets) to be protected the same way. To
change a protected ref in an emergency, disable its ruleset first and
re-enable it straight afterward. `main` is deliberately not protected.
