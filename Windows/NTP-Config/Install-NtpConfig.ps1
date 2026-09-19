<#
.SYNOPSIS
    Install-NtpConfig.ps1

.DESCRIPTION
    Bootstrap installer for the Windows side of NTP-Config. Downloads the
    MVTS-Corp/Scripts repo from GitHub as an HTTPS zip archive (no git
    required - installing Git for Windows on a domain controller or a
    hardened member server is undesirable, and GitHub cannot serve a single
    subfolder as an archive, so the whole repo comes down regardless),
    verifies Configure-NtpConfig.ps1 with a syntax check before it is ever
    placed where operators will run it, and installs only the contents of
    the repo's Windows\NTP-Config folder (runme.cmd included) flattened
    directly into $InstallDir - the rest of the repo is not relevant on
    this host and is left out entirely. $InstallDir itself is added to the
    machine PATH so the tool can be run from any elevated PowerShell prompt
    as `Configure-NtpConfig.ps1`. No scheduled tasks are created or
    required; Configure-NtpConfig.ps1 checks for and applies updates from
    the repo on every run on its own.

    All Windows components this tool uses (w32time, the NetSecurity module
    for firewall rules, and Microsoft.PowerShell.Archive for Expand-Archive)
    ship with Windows itself, so unlike the Linux installer there is no
    package-manager dependency step here.

    TLS: GitHub presents a publicly trusted certificate, so no TLS switch is
    normally needed. If this host sits behind a TLS-inspecting proxy whose
    CA it does not trust, use -CaCertPath (verifies TLS against that CA, the
    correct long-term option) or -Insecure (skips verification, trusted
    networks only). The choice is saved for later self-updates.

.PARAMETER Repo
    GitHub repository in owner/name form. Default: MVTS-Corp/Scripts.

.PARAMETER Ref
    Git ref (a branch or a tag) to install from and follow for updates.
    Default: stable, a branch that only ever points at a tagged release. Pass
    a release tag such as ntp-config-v1.0.0 to pin that exact release. A re-run
    that does not name a ref keeps the ref the existing install follows.

.PARAMETER InstallDir
    Where to install. Default: C:\DATA\Tools\NTP-Config.

.PARAMETER Insecure
    Skip TLS certificate verification. Mutually exclusive with -CaCertPath.

.PARAMETER CaCertPath
    Path to a PEM/CER CA certificate to trust for the download. It is copied
    into the install directory so later self-updates keep working after the
    original file is gone.

.NOTES
    Version: v2.2.0
    Last Edit Date: 2026-09-18

    CHANGELOG:
      v2.2.0 - -Branch is replaced by -Ref (a branch or a tag), default
               "stable": a branch that only ever points at a tagged release.
               A release tag pins an exact version. The ref is saved in the
               state file (key Ref) and, like the TLS choice, kept when the
               installer is re-run without naming one.
      v2.1.0 - Safe to call from another script: parameter errors now exit 2
               (previously Write-Error threw, so the intended exit codes never
               applied), validation runs before the admin check, and progress
               output is suppressed. Exit codes: 0 installed, 1 runtime failure
               (not elevated, download or verify failed), 2 invalid parameters.
      v2.0.0 - Moved from a self-hosted Git server to the public
               MVTS-Corp/Scripts repo on GitHub. The source is now
               -Repo/-Branch (later -Ref) instead of a full -RepoUrl, and only
               Windows\NTP-Config is installed. The saved state file has a
               new shape (Repo/Ref/TlsMode/CaCertPath); a CA passed with
               -CaCertPath is now copied into the install directory.
      v1.3.0 - Last version published from the previous self-hosted repo.
#>

[CmdletBinding()]
param(
    [string]$Repo = 'MVTS-Corp/Scripts',
    [string]$Ref = 'stable',
    [string]$InstallDir = 'C:\DATA\Tools\NTP-Config',
    [switch]$Insecure,
    [string]$CaCertPath
)

