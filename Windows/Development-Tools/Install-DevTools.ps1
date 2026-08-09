<#
.SYNOPSIS
    Install-DevTools.ps1

.DESCRIPTION
    Downloads and installs the core Windows development toolchain: Claude Code, Git for
    Windows, Node.js LTS, Gitea, Gitea MCP, Tea CLI, GitHub CLI, GitHub Desktop, Visual
    Studio Code, and Notepad++. Everything is installed under C:\DATA\Tools (subfolders are
    created automatically), and system-wide (Machine scope) environment variables and PATH
    entries are configured afterward so every tool is available from any new terminal
    session, for any user on the machine.

    This script is self-contained and location-independent: it never references its own
    original folder. Copy it and Run-Install-DevTools.cmd to any folder on any Windows 10/11
    machine and run the .cmd file.

.NOTES
    Version: v1.0.0
    Last Edit Date: 2026-08-01
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------

$script:ToolsRoot   = 'C:\DATA\Tools'
$script:DownloadDir = Join-Path $script:ToolsRoot 'Downloads'
$script:LogDir      = Join-Path $script:ToolsRoot 'Logs'
$script:LogFile     = $null
$script:ResolvedPaths = @{}
$script:Failures      = New-Object System.Collections.Generic.List[object]
$script:GitHubHeaders = @{ 'User-Agent' = 'DevTools-Installer' }

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------

function Write-Log {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'DEBUG' { Write-Host $line -ForegroundColor DarkGray }
        default { Write-Host $line }
    }
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line
    }
}

# ----------------------------------------------------------------------------
# Environment / PATH helpers
# ----------------------------------------------------------------------------

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:PATH = "$machine;$user"
}

function Add-ToMachinePath {
    param([Parameter(Mandatory)][string]$Directory)
    $Directory = $Directory.TrimEnd('\')
    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = @($current -split ';' | Where-Object { $_ -ne '' })
    $alreadyPresent = $parts | Where-Object { $_.TrimEnd('\') -ieq $Directory }
    if ($alreadyPresent) {
        Write-Log "  PATH already contains $Directory" 'DEBUG'
        return
    }
    $newPath = ($parts + $Directory) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
    Write-Log "  Added to system PATH: $Directory" 'INFO'
    Update-SessionPath
}

function Remove-DirIfEmpty {
    param([Parameter(Mandatory)][string]$Directory)
    if (Test-Path -LiteralPath $Directory) {
        $hasContent = @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue).Count -gt 0
        if (-not $hasContent) {
            Remove-Item -LiteralPath $Directory -Force -ErrorAction SilentlyContinue
            Write-Log "  Removed unused empty folder: $Directory" 'DEBUG'
        }
    }
}

function Set-MachineEnvVar {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Machine')
    Set-Item -Path "Env:$Name" -Value $Value
    Write-Log "  Set machine environment variable $Name = $Value" 'INFO'
}

# ----------------------------------------------------------------------------
# Generic retry / download / checksum helpers
# ----------------------------------------------------------------------------

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$MaxAttempts = 3,
        [int]$BackoffSeconds = 5
    )
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            return & $Action
        } catch {
            Write-Log "  Attempt $i/$MaxAttempts failed: $($_.Exception.Message)" 'WARN'
            if ($i -lt $MaxAttempts) {
                Start-Sleep -Seconds ($i * $BackoffSeconds)
            } else {
                throw
            }
        }
    }
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$MaxAttempts = 3,
        [int]$TimeoutSec = 180
    )
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            Write-Log "  Downloading $Url (attempt $i/$MaxAttempts)..." 'INFO'
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec -Headers $script:GitHubHeaders
            if ((Get-Item $OutFile).Length -gt 0) { return }
            throw 'Downloaded file is empty.'
        } catch {
            Write-Log "  Download attempt $i failed: $($_.Exception.Message)" 'WARN'
            if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
            if ($i -lt $MaxAttempts) { Start-Sleep -Seconds ($i * 5) }
        }
    }
    throw "Failed to download $Url after $MaxAttempts attempts."
}

