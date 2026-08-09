<#
.SYNOPSIS
    setup-gitea-mcp.ps1

.DESCRIPTION
    Adds C:\DATA\Tools\GiteaMCP and C:\DATA\Tools\Tea to the user PATH if
    missing, sets GITEA_HOST and GITEA_ACCESS_TOKEN as persistent user
    environment variables, registers gitea-mcp with Claude Code, and
    optionally configures a tea CLI login profile. Prompts for the PAT
    interactively rather than accepting it as a plaintext argument, so it
    never lands in shell history or a saved script.

.PARAMETER GiteaHost
    Your Gitea instance URL, e.g. https://git.example.com. No default -
    every deployment points at a different Gitea instance, so this must
    be supplied explicitly via -GiteaHost or, if omitted, you will be
    prompted for it interactively.

.PARAMETER TeaLoginName
    Local profile name used for the optional `tea` CLI login (tea login
    add --name ...). Purely a local label; defaults to "gitea".

.NOTES
    Version: v1.1.0
    Last Edit Date: 2026-08-09
#>

param(
    [string]$GiteaHost,
    [string]$ToolsPath = "C:\DATA\Tools",
    [string]$TeaLoginName = "gitea",
    [switch]$SkipTeaLogin
)

$ErrorActionPreference = "Stop"

$giteaMcpExe = Join-Path $ToolsPath "GiteaMCP\gitea-mcp.exe"
$teaExe = Join-Path $ToolsPath "Tea\tea.exe"

if (-not (Test-Path $giteaMcpExe)) {
    Write-Error "gitea-mcp.exe not found at $giteaMcpExe - check the path."
    exit 1
}

# --- Resolve the Gitea host URL: use -GiteaHost if given, else prompt.
#     No baked-in default - pointing this at the wrong Gitea instance
#     silently registers gitea-mcp against someone else's server. ---
if ([string]::IsNullOrWhiteSpace($GiteaHost)) {
    $GiteaHost = Read-Host "Enter your Gitea host URL (e.g. https://git.example.com)"
}
if ([string]::IsNullOrWhiteSpace($GiteaHost)) {
    Write-Error "No Gitea host URL entered - aborting."
    exit 1
}
if ($GiteaHost -notmatch '^https?://') {
    Write-Error "Gitea host URL must start with http:// or https:// - got '$GiteaHost'."
    exit 1
}
$GiteaHost = $GiteaHost.TrimEnd('/')

# --- Prompt for the PAT securely ---
$secureToken = Read-Host "Enter your Gitea Personal Access Token" -AsSecureString
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
$token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Error "No token entered - aborting."
    exit 1
}

# --- Add the GiteaMCP and Tea subfolders to the user PATH if not already present ---
# (gitea-mcp.exe and tea.exe live in their own subfolders now, not directly under
# ToolsPath, so it's their specific folders that need to be on PATH, not the root.)
$currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
$pathEntries = $currentPath -split ";" | Where-Object { $_ -ne "" }
$foldersToAdd = @((Split-Path -Parent $giteaMcpExe), (Split-Path -Parent $teaExe)) | Select-Object -Unique

$newEntries = $foldersToAdd | Where-Object { $pathEntries -notcontains $_ }
if ($newEntries) {
    Write-Host "Adding to user PATH: $($newEntries -join ', ')"
    $newPath = ($pathEntries + $newEntries) -join ";"
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Host "PATH updated. Open a new terminal for this to take effect there."
} else {
    Write-Host "GiteaMCP and Tea folders already present in user PATH - skipping."
}

# --- Set GITEA_HOST and GITEA_ACCESS_TOKEN as persistent user env vars ---
[Environment]::SetEnvironmentVariable("GITEA_HOST", $GiteaHost, "User")
[Environment]::SetEnvironmentVariable("GITEA_ACCESS_TOKEN", $token, "User")
Write-Host "GITEA_HOST set to $GiteaHost"
Write-Host "GITEA_ACCESS_TOKEN set (value not displayed)."

# --- Register gitea-mcp with Claude Code ---
Write-Host "Registering gitea-mcp with Claude Code..."
& claude mcp add --transport stdio --scope user gitea `
    --env "GITEA_ACCESS_TOKEN=$token" `
    --env "GITEA_HOST=$GiteaHost" `
    -- $giteaMcpExe -t stdio

if ($LASTEXITCODE -ne 0) {
    Write-Warning "claude mcp add returned a non-zero exit code - check the output above."
} else {
    Write-Host "gitea-mcp registered. Restart Claude Code (or start a new session) to pick it up."
}

# --- Optional: tea CLI login profile ---
if (-not $SkipTeaLogin -and (Test-Path $teaExe)) {
    $giteaUsername = Read-Host "Enter your Gitea username (for tea CLI login, press Enter to skip)"
    if (-not [string]::IsNullOrWhiteSpace($giteaUsername)) {
        & $teaExe login add --name $TeaLoginName --url $GiteaHost --user $giteaUsername --token $token
        Write-Host "tea CLI login profile '$TeaLoginName' created."
    } else {
        Write-Host "Skipping tea CLI login (no username entered)."
    }
}

# --- Clear the token from memory in this session ---
Remove-Variable token -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Done. Verify with: claude mcp list"
