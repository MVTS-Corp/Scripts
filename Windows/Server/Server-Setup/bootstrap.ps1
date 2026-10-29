<#
.SYNOPSIS
    bootstrap.ps1

.DESCRIPTION
    One-line install entry point for Setup-WindowsServer.ps1. Downloads a
    snapshot of the MVTS-Corp/Scripts repo from GitHub as a zip (no git
    needed) into a new temp folder, runs Setup-WindowsServer.ps1 from it as
    its own process, and deletes the snapshot afterward. Nothing is
    installed; the only thing left behind is Setup-WindowsServer.ps1's log.

    Run from an elevated PowerShell:
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Windows/Server/Server-Setup/bootstrap.ps1)))
    Every argument is passed through to Setup-WindowsServer.ps1, for example:
        & ([scriptblock]::Create((irm <same URL>))) -Yes -EnableRdp

    Its own arguments (taken out before the rest are passed on):
      -Ref <branch or tag>   Snapshot to download. Default main.
      -ArchiveUrl <url>      Download the zip from this URL instead (a fork or
                             a mirror). -Ref is then ignored.

    It does not call exit, because the one-liner runs it inside the caller's
    own PowerShell session. Setup-WindowsServer.ps1's exit code is left in
    $LASTEXITCODE (0 ok, 1 failure, 2 invalid parameters, 3 flagged for
    review; 1 here also covers a failed download).

.NOTES
    Version: v1.0.0
    Last Edit Date: 2026-10-28

    CHANGELOG:
      v1.0.0 - Initial release.
#>

# Deliberately no param() block: the setup script's own switches (-Yes,
# -EnableRdp, ...) have to reach it untouched, and an advanced param block
# would reject them as unknown parameters.
$bsRef = 'main'
$bsArchiveUrl = ''
$bsForward = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -eq '-Ref' -and $i + 1 -lt $args.Count) { $bsRef = [string]$args[++$i]; continue }
    if ($a -eq '-ArchiveUrl' -and $i + 1 -lt $args.Count) { $bsArchiveUrl = [string]$args[++$i]; continue }
    $bsForward.Add($a)
}

& {
    param($Ref, $ArchiveUrl, [string[]]$Forward)
    $ErrorActionPreference = 'Stop'
    $global:LASTEXITCODE = 1

    if (-not $ArchiveUrl) {
        if ($Ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$' -or $Ref -match '\.\.') {
            Write-Host "ERROR: '$Ref' is not a valid branch or tag name." -ForegroundColor Red
            $global:LASTEXITCODE = 2
            return
        }
        $ArchiveUrl = "https://github.com/MVTS-Corp/Scripts/archive/$Ref.zip"
    }

    $work = Join-Path ([IO.Path]::GetTempPath()) ("MVTS-Server-Setup-{0}" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $zip = Join-Path $work 'repo.zip'
        $extract = Join-Path $work 'repo'
        Write-Host "Downloading $ArchiveUrl"
        $prevProtocol = [Net.ServicePointManager]::SecurityProtocol
        try {
            [Net.ServicePointManager]::SecurityProtocol = $prevProtocol -bor [Net.SecurityProtocolType]::Tls12
            # The progress bar makes Invoke-WebRequest many times slower on 5.1.
            $prevProgress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $ArchiveUrl -OutFile $zip -UseBasicParsing -TimeoutSec 120
        } catch {
            Write-Host "ERROR: download failed: $($_.Exception.Message)" -ForegroundColor Red
            return
        } finally {
            [Net.ServicePointManager]::SecurityProtocol = $prevProtocol
            $ProgressPreference = $prevProgress
        }

        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        # GitHub wraps the snapshot in one top-level folder (Scripts-<ref>).
        $root = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
        $setup = $null
        if ($root) { $setup = Join-Path $root.FullName (Join-Path 'Windows' (Join-Path 'Server' (Join-Path 'Server-Setup' 'Setup-WindowsServer.ps1'))) }
        if (-not $setup -or -not (Test-Path -LiteralPath $setup)) {
            Write-Host 'ERROR: the downloaded snapshot does not contain Windows\Server\Server-Setup\Setup-WindowsServer.ps1.' -ForegroundColor Red
            return
        }

        # Check it parses before running it as Administrator.
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($setup, [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            Write-Host "ERROR: Setup-WindowsServer.ps1 in the snapshot has syntax errors: $($parseErrors[0].Message)" -ForegroundColor Red
            return
        }

        # Always Windows PowerShell 5.1, even from a PowerShell 7 prompt:
        # Get-WindowsFeature (used to detect an RDS session host) is not
        # available in PowerShell 7.
        $exe = Join-Path $env:SystemRoot (Join-Path 'System32' (Join-Path 'WindowsPowerShell' (Join-Path 'v1.0' 'powershell.exe')))
        & $exe -NoProfile -ExecutionPolicy Bypass -File $setup @Forward
        $rc = $LASTEXITCODE
        $global:LASTEXITCODE = $rc
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
} $bsRef $bsArchiveUrl $bsForward.ToArray()