function Test-ChecksumAsset {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$ChecksumUrl,
        [Parameter(Mandatory)][string]$TargetFileName
    )
    try {
        # Invoke-WebRequest + .Content is used deliberately instead of Invoke-RestMethod:
        # these are plain-text checksum files, and RestMethod's content-type-based
        # auto-parsing can misbehave on file types it does not recognize.
        $response = Invoke-WebRequest -Uri $ChecksumUrl -UseBasicParsing -TimeoutSec 30 -Headers $script:GitHubHeaders
        $text = $response.Content
    } catch {
        Write-Log "  Could not download checksum file for verification: $($_.Exception.Message)" 'WARN'
        return
    }

    $match = [regex]::Match($text, '([a-fA-F0-9]{64})\s*[*]?\s*' + [regex]::Escape($TargetFileName))
    if (-not $match.Success) {
        $match = [regex]::Match($text, '^\s*([a-fA-F0-9]{64})\s*$', [Text.RegularExpressions.RegexOptions]::Multiline)
    }
    if (-not $match.Success) {
        Write-Log "  Could not locate a checksum entry for $TargetFileName; skipping verification." 'WARN'
        return
    }

    $expected = $match.Groups[1].Value
    $actual = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash
    if ($actual -ieq $expected) {
        Write-Log "  Checksum verified for $TargetFileName" 'INFO'
    } else {
        throw "Checksum mismatch for $TargetFileName. Expected $expected, got $actual. The download may be corrupt or tampered with."
    }
}

function Get-LatestReleaseInfo {
    param([Parameter(Mandatory)][string]$ApiUrl)
    return Invoke-WithRetry -MaxAttempts 3 -Action {
        Invoke-RestMethod -Uri $ApiUrl -UseBasicParsing -TimeoutSec 30 -Headers $script:GitHubHeaders
    }
}

# ----------------------------------------------------------------------------
# Locating what actually got installed (never trust an installer's exit code
# alone - confirm the executable is really there afterward).
# ----------------------------------------------------------------------------

