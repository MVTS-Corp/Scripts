#Requires -Version 5.1
<#
.SYNOPSIS
    MVTS-Fonts.ps1 - Install Google Fonts system-wide on Windows.

.DESCRIPTION
    Pulls TTFs directly from the google/fonts GitHub repo (raw host), which is
    deterministic and not subject to the unofficial fonts.google.com/download
    endpoint's flakiness or to api.github.com's 60/hour unauthenticated limit.

    Each download is validated as a real font (sfnt magic bytes) before install.
    Fonts are copied to %WINDIR%\Fonts and registered under HKLM so they persist
    and are visible to every user. A WM_FONTCHANGE broadcast tells already-running
    apps to pick them up without a reboot.

    Idempotent: entries already registered are skipped unless -Force is given.
    Must be run from an elevated (Administrator) session.

.PARAMETER Force
    Reinstall every font even if already registered.

.EXAMPLE
    # Local, from a saved file (elevated PowerShell):
    powershell -ExecutionPolicy Bypass -File .\MVTS-Fonts.ps1
    powershell -ExecutionPolicy Bypass -File .\MVTS-Fonts.ps1 -Force

.EXAMPLE
    # Remote, straight from the repo (run in an ELEVATED PowerShell):
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    irm https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Windows/MVTS-Fonts.ps1 | iex

    # Remote with -Force (iex can't take params, so wrap in a scriptblock):
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Windows/MVTS-Fonts.ps1))) -Force
#>
[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# TLS 1.2 - Server 2016/2012R2 and PS 5.1 may default to TLS 1.0, which GitHub rejects.
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --- Configuration ---------------------------------------------------------
# Pin $Ref to a commit SHA instead of 'main' for byte-for-byte reproducibility
# across a fleet (protects against upstream file renames).
$Ref     = 'main'
$Base    = "https://raw.githubusercontent.com/google/fonts/$Ref"
$FontDir = Join-Path $env:WINDIR 'Fonts'
$RegPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

# Url  = repo-relative path (variable-font names contain [] - encoded at fetch time)
# File = on-disk filename (brackets stripped: PowerShell treats [] as wildcards)
# Name = registry display name; Windows convention appends " (TrueType)"
# Inter and Outfit are variable fonts (all weights Thin->Black in one file).
$Fonts = @(
    @{ Url = 'apache/permanentmarker/PermanentMarker-Regular.ttf'; File = 'PermanentMarker-Regular.ttf'; Name = 'Permanent Marker' }
    @{ Url = 'ofl/archivoblack/ArchivoBlack-Regular.ttf';          File = 'ArchivoBlack-Regular.ttf';     Name = 'Archivo Black' }
    @{ Url = 'ofl/outfit/Outfit[wght].ttf';                        File = 'Outfit.ttf';                  Name = 'Outfit' }
    @{ Url = 'ofl/inter/Inter[opsz,wght].ttf';                     File = 'Inter.ttf';                   Name = 'Inter' }
    @{ Url = 'ofl/inter/Inter-Italic[opsz,wght].ttf';             File = 'Inter-Italic.ttf';            Name = 'Inter Italic' }
)

# --- Helpers ---------------------------------------------------------------
function Write-Log  ($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Warn ($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Stop-Fail  ($m) { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

# A font is "registered" if a value of this name exists under the Fonts key.
function Test-Registered ($name) {
    $v = Get-ItemProperty -Path $RegPath -Name "$name (TrueType)" -ErrorAction SilentlyContinue
    return $null -ne $v
}

# True if the file begins with a valid sfnt signature (TTF / OTTO / true / ttcf).
function Test-IsFont ($path) {
    $b  = [byte[]]::new(4)
    $fs = [IO.File]::OpenRead($path)
    try { [void]$fs.Read($b, 0, 4) } finally { $fs.Dispose() }
    $hex = -join ($b | ForEach-Object { $_.ToString('x2') })
    return @('00010000', '4f54544f', '74727565', '74746366') -contains $hex
}

# --- Pre-flight ------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Stop-Fail 'Run this from an elevated (Administrator) PowerShell session.' }

$tmp = Join-Path $env:TEMP ('mvts-fonts-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# --- Install ---------------------------------------------------------------
$changed = $false
foreach ($f in $Fonts) {
    if (-not $Force -and (Test-Registered $f.Name)) {
        Write-Log "Already installed: $($f.Name) (skipping; use -Force to reinstall)"
        continue
    }

    Write-Log "Fetching: $($f.Name)"
    $url = "$Base/" + ($f.Url -replace '\[', '%5B' -replace '\]', '%5D')
    $dl  = Join-Path $tmp $f.File
    try {
        Invoke-WebRequest -Uri $url -OutFile $dl -UseBasicParsing
    } catch {
        Write-Warn "  download failed: $($f.File)"; continue
    }
    if (-not (Test-IsFont $dl)) {
        Write-Warn "  not a valid font (upstream moved?): $($f.File)"; continue
    }

    $dest = Join-Path $FontDir $f.File
    Copy-Item -LiteralPath $dl -Destination $dest -Force
    New-ItemProperty -Path $RegPath -Name "$($f.Name) (TrueType)" `
        -Value $f.File -PropertyType String -Force | Out-Null
    '    installed {0} ({1:N0} bytes)' -f $f.File, (Get-Item -LiteralPath $dest).Length | Write-Host
    $changed = $true
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

# --- Notify running sessions (no reboot needed) ----------------------------
if ($changed) {
    Write-Log 'Broadcasting font change to running applications...'
    if (-not ('Win32.FontNotify' -as [type])) {
        Add-Type -Namespace Win32 -Name FontNotify -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(
    System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam,
    uint flags, uint timeout, out System.IntPtr result);
'@
    }
    $HWND_BROADCAST = [IntPtr]0xffff
    $WM_FONTCHANGE  = 0x001D
    $result = [IntPtr]::Zero
    [void][Win32.FontNotify]::SendMessageTimeout(
        $HWND_BROADCAST, $WM_FONTCHANGE, [IntPtr]::Zero, [IntPtr]::Zero, 2, 1000, [ref]$result)
} else {
    Write-Log 'No changes.'
}

# --- Verify ----------------------------------------------------------------
# Deterministic check (registry value + file on disk). We deliberately avoid
# querying the live GDI font collection here: it caches per-process and can
# report a freshly added font as missing, producing a false failure.
Write-Log 'Verifying:'
$ok = $true
foreach ($f in $Fonts) {
    $present = (Test-Registered $f.Name) -and
              (Test-Path -LiteralPath (Join-Path $FontDir $f.File))
    if ($present) {
        Write-Host "    [OK] $($f.Name)" -ForegroundColor Green
    } else {
        Write-Host "    [--] $($f.Name) (not found)" -ForegroundColor Red
        $ok = $false
    }
}

if (-not $ok) { Stop-Fail 'One or more fonts are missing - check the warnings above.' }
Write-Log "Done. Fonts installed to $FontDir"