$ScriptVersion = 'v2.2.0'
$ErrorActionPreference = 'Stop'
# Progress bars make Invoke-WebRequest and Expand-Archive dramatically slower on
# Windows PowerShell 5.1 and add noise to captured output from a calling script.
$ProgressPreference = 'SilentlyContinue'
$RepoSubPath = 'Windows\NTP-Config'

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
function Test-NtpIsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Wraps Invoke-WebRequest with optional, narrowly-scoped TLS handling for
# hosts that cannot verify GitHub's certificate on their own (a TLS-inspecting
# proxy with a private CA, for example). The previous
# ServerCertificateValidationCallback/SecurityProtocol are always restored
# afterward, so a relaxed check here never leaks to unrelated calls later
# in the process.
function Invoke-NtpWebRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$TlsMode = 'Default',
        [string]$CaCertPath
    )
    $prevCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    $prevProtocol = [System.Net.ServicePointManager]::SecurityProtocol
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = $prevProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        switch ($TlsMode) {
            'Insecure' {
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            }
            'Cacert' {
                if (-not $CaCertPath -or -not (Test-Path -LiteralPath $CaCertPath)) {
                    throw "TLS mode is 'Cacert' but CaCertPath '$CaCertPath' was not found."
                }
                $caCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CaCertPath)
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
                    param($reqSender, $cert, $chain, $policyErrors)
                    # A name mismatch is a real problem regardless of which CA
                    # issued the cert - pinning our own CA below only replaces
                    # the "do we trust the issuer" check, not the hostname check
                    # .NET already computed into $policyErrors.
                    if (($policyErrors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch) -ne 0) { return $false }
                    if (($policyErrors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNotAvailable) -ne 0) { return $false }
                    $chain.ChainPolicy.ExtraStore.Add($caCert)
                    # Our CA is intentionally not in the Windows trust store yet
                    # (that is the whole reason -CaCertPath exists), so the
                    # chain must be allowed to build to an otherwise-untrusted
                    # root - the thumbprint check below is what actually
                    # confers trust, not this flag on its own.
                    $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
                    $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
                    if (-not $chain.Build([System.Security.Cryptography.X509Certificates.X509Certificate2]$cert)) { return $false }
                    foreach ($element in $chain.ChainElements) {
                        if ($element.Certificate.Thumbprint -eq $caCert.Thumbprint) { return $true }
                    }
                    return $false
                }.GetNewClosure()
            }
        }
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
    } finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $prevCallback
        [System.Net.ServicePointManager]::SecurityProtocol = $prevProtocol
    }
}