function Find-InstalledExe {
    param(
        [Parameter(Mandatory)][string]$ExeHint,
        [string[]]$PreferredDirs = @()
    )

    foreach ($dir in $PreferredDirs) {
        if ($dir -and (Test-Path $dir)) {
            $hit = Get-ChildItem -Path $dir -Filter $ExeHint -Recurse -Depth 4 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }

    $cmd = Get-Command $ExeHint -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $roots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        (Join-Path $env:LocalAppData 'Programs'),
        $env:ProgramData
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($root in $roots) {
        $hit = Get-ChildItem -Path $root -Filter $ExeHint -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    return $null
}

# ----------------------------------------------------------------------------
# winget-based installer
# ----------------------------------------------------------------------------

function Install-WithWinget {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$WingetId,
        [Parameter(Mandatory)][string]$TargetDir,
        [Parameter(Mandatory)][string]$ExeHint,
        [string]$CliHint,
        [switch]$SkipRelocate,
        [switch]$SkipPath,
        [string]$EnvVarName,
        [string[]]$ExtraSearchDirs = @()
    )

    Write-Log "Installing $DisplayName (winget id: $WingetId)..." 'INFO'

    # $TargetDir is never pre-created here. winget/the underlying installer creates it
    # itself if relocation succeeds; if relocation is unsupported or the package turns out
    # to already be installed elsewhere, nothing should exist under C:\DATA\Tools for it.
    # The finally block below removes it again if it ended up empty either way.
    try {
        $commonArgs = @(
            'install', '--id', $WingetId, '--exact', '--silent',
            '--accept-package-agreements', '--accept-source-agreements',
            '--disable-interactivity'
        )

        $attempts = @()
        if (-not $SkipRelocate) {
            $attempts += , @('--scope', 'machine', '--location', $TargetDir)
            $attempts += , @('--location', $TargetDir)
        }
        $attempts += , @('--scope', 'machine')
        $attempts += , @()
        # Last resort: winget's own package database can believe something is already
        # installed (so it skips reinstalling) even when the app itself is missing or a
        # prior install left it broken/partial. --force makes winget actually re-run the
        # installer instead of trusting its own "already installed" bookkeeping.
        $attempts += , @('--force')

        $searchDirs = @($TargetDir) + $ExtraSearchDirs
        $resolved = $null

        foreach ($extra in $attempts) {
            $argList = $commonArgs + $extra
            Write-Log ("  winget " + ($argList -join ' ')) 'DEBUG'
            $proc = Start-Process -FilePath 'winget' -ArgumentList $argList -NoNewWindow -Wait -PassThru
            Update-SessionPath
            $resolved = Find-InstalledExe -ExeHint $ExeHint -PreferredDirs $searchDirs
            if ($resolved) {
                Write-Log "  Found $ExeHint at $resolved" 'INFO'
                break
            }
            Write-Log "  This attempt did not yield a locatable $ExeHint (winget exit code $($proc.ExitCode)); trying the next strategy..." 'WARN'
        }

        if (-not $resolved) {
            throw "$DisplayName installation could not be verified: $ExeHint was not found after all installation strategies were tried."
        }

        $script:ResolvedPaths[$DisplayName] = $resolved
        $resolvedDir = Split-Path -Parent $resolved

        if (-not $SkipPath) {
            Add-ToMachinePath -Directory $resolvedDir
            if ($CliHint) {
                $cliPath = Find-InstalledExe -ExeHint $CliHint -PreferredDirs $searchDirs
                if ($cliPath) {
                    Add-ToMachinePath -Directory (Split-Path -Parent $cliPath)
                } else {
                    Write-Log "  Note: companion CLI shim $CliHint was not found; the 'code' style command may not be on PATH yet." 'WARN'
                }
            }
        }

        if ($EnvVarName) {
            Set-MachineEnvVar -Name $EnvVarName -Value $resolvedDir
        }

        if ($resolvedDir.TrimEnd('\') -ieq $TargetDir.TrimEnd('\')) {
            Write-Log "  $DisplayName installed under $TargetDir as requested." 'INFO'
        } else {
            Write-Log "  $DisplayName installed at $resolvedDir (its installer does not support relocating into $TargetDir; nothing is left under C:\DATA\Tools for it)." 'INFO'
        }
    } finally {
        Remove-DirIfEmpty -Directory $TargetDir
    }
}

# ----------------------------------------------------------------------------
# Portable (direct binary release) installer, used for Gitea, Tea CLI, and
# Gitea MCP, none of which ship a Windows installer, only raw binaries.
# ----------------------------------------------------------------------------

function Install-PortableTool {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$ApiUrl,
        [Parameter(Mandatory)][string]$AssetPattern,
        [Parameter(Mandatory)][string]$TargetDir,
        [Parameter(Mandatory)][string]$ExeName,
        [switch]$IsZip
    )

    Write-Log "Installing $DisplayName..." 'INFO'

    # $TargetDir is only created right before it is actually written to, and cleaned up
    # again in the finally block if the install failed before reaching that point (bad
    # asset match, failed download, failed checksum) - never left behind empty.
    try {
        $release = Get-LatestReleaseInfo -ApiUrl $ApiUrl
        $asset = $release.assets | Where-Object { $_.name -match $AssetPattern } | Select-Object -First 1
        if (-not $asset) {
            throw "$DisplayName ($($release.tag_name)): no release asset matched pattern '$AssetPattern'."
        }
        Write-Log "  Latest version: $($release.tag_name); asset: $($asset.name)" 'INFO'

        $downloadPath = Join-Path $script:DownloadDir $asset.name
        Invoke-DownloadFile -Url $asset.browser_download_url -OutFile $downloadPath

        $checksumAsset = $release.assets | Where-Object { $_.name -ieq "$($asset.name).sha256" } | Select-Object -First 1
        if (-not $checksumAsset) {
            $checksumAsset = $release.assets | Where-Object { $_.name -match '_checksums?\.txt$' } | Select-Object -First 1
        }
        if ($checksumAsset) {
            Test-ChecksumAsset -FilePath $downloadPath -ChecksumUrl $checksumAsset.browser_download_url -TargetFileName $asset.name
        } else {
            Write-Log "  No published checksum found for $($asset.name); relying on HTTPS transport security only." 'WARN'
        }

        New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null

        if ($IsZip) {
            $extractDir = Join-Path $script:DownloadDir ([IO.Path]::GetFileNameWithoutExtension($asset.name))
            if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
            Expand-Archive -Path $downloadPath -DestinationPath $extractDir -Force
            $exeFound = Get-ChildItem -Path $extractDir -Filter $ExeName -Recurse | Select-Object -First 1
            if (-not $exeFound) { throw "${DisplayName}: $ExeName was not found inside the downloaded archive." }
            Copy-Item -Path (Join-Path $exeFound.DirectoryName '*') -Destination $TargetDir -Recurse -Force
        } else {
            Copy-Item -Path $downloadPath -Destination (Join-Path $TargetDir $ExeName) -Force
        }

        $finalExe = Join-Path $TargetDir $ExeName
        if (-not (Test-Path $finalExe)) {
            throw "${DisplayName}: expected executable was not found at $finalExe after install."
        }

        $script:ResolvedPaths[$DisplayName] = $finalExe
        Add-ToMachinePath -Directory $TargetDir
        Write-Log "  $DisplayName installed at $finalExe" 'INFO'
    } finally {
        Remove-DirIfEmpty -Directory $TargetDir
    }
}

# ----------------------------------------------------------------------------
# Claude Code (npm global package - depends on Node.js already being on PATH)
# ----------------------------------------------------------------------------

function Install-ClaudeCode {
    Write-Log 'Installing Claude Code (npm global package)...' 'INFO'
    Update-SessionPath

    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npm) {
        throw 'npm was not found on PATH. Node.js must install successfully before Claude Code can be installed.'
    }

    $npmGlobalDir = Join-Path $script:ToolsRoot 'npm-global'
    New-Item -ItemType Directory -Force -Path $npmGlobalDir | Out-Null

    # NPM_CONFIG_PREFIX is the authoritative, version-independent way to redirect npm's
    # global install location; set it first so it governs the install below regardless of
    # what happens with the best-effort "npm config set" call underneath it.
    Set-MachineEnvVar -Name 'NPM_CONFIG_PREFIX' -Value $npmGlobalDir
    Add-ToMachinePath -Directory $npmGlobalDir

    & npm config set prefix "$npmGlobalDir" --global
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  npm config set prefix returned exit code $LASTEXITCODE (non-fatal; NPM_CONFIG_PREFIX still governs the install)." 'WARN'
    }

    Write-Log '  Running: npm install -g @anthropic-ai/claude-code' 'INFO'
    & npm install -g '@anthropic-ai/claude-code'
    if ($LASTEXITCODE -ne 0) { throw "npm install -g @anthropic-ai/claude-code failed with exit code $LASTEXITCODE" }

    Update-SessionPath
    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claudeCmd) {
        $guess = Join-Path $npmGlobalDir 'claude.cmd'
        if (Test-Path $guess) { $claudeCmd = [pscustomobject]@{ Source = $guess } }
    }
    if (-not $claudeCmd) {
        throw "Claude Code installed via npm, but the 'claude' command could not be located afterward."
    }

    $script:ResolvedPaths['Claude Code'] = $claudeCmd.Source
    Write-Log "  Claude Code installed at $($claudeCmd.Source)" 'INFO'
}

