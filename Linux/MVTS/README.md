README.md v1.0.0 (Last Rev: 2026-08-09)

## Overview

MVTS brand asset scripts for Linux. Currently holds the font installer that
puts the MVTS brand Google Fonts on a Debian/Ubuntu host system-wide.

## Files

- `MVTS-Fonts.sh` - installs Permanent Marker, Archivo Black, Outfit, and
  Inter (regular and italic) system-wide to `/usr/local/share/fonts/google`.
  Idempotent; already-installed families are skipped unless `--force` is
  given. Run `sudo ./MVTS-Fonts.sh --force` to reinstall everything.

## Quick Start

Pulling and running directly from GitHub in one line:

```bash
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/MVTS/MVTS-Fonts.sh | sudo bash
```

Or from a cloned copy of this repo:

```bash
sudo ./MVTS-Fonts.sh
```

## After Install Configuration

No further configuration is needed. Applications that were already open when
the fonts were installed may need to be restarted before the new families
show up in their font picker; this depends on the application, not on
anything this script can control on Linux.

## Troubleshooting

- **"not a valid font (upstream moved?)" warning** - the google/fonts repo
  renamed or restructured the file this script expects. Check the
  `FONT_FILES` map at the top of `MVTS-Fonts.sh` against the current path in
  https://github.com/google/fonts and update it.
- **A family shows as missing in the final verification** - re-run with
  `--force` to force a fresh download, then check `fc-list | grep -i
  "<family name>"` directly to confirm what fontconfig actually sees.
- **Script exits with "Please run as root"** - run it with `sudo`.
