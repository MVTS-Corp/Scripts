#!/usr/bin/env bash
#
# install-fonts.sh — Install Google Fonts system-wide on Debian/Ubuntu.
#
# Idempotent: safe to re-run. Families already present are skipped unless
# --force is given. Installs its own dependencies (curl, unzip, fontconfig).
#
# Usage:
#   sudo ./install-fonts.sh           # install missing families
#   sudo ./install-fonts.sh --force   # reinstall everything
#
set -euo pipefail

# --- Configuration ---------------------------------------------------------
FONT_FAMILIES=(
  "Permanent Marker"
  "Archivo Black"
  "Outfit"
  "Inter"
)
INSTALL_DIR="/usr/local/share/fonts/google"
PREFER_STATIC=true   # use static instances for variable fonts when available

# --- Helpers ---------------------------------------------------------------
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# Exact, case-insensitive family-name match against fontconfig's family list.
# Avoids substring false positives (e.g. "Inter" vs "Inter Tight").
family_installed() { fc-list : family | grep -qix "$1"; }

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

# --- Pre-flight ------------------------------------------------------------
[[ $EUID -eq 0 ]] || err "Please run as root (sudo)."

missing=false
for cmd in curl unzip fc-cache fc-list; do
  command -v "$cmd" >/dev/null 2>&1 || missing=true
done
if $missing; then
  log "Installing dependencies (curl, unzip, fontconfig)…"
  apt-get update -qq
  apt-get install -y -qq curl unzip fontconfig
fi

# --- Install ---------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

changed=false
for fam in "${FONT_FAMILIES[@]}"; do
  if ! $FORCE && family_installed "$fam"; then
    log "Already installed: $fam (skipping; use --force to reinstall)"
    continue
  fi

  log "Downloading: $fam"
  enc="${fam// /%20}"
  zip="$TMP/${fam// /_}.zip"
  if ! curl -fsSL -o "$zip" "https://fonts.google.com/download?family=${enc}"; then
    warn "Download failed for '$fam' — skipping."
    continue
  fi

  dest="$TMP/${fam// /_}"
  unzip -oq "$zip" -d "$dest"

  # Prefer static instances (broader compatibility than variable fonts).
  src="$dest"
  if $PREFER_STATIC && [[ -d "$dest/static" ]]; then
    src="$dest/static"
  fi

  count=$(find "$src" -type f \( -iname '*.ttf' -o -iname '*.otf' \) | wc -l)
  if (( count == 0 )); then
    warn "No font files found in download for '$fam' — skipping."
    continue
  fi

  find "$src" -type f \( -iname '*.ttf' -o -iname '*.otf' \) \
    -exec install -m 644 {} "$INSTALL_DIR/" \;
  changed=true
done

# --- Finalize --------------------------------------------------------------
if $changed; then
  log "Rebuilding font cache…"
  fc-cache -f "$INSTALL_DIR" >/dev/null
else
  log "No changes; font cache untouched."
fi

# --- Verify ----------------------------------------------------------------
log "Verifying:"
ok=true
for fam in "${FONT_FAMILIES[@]}"; do
  if family_installed "$fam"; then
    printf '    \033[1;32m✓\033[0m %s\n' "$fam"
  else
    printf '    \033[1;31m✗\033[0m %s (not found)\n' "$fam"
    ok=false
  fi
done

$ok || err "One or more families are missing — check the warnings above."
log "Done. Fonts installed to $INSTALL_DIR"