# ----------------------------------------------------------------------------
# GitHub Desktop needs special handling: its Squirrel-based installer does
# not support a custom install location or a true machine-wide install. We
# install it normally, then record and clearly report its real location
# instead of pretending we relocated it.
# ----------------------------------------------------------------------------

function Install-GitHubDesktop {
    $displayName = 'GitHub Desktop'

    # GitHub Desktop's installer can never be relocated (see note below), so no folder
    # under C:\DATA\Tools is ever created for it. If an earlier version of this script
    # left one behind (with an INSTALL_LOCATION.txt note file inside), clean it up now.
    $legacyDir = Join-Path $script:ToolsRoot 'GitHubDesktop'
    $legacyNoteFile = Join-Path $legacyDir 'INSTALL_LOCATION.txt'
    if (Test-Path -LiteralPath $legacyNoteFile) {
        Remove-Item -LiteralPath $legacyNoteFile -Force -ErrorAction SilentlyContinue
        Write-Log "  Removed leftover note file from a previous run: $legacyNoteFile" 'DEBUG'
    }
    Remove-DirIfEmpty -Directory $legacyDir

    Write-Log "Installing $displayName (winget id: GitHub.GitHubDesktop)..." 'INFO'
    Write-Log '  Note: GitHub Desktop ships only a per-user Squirrel installer upstream. There is' 'WARN'
    Write-Log '  no supported way to force a machine-wide install or a custom install path for it.' 'WARN'
    Write-Log '  It will install to its standard per-user location; that path is recorded below.' 'WARN'

    $commonArgs = @(
        'install', '--id', 'GitHub.GitHubDesktop', '--exact', '--silent',
        '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity'
    )
    $attempts = @()
    $attempts += , @('--scope', 'machine')
    $attempts += , @()
    $attempts += , @('--force')

    $localAppDataTarget = Join-Path $env:LocalAppData 'GitHubDesktop'
    $resolved = $null

    foreach ($extra in $attempts) {
        # Squirrel (GitHub Desktop's installer framework) marks a failed/incomplete install
        # with a ".dead" file and leaves the real GitHubDesktop.exe missing, while winget's
        # own bookkeeping still reports the package as installed and refuses to touch it.
        # Clear that dead install out of the way before the --force retry so a fresh install
        # actually has a clean slate to write into.
        if ($extra -contains '--force' -and (Test-Path (Join-Path $localAppDataTarget '.dead'))) {
            Write-Log "  Found a dead/incomplete GitHub Desktop install at $localAppDataTarget; removing it before forcing a reinstall." 'WARN'
            Remove-Item -LiteralPath $localAppDataTarget -Recurse -Force -ErrorAction SilentlyContinue
        }
        $argList = $commonArgs + $extra
        Write-Log ("  winget " + ($argList -join ' ')) 'DEBUG'
        $proc = Start-Process -FilePath 'winget' -ArgumentList $argList -NoNewWindow -Wait -PassThru
        Update-SessionPath
        $resolved = Find-InstalledExe -ExeHint 'GitHubDesktop.exe' -PreferredDirs @($localAppDataTarget)
        if ($resolved) { break }
        Write-Log "  This attempt did not yield a locatable GitHubDesktop.exe (winget exit code $($proc.ExitCode)); trying the next strategy..." 'WARN'
    }

    if (-not $resolved) {
        throw "$displayName installation could not be verified: GitHubDesktop.exe was not found after installation."
    }

    $realDir = Split-Path -Parent $resolved
    $script:ResolvedPaths[$displayName] = $resolved
    Set-MachineEnvVar -Name 'GITHUB_DESKTOP_HOME' -Value $realDir

    Write-Log "  $displayName installed at $resolved (its installer cannot be relocated; nothing is left under C:\DATA\Tools for it - use GITHUB_DESKTOP_HOME instead)." 'INFO'
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    Write-Host 'This script must be run as Administrator (it installs software machine-wide and' -ForegroundColor Red
    Write-Host 'writes system environment variables). Run Run-Install-DevTools.cmd instead, or' -ForegroundColor Red
    Write-Host 'right-click this .ps1 file and choose "Run with PowerShell" from an elevated prompt.' -ForegroundColor Red
    exit 1
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host 'winget (Windows Package Manager) was not found on this system.' -ForegroundColor Red
    Write-Host 'Install "App Installer" from the Microsoft Store (search "App Installer" or visit' -ForegroundColor Red
    Write-Host 'https://apps.microsoft.com/detail/9nblggh4nns1), then run this script again.' -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Force -Path $script:ToolsRoot   | Out-Null
New-Item -ItemType Directory -Force -Path $script:DownloadDir | Out-Null
New-Item -ItemType Directory -Force -Path $script:LogDir      | Out-Null
$script:LogFile = Join-Path $script:LogDir ("install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

Write-Log '==================================================================' 'INFO'
Write-Log ' Development Tools Installer v1.0.0' 'INFO'
Write-Log " Installing under: $script:ToolsRoot" 'INFO'
Write-Log " Log file: $script:LogFile" 'INFO'
Write-Log '==================================================================' 'INFO'

# Tool subfolders are intentionally NOT pre-created here. Each installer function creates
# its own folder only once it actually has something to put there, so a tool that cannot be
# relocated (GitHub Desktop) or was already installed elsewhere never leaves an empty or
# note-only folder behind under C:\DATA\Tools.

function Invoke-InstallStep {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
    } catch {
        Write-Log "$Name FAILED: $($_.Exception.Message)" 'ERROR'
        $script:Failures.Add([pscustomobject]@{ Tool = $Name; Error = $_.Exception.Message })
    }
}

Write-Log '--- Phase 1: Dependencies (Git, Node.js) ---' 'INFO'

Invoke-InstallStep -Name 'Git for Windows' -Action {
    Install-WithWinget -DisplayName 'Git for Windows' -WingetId 'Git.Git' `
        -TargetDir (Join-Path $script:ToolsRoot 'Git') -ExeHint 'git.exe'
}

Invoke-InstallStep -Name 'Node.js LTS' -Action {
    Install-WithWinget -DisplayName 'Node.js LTS' -WingetId 'OpenJS.NodeJS.LTS' `
        -TargetDir (Join-Path $script:ToolsRoot 'NodeJS') -ExeHint 'node.exe'
}

Write-Log '--- Phase 2: Claude Code and GitHub tooling ---' 'INFO'

Invoke-InstallStep -Name 'Claude Code' -Action { Install-ClaudeCode }

Invoke-InstallStep -Name 'GitHub CLI' -Action {
    Install-WithWinget -DisplayName 'GitHub CLI' -WingetId 'GitHub.cli' `
        -TargetDir (Join-Path $script:ToolsRoot 'GitHubCLI') -ExeHint 'gh.exe'
}

Invoke-InstallStep -Name 'GitHub Desktop' -Action { Install-GitHubDesktop }

Write-Log '--- Phase 3: Editors ---' 'INFO'

Invoke-InstallStep -Name 'Visual Studio Code' -Action {
    Install-WithWinget -DisplayName 'Visual Studio Code' -WingetId 'Microsoft.VisualStudioCode' `
        -TargetDir (Join-Path $script:ToolsRoot 'VSCode') -ExeHint 'Code.exe' -CliHint 'code.cmd'
}

Invoke-InstallStep -Name 'Notepad++' -Action {
    Install-WithWinget -DisplayName 'Notepad++' -WingetId 'Notepad++.Notepad++' `
        -TargetDir (Join-Path $script:ToolsRoot 'NotepadPlusPlus') -ExeHint 'notepad++.exe'
}

Write-Log '--- Phase 4: Gitea ecosystem ---' 'INFO'

Invoke-InstallStep -Name 'Gitea' -Action {
    Install-PortableTool -DisplayName 'Gitea' `
        -ApiUrl 'https://api.github.com/repos/go-gitea/gitea/releases/latest' `
        -AssetPattern '^gitea-.*-windows-4\.0-amd64\.exe$' `
        -TargetDir (Join-Path $script:ToolsRoot 'Gitea') -ExeName 'gitea.exe'
}

Invoke-InstallStep -Name 'Tea CLI' -Action {
    Install-PortableTool -DisplayName 'Tea CLI' `
        -ApiUrl 'https://gitea.com/api/v1/repos/gitea/tea/releases/latest' `
        -AssetPattern '^tea-.*-windows-amd64\.exe$' `
        -TargetDir (Join-Path $script:ToolsRoot 'Tea') -ExeName 'tea.exe'
}

Invoke-InstallStep -Name 'Gitea MCP' -Action {
    Install-PortableTool -DisplayName 'Gitea MCP' `
        -ApiUrl 'https://gitea.com/api/v1/repos/gitea/gitea-mcp/releases/latest' `
        -AssetPattern '^gitea-mcp_Windows_x86_64\.zip$' `
        -TargetDir (Join-Path $script:ToolsRoot 'GiteaMCP') -ExeName 'gitea-mcp.exe' -IsZip
}

Write-Log '--- Phase 5: Final environment configuration ---' 'INFO'
Set-MachineEnvVar -Name 'DEVTOOLS_HOME' -Value $script:ToolsRoot
Update-SessionPath

# Self-healing sweep: each installer already cleans up its own unused folder, but this
# catches anything left behind by an older version of this script, or any other cause,
# so a completed run never leaves an empty tool folder sitting under C:\DATA\Tools.
Get-ChildItem -Path $script:ToolsRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notin @($script:DownloadDir, $script:LogDir) } |
    ForEach-Object { Remove-DirIfEmpty -Directory $_.FullName }