# Swaps a staged (already downloaded and verified) file or folder into
# place using two renames instead of a slow recursive overwrite, so the
# window in which $InstallDir is in a half-updated state is as small as
# possible. Because Configure-NtpConfig.ps1 is verified with a syntax
# check against the STAGED copy before this is ever called, there is no
# "bad version went live, now roll it back" case to handle here - unlike
# the Linux installer's git pull (which mutates the working tree before it
# can be checked), nothing under $InstallDir is touched until the new copy
# has already passed its check. Works for both directories and individual
# files - Copy-Item/Remove-Item/Rename-Item all handle a plain file just as
# well as a directory, -Recurse is simply a no-op on a file.
function Install-NtpStagedItem {
    param(
        [Parameter(Mandatory)][string]$StagingRoot,
        [Parameter(Mandatory)][string]$InstallDir,
        [Parameter(Mandatory)][string]$ItemName
    )
    $src = Join-Path $StagingRoot $ItemName
    if (-not (Test-Path -LiteralPath $src)) { return }
    if (-not (Test-Path -LiteralPath $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

    $dst = Join-Path $InstallDir $ItemName
    $newDst = Join-Path $InstallDir "$ItemName.new"
    $oldDst = Join-Path $InstallDir "$ItemName.old"

    if (Test-Path -LiteralPath $newDst) { Remove-Item -LiteralPath $newDst -Recurse -Force }
    Copy-Item -LiteralPath $src -Destination $newDst -Recurse -Force
    if (Test-Path -LiteralPath $oldDst) { Remove-Item -LiteralPath $oldDst -Recurse -Force }

    $renamedOld = $false
    if (Test-Path -LiteralPath $dst) {
        Rename-Item -LiteralPath $dst -NewName "$ItemName.old"
        $renamedOld = $true
    }
    try {
        Rename-Item -LiteralPath $newDst -NewName $ItemName
    } catch {
        # The second rename is the one most likely to hit a transient
        # sharing violation (e.g. AV still scanning the just-copied files).
        # Put the previous live item back rather than leaving $InstallDir
        # with neither an old nor a current $ItemName.
        if ($renamedOld) { Rename-Item -LiteralPath $oldDst -NewName $ItemName -ErrorAction SilentlyContinue }
        throw
    }
    if (Test-Path -LiteralPath $oldDst) { Remove-Item -LiteralPath $oldDst -Recurse -Force -ErrorAction SilentlyContinue }
}

# --------------------------------------------------------------------------
# Parameter validation (exit 2, before anything is touched - and before the
# admin check, so a caller learns about a bad parameter without elevation)
#
# [Console]::Error + exit is used instead of Write-Error: under
# $ErrorActionPreference = 'Stop' Write-Error throws, and the exit code the
# caller sees would be 1 no matter what number followed it.
# --------------------------------------------------------------------------
function Exit-NtpUsage {
    param([string]$Message)
    [Console]::Error.WriteLine("ERROR: $Message")
    exit 2
}

if ($Insecure -and $CaCertPath) {
    Exit-NtpUsage "-Insecure and -CaCertPath are mutually exclusive. Pick one."
}
$TlsMode = if ($Insecure) { 'Insecure' } elseif ($CaCertPath) { 'Cacert' } else { 'Default' }
if ($TlsMode -eq 'Cacert' -and -not (Test-Path -LiteralPath $CaCertPath)) {
    Exit-NtpUsage "-CaCertPath '$CaCertPath' does not exist."
}
# Both values end up inside a download URL (and are saved for later updates),
# so anything outside the characters GitHub itself allows is refused up front.
if ($Repo -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') {
    Exit-NtpUsage "-Repo '$Repo' is not in owner/name form."
}
function Test-NtpRef {
    param([string]$Value)
    return ($Value -match '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -and $Value -notmatch '\.\.' -and -not $Value.EndsWith('/'))
}
if (-not (Test-NtpRef $Ref)) {
    Exit-NtpUsage "-Ref '$Ref' is not a valid branch or tag name."
}
$refWasGiven = $PSBoundParameters.ContainsKey('Ref')

# --------------------------------------------------------------------------
# Admin check
# --------------------------------------------------------------------------
if (-not (Test-NtpIsAdmin)) {
    [Console]::Error.WriteLine("ERROR: This installer must be run as Administrator.")
    exit 1
}
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

# A re-run that does not name a ref or a TLS option keeps what the existing
# install already uses, so re-running the installer for an unrelated reason
# never silently moves a pinned host onto the moving channel or drops its
# TLS choice.
$stateFilePath = Join-Path $InstallDir '.ntp-config-state.json'
$existingState = $null
if (Test-Path -LiteralPath $stateFilePath) {
    try { $existingState = Get-Content -LiteralPath $stateFilePath -Raw | ConvertFrom-Json } catch { $existingState = $null }
}
if ($existingState) {
    if (-not $refWasGiven -and $existingState.PSObject.Properties.Name -contains 'Ref' -and (Test-NtpRef ([string]$existingState.Ref))) {
        $Ref = [string]$existingState.Ref
        Write-Host "Keeping the existing update ref ($Ref)."
    }
    if (-not $Insecure -and -not $CaCertPath -and $existingState.PSObject.Properties.Name -contains 'TlsMode') {
        if ($existingState.TlsMode -eq 'Insecure') {
            $TlsMode = 'Insecure'
            Write-Host "Keeping the existing TLS setting (Insecure)."
        } elseif ($existingState.TlsMode -eq 'Cacert' -and $existingState.CaCertPath -and (Test-Path -LiteralPath $existingState.CaCertPath)) {
            $TlsMode = 'Cacert'
            $CaCertPath = [string]$existingState.CaCertPath
            Write-Host "Keeping the existing TLS setting (Cacert)."
        }
    }
}

if ($TlsMode -eq 'Insecure') {
    Write-Warning "-Insecure set. Downloads and update checks will skip TLS verification. Only appropriate on a trusted network."
}

# --------------------------------------------------------------------------
# Download, verify, and install
# --------------------------------------------------------------------------
$tmpRoot = Join-Path $env:TEMP "ntp-config-install-$([guid]::NewGuid().ToString('N'))"
$zipPath = Join-Path $env:TEMP "ntp-config-install-$([guid]::NewGuid().ToString('N')).zip"
# GitHub resolves archive/<ref> for a branch or a tag alike.
$archiveUrl = "https://github.com/$Repo/archive/$Ref.zip"

try {
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

    Write-Host "Downloading $archiveUrl ..."
    Invoke-NtpWebRequest -Uri $archiveUrl -OutFile $zipPath -TlsMode $TlsMode -CaCertPath $CaCertPath

    Expand-Archive -LiteralPath $zipPath -DestinationPath $tmpRoot -Force
    $extractedRoot = Get-ChildItem -LiteralPath $tmpRoot -Directory | Select-Object -First 1
    if (-not $extractedRoot) {
        throw "Downloaded archive did not contain a recognizable folder."
    }

    $mainScript = Join-Path $extractedRoot.FullName "$RepoSubPath\Configure-NtpConfig.ps1"
    if (-not (Test-Path -LiteralPath $mainScript)) {
        throw "$RepoSubPath\Configure-NtpConfig.ps1 not found in the downloaded archive."
    }

    Write-Host "Verifying Configure-NtpConfig.ps1 before installing..."
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($mainScript, [ref]$null, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw "Configure-NtpConfig.ps1 failed a syntax check:`n$($parseErrors | Out-String)"
    }

    # Only the contents of Windows\NTP-Config are installed - flattened
    # directly into $InstallDir - and the rest of the repo is left out
    # entirely, since none of it is relevant here. $InstallDir itself may
    # already hold state this installer owns (.ntp-config-state.json,
    # Backups\) that is not part of the archive at all;
    # Install-NtpStagedItem only touches items that exist in the staged
    # folder, so nothing else already there is disturbed.
    $stagedToolRoot = Join-Path $extractedRoot.FullName $RepoSubPath
    Get-ChildItem -LiteralPath $stagedToolRoot -Force | ForEach-Object {
        Install-NtpStagedItem -StagingRoot $stagedToolRoot -InstallDir $InstallDir -ItemName $_.Name
    }

    # A CA passed in from wherever it happened to be (Downloads, a temp
    # folder) is copied next to the tool, so later self-updates do not break
    # the day that original file is cleaned up.
    $savedCaPath = $null
    if ($TlsMode -eq 'Cacert') {
        $savedCaPath = Join-Path $InstallDir 'ca-cert.pem'
        if ((Resolve-Path -LiteralPath $CaCertPath).Path -ne $savedCaPath) {
            Copy-Item -LiteralPath $CaCertPath -Destination $savedCaPath -Force
        }
    }

    # Persisted so Configure-NtpConfig.ps1's own self-update does not need
    # -Insecure/-CaCertPath supplied again on every later run.
    $state = [ordered]@{
        Repo       = $Repo
        Ref        = $Ref
        TlsMode    = $TlsMode
        CaCertPath = $savedCaPath
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallDir '.ntp-config-state.json') -Encoding UTF8

    $binDir = $InstallDir
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $alreadyOnPath = ($machinePath -split ';') | Where-Object { $_.TrimEnd('\') -ieq $binDir.TrimEnd('\') }
    if (-not $alreadyOnPath) {
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;$binDir", 'Machine')
        $env:Path = "$env:Path;$binDir"
        Write-Host "Added $binDir to the machine PATH."
    }

    Write-Host ""
    Write-Host "Install-NtpConfig.ps1 $ScriptVersion complete."
    Write-Host "  Repo:      $Repo"
    Write-Host "  Follows:   $Ref"
    Write-Host "  TLS mode:  $TlsMode"
    Write-Host "  Installed: $InstallDir"
    Write-Host ""
    Write-Host "Run it with (this shell already has the updated PATH; new shells will too):"
    Write-Host "  Configure-NtpConfig.ps1"
    Write-Host "Or double-click $(Join-Path $binDir 'runme.cmd') (self-elevates if needed)."
    Write-Host "It checks for and applies updates automatically on every run. No scheduled"
    Write-Host "tasks were created; none are needed for this tool."
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
}
