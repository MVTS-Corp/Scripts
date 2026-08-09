README.md v1.0.0 (Last Rev: 2026-08-09)

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