# Downloads is scratch space only, not a cache: every portable tool install always fetches
# the latest release fresh rather than checking for an existing local copy, so anything left
# in here after a run is pure dead weight (the raw .exe/.zip downloads that already got
# copied into their real tool folders). Clear its contents, but keep the folder itself so
# the next run has somewhere to stage into without recreating it.
if (Test-Path $script:DownloadDir) {
    Get-ChildItem -Path $script:DownloadDir -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------

Write-Log '==================================================================' 'INFO'
Write-Log ' Installation summary' 'INFO'
Write-Log '==================================================================' 'INFO'

foreach ($name in $script:ResolvedPaths.Keys | Sort-Object) {
    Write-Log ("  OK    {0,-20} {1}" -f $name, $script:ResolvedPaths[$name]) 'INFO'
}
foreach ($failure in $script:Failures) {
    Write-Log ("  FAIL  {0,-20} {1}" -f $failure.Tool, $failure.Error) 'ERROR'
}

Write-Log '' 'INFO'
Write-Log 'Next steps:' 'INFO'
Write-Log '  - Open a NEW terminal window (already-open windows will not see the updated PATH).' 'INFO'
Write-Log '  - git config --global user.name / user.email have not been set; do that yourself.' 'INFO'
Write-Log '  - Run "gh auth login" to authenticate GitHub CLI.' 'INFO'
Write-Log '  - Run "claude" to sign in to Claude Code.' 'INFO'
Write-Log '  - Gitea was installed as a standalone binary only; it is not configured or running' 'INFO'
Write-Log '    as a service. See https://docs.gitea.com/installation for app.ini and service setup.' 'INFO'
Write-Log '  - Gitea MCP needs your Gitea host URL and an access token; register it with Claude' 'INFO'
Write-Log '    Code once your Gitea instance exists, for example:' 'INFO'
Write-Log '    claude mcp add gitea -- "C:\DATA\Tools\GiteaMCP\gitea-mcp.exe" --host <your-gitea-url> --token <your-token>' 'INFO'
Write-Log '' 'INFO'
Write-Log "Full log saved to: $script:LogFile" 'INFO'

if ($script:Failures.Count -gt 0) {
    Write-Log "$($script:Failures.Count) tool(s) failed to install. Review the errors above." 'ERROR'
    exit 1
}

Write-Log 'All tools installed successfully.' 'INFO'
exit 0
