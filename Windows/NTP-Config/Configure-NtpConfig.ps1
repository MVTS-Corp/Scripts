<#
.SYNOPSIS
    Configure-NtpConfig.ps1

.DESCRIPTION
    Interactive tool to view and configure Windows time synchronization
    (w32time) on domain-joined clients, standalone/workgroup clients, member
    servers, domain controllers, and Hyper-V hosts.

    Domain-aware defaults:
      - Not domain-joined: operator picks an explicit upstream time source.
      - Domain-joined, not a DC: defaults to the domain hierarchy (nearest
        domain controller), which is what Windows already does on its own
        and is almost always correct. The operator can override this.
      - Domain Controller, PDC emulator: defaults to an explicit external
        time source, per Microsoft guidance, since it is the authoritative
        time source for the whole domain.
      - Domain Controller, not the PDC emulator: defaults to the domain
        hierarchy like a normal member, so it does not become a second,
        independent time island inside the domain.
      - If Group Policy is enforcing Windows Time Service settings on this
        machine, this tool detects it, shows the enforced values, and
        refuses to make local changes that policy would just overwrite
        again on the next refresh.

    Part of the MVTS-Corp/Scripts repo, under Windows\NTP-Config. When run
    from an install created by Install-NtpConfig.ps1, this script checks
    GitHub for a newer version on every run and applies it before doing
    anything else, via an HTTPS zip download (no git required). No
    scheduled tasks are used or required.

    All Windows components this tool uses (w32time, the NetSecurity module
    for firewall rules) ship with Windows itself - there is no
    dependency-install step here.

    UNATTENDED USE (for a larger provisioning script):
    Run it as its own process, never in-process, so the exit code and output
    are captured cleanly:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File Configure-NtpConfig.ps1 -TimeSource Default -AllowSubnet 192.168.1.0/24
    Passing -TimeSource and/or -AllowSubnet (or -Unattended) means it never
    prompts. Unattended runs are declarative and idempotent: each setting
    given is compared with what is configured and only changed if it
    differs, so repeating a command changes nothing and does not restart
    w32time. One registry backup is taken per run. The last line printed is
    "RESULT: changed" or "RESULT: unchanged". Self-update is off in
    unattended and -Status runs unless -Update is given, so the caller
    controls which version runs.

    Exit codes:
      0  success (changes applied, or nothing needed changing)
      1  runtime failure (not elevated, w32time would not start, ...)
      2  invalid parameters; nothing on the system was touched
      3  refused: the request does not suit this machine's role (for example
         -TimeSource DomainHierarchy on a standalone machine, or an external
         source on a domain member without -AllowAtypical); nothing changed
      4  time settings are enforced by Group Policy; nothing changed

.PARAMETER NoUpdate
    Skip the self-update check for this run (also: set NTP_SKIP_SELF_UPDATE=1).

.PARAMETER Update
    Check for a self-update even in unattended or -Status mode (off by
    default there).

.PARAMETER Unattended
    Never prompt. Implied by -TimeSource or -AllowSubnet.

.PARAMETER Status
    Print the current configuration and exit without changing anything.

.PARAMETER TimeSource
    Default (recommended for this machine's role, see above), Windows,
    UsaPool, Preferred, Custom (needs -CustomSource), or DomainHierarchy.

.PARAMETER CustomSource
    Hostnames or IPs for -TimeSource Custom (array, or comma/space separated).

.PARAMETER AllowSubnet
    The complete list of subnets allowed to query this machine's NTP server
    role, in CIDR form (array, or comma/space separated), or "none". The list
    REPLACES the current one: matching firewall rules are added and removed
    to follow. Enables the NTP server role when the list is not empty.

.PARAMETER AllowAtypical
    Permit an explicit external time source on a machine whose role would
    normally follow the domain hierarchy (domain members, secondary domain
    controllers, child-domain PDC emulators).

.NOTES
    Version: v1.6.0
    Last Edit Date: 2026-09-18

    CHANGELOG:
      v1.6.0 - Self-update follows the ref saved by Install-NtpConfig.ps1 (a
               branch or a tag, key Ref in the state file) instead of a fixed
               branch. The default is the "stable" channel, which only ever
               points at a tagged release; an install made with -Ref <tag> is
               pinned and never moves. The saved ref is validated before it
               is placed in a URL. A state file without a Ref (an older
               layout) prompts a re-run of the installer.
      v1.5.0 - Added unattended mode (-TimeSource, -CustomSource,
               -AllowSubnet, -AllowAtypical, -Unattended) and -Status so
               this tool can be driven by a larger provisioning script:
               declarative and idempotent, one registry backup per run, no
               prompts, a final RESULT line, and documented exit codes (0-4).
               Parameters are fully validated before anything is touched.
               Self-update is off by default in unattended and -Status runs
               (-Update opts in). -Status no longer starts or re-enables
               w32time as a side effect. The interactive menus now exit with
               an error, instead of looping, if their input closes. The
               interactive "replace all subnets" option now compares firewall
               rules by rule name instead of by the address string Windows
               reports back, which is normalized and did not match the CIDR
               that was typed, so every replace removed and re-added every
               rule. Example subnet changed to 192.168.1.0/24.
      v1.4.0 - Moved from a self-hosted Git server to the public
               MVTS-Corp/Scripts repo on GitHub. Self-update now reads the
               published script's version with one small download and only
               fetches the repo archive when that version is strictly newer
               (previously the whole archive came down on every run). The
               install state file is validated before use, and a state file
               left by an older install prompts a re-run of the installer
               instead of being followed.
      v1.3.0 - Last version published from the previous self-hosted repo.
#>

[CmdletBinding()]
param(
    [switch]$NoUpdate,
    [switch]$Update,
    [switch]$Unattended,
    [switch]$Status,
    [string]$TimeSource,
    [string[]]$CustomSource,
    [string[]]$AllowSubnet,
    [switch]$AllowAtypical
)

$ScriptVersion = 'v1.6.0'
$RepoSubPath = 'Windows\NTP-Config'
$RawSubPath = 'Windows/NTP-Config/Configure-NtpConfig.ps1'
$ErrorActionPreference = 'Stop'
$Script:LastBackup = $null
$Script:LastApplyOk = $false
$Script:BackupOncePerRun = $false
$Script:BoundParams = $PSBoundParameters

$WindowsDefaultSources = @('time.windows.com')
$UsaPoolSources = @('0.us.pool.ntp.org', '1.us.pool.ntp.org', '2.us.pool.ntp.org', '3.us.pool.ntp.org')
$PreferredSources = @('time.cloudflare.com', 'us.pool.ntp.org', 'time.nist.gov')
$AllowRulePrefix = 'NTP-SCRIPT-ALLOW-'

# ==========================================================================
# Admin / self-update helpers
# ==========================================================================
function Test-NtpIsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# See Install-NtpConfig.ps1 for the twin of this function - kept
# independent/self-contained on purpose (same convention as install.sh and
# configure-ntp-server.sh on the Linux side each carrying their own
# self-update logic rather than sharing a library file that would itself
# need to be fetched and trusted).
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

# Twin of the function in Install-NtpConfig.ps1 - see there for why the
# staged copy is verified before either rename happens. Works for both
# directories and individual files - Copy-Item/Remove-Item/Rename-Item all
# handle a plain file just as well as a directory, -Recurse is simply a
# no-op on a file.
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
        # sharing violation (e.g. AV still scanning the just-copied files,
        # or a handle still open on the currently-executing script inside
        # this very folder during a self-update). Put the previous live
        # item back rather than leaving $InstallDir with neither an old
        # nor a current $ItemName.
        if ($renamedOld) { Rename-Item -LiteralPath $oldDst -NewName $ItemName -ErrorAction SilentlyContinue }
        throw
    }
    if (Test-Path -LiteralPath $oldDst) { Remove-Item -LiteralPath $oldDst -Recurse -Force -ErrorAction SilentlyContinue }
}

# A git ref (branch or tag) as it appears in the install state file. The
# value ends up inside download URLs, so only the characters git allows in a
# branch or tag name in practice are accepted.
function Test-NtpRef {
    param([string]$Value)
    return ($Value -match '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -and $Value -notmatch '\.\.' -and -not $Value.EndsWith('/'))
}

# Returns 1 if $Candidate is a strictly higher version than $Current, 0 if
# equal, -1 if lower. Both must look like vX.Y.Z; anything else throws, so
# the caller's catch treats an unparseable version as "do not update".
function Compare-NtpVersion {
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Current
    )
    $c = [version]($Candidate.TrimStart('v', 'V'))
    $r = [version]($Current.TrimStart('v', 'V'))
    return $c.CompareTo($r)
}

# Reads $ScriptVersion out of a script file's text without running it.
# Anchored to the start of a line so the same pattern quoted inside a
# comment or string elsewhere in the file cannot be mistaken for it.
function Get-NtpScriptVersionFromFile {
    param([Parameter(Mandatory)][string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw
    $m = [regex]::Match($text, "(?m)^\`$ScriptVersion\s*=\s*'(v\d+\.\d+\.\d+)'")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# Self-update is best-effort only: any failure here (network, a locked
# file, a bad archive) must fall back to "keep running the current
# version" rather than crash the tool an operator is actively using to
# fix time sync on a box right now - the whole body is one try/catch for
# exactly that reason.
#
# Two-step on purpose: the published script alone is small, so its version
# is checked first with one cheap download, and the repo archive (the whole
# repo, since GitHub cannot serve a single subfolder) is only fetched when
# that version is strictly newer than the one running.
function Invoke-NtpSelfUpdate {
    if ($NoUpdate -or $env:NTP_SKIP_SELF_UPDATE -eq '1') { return }
    # A caller driving this tool controls which version runs; an unattended
    # or -Status run does not swap in a newer copy unless -Update asks for it.
    if (($Unattended -or $Status -or $TimeSource -or $AllowSubnet) -and -not $Update) { return }

    # $PSScriptRoot is $InstallDir itself - Install-NtpConfig.ps1 flattens
    # the repo's Windows\NTP-Config folder directly into $InstallDir.
    $installRoot = $PSScriptRoot
    $stateFile = Join-Path $installRoot '.ntp-config-state.json'
    if (-not (Test-Path -LiteralPath $stateFile)) {
        return # not running from a managed install - nothing to update from
    }

    $tmpRoot = $null
    $zipPath = $null
    $probePath = $null
    try {
        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json

        # The saved values become part of download URLs, so they are checked
        # against what GitHub itself allows before being used. A state file
        # from the older self-hosted layout has no Repo at all, and following
        # its old RepoUrl would point at a server that is no longer the
        # source, so that case asks for a re-run of the installer instead.
        if ($state.PSObject.Properties.Name -notcontains 'Repo') {
            Write-Warning "The install state file is from an older version of this tool. Re-run Install-NtpConfig.ps1 to switch to the current update source. Continuing with current version."
            return
        }
        if ($state.Repo -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' -or -not (Test-NtpRef ([string]$state.Ref))) {
            Write-Warning "The install state file has an invalid Repo/Ref. Continuing with current version."
            return
        }
        if (@('Default', 'Insecure', 'Cacert') -notcontains $state.TlsMode) {
            Write-Warning "The install state file has an unrecognized TlsMode '$($state.TlsMode)'. Continuing with current version."
            return
        }
        if ($state.TlsMode -eq 'Cacert' -and (-not $state.CaCertPath -or -not (Test-Path -LiteralPath $state.CaCertPath))) {
            Write-Warning "The CA certificate saved at install time ('$($state.CaCertPath)') no longer exists. Re-run Install-NtpConfig.ps1 with -CaCertPath. Continuing with current version."
            return
        }

        # Step 1: cheap version probe.
        $probePath = Join-Path $env:TEMP "ntp-config-probe-$([guid]::NewGuid().ToString('N')).ps1"
        $rawUrl = "https://raw.githubusercontent.com/$($state.Repo)/$($state.Ref)/$RawSubPath"
        try {
            Invoke-NtpWebRequest -Uri $rawUrl -OutFile $probePath -TlsMode $state.TlsMode -CaCertPath $state.CaCertPath
        } catch {
            Write-Warning "Could not reach GitHub to check for updates. Continuing with current version."
            return
        }

        $newVersion = Get-NtpScriptVersionFromFile -Path $probePath
        if (-not $newVersion) {
            Write-Warning "Could not read a version from the published script. Continuing with current version."
            return
        }
        $order = Compare-NtpVersion -Candidate $newVersion -Current $ScriptVersion
        if ($order -eq 0) {
            return # already current
        }
        if ($order -lt 0) {
            Write-Warning "Published version ($newVersion) is older than the running version ($ScriptVersion). Skipping to avoid a silent downgrade."
            return
        }

        Write-Host "Update available for NTP-Config ($ScriptVersion -> $newVersion). Downloading..."

        # Step 2: the archive.
        $tmpRoot = Join-Path $env:TEMP "ntp-config-update-$([guid]::NewGuid().ToString('N'))"
        $zipPath = Join-Path $env:TEMP "ntp-config-update-$([guid]::NewGuid().ToString('N')).zip"
        New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

        $archiveUrl = "https://github.com/$($state.Repo)/archive/$($state.Ref).zip"
        try {
            Invoke-NtpWebRequest -Uri $archiveUrl -OutFile $zipPath -TlsMode $state.TlsMode -CaCertPath $state.CaCertPath
        } catch {
            Write-Warning "Could not download the update archive. Continuing with current version."
            return
        }

        Expand-Archive -LiteralPath $zipPath -DestinationPath $tmpRoot -Force
        $extractedRoot = Get-ChildItem -LiteralPath $tmpRoot -Directory | Select-Object -First 1
        if (-not $extractedRoot) {
            Write-Warning "Downloaded update archive did not contain a recognizable folder. Continuing with current version."
            return
        }

        $stagedToolRoot = Join-Path $extractedRoot.FullName $RepoSubPath
        $newMainScript = Join-Path $stagedToolRoot 'Configure-NtpConfig.ps1'
        if (-not (Test-Path -LiteralPath $newMainScript)) {
            Write-Warning "Update archive did not contain $RepoSubPath\Configure-NtpConfig.ps1. Continuing with current version."
            return
        }

        # The probe and the archive are two separate downloads; if the
        # branch moved between them, what is about to be installed is not
        # what was just version-checked.
        $stagedVersion = Get-NtpScriptVersionFromFile -Path $newMainScript
        if ($stagedVersion -ne $newVersion) {
            Write-Warning "The downloaded archive ($stagedVersion) does not match the version just checked ($newVersion). Continuing with current version; the next run will retry."
            return
        }

        Write-Host "Verifying before applying..."
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($newMainScript, [ref]$null, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            Write-Warning "Downloaded update failed a syntax check. Continuing with current version."
            return
        }

        # Only the contents of Windows\NTP-Config are installed, flattened
        # directly into $installRoot, matching Install-NtpConfig.ps1's own
        # install behavior. Anything else already in $installRoot (the state
        # file, Backups\, a saved CA) is not part of the archive and is left
        # alone.
        Get-ChildItem -LiteralPath $stagedToolRoot -Force | ForEach-Object {
            Install-NtpStagedItem -StagingRoot $stagedToolRoot -InstallDir $installRoot -ItemName $_.Name
        }

        Write-Host "Update applied. Restarting with the new version..."
        $newScriptPath = Join-Path $installRoot 'Configure-NtpConfig.ps1'
        $exitCode = 0
        & $newScriptPath @PSBoundParameters
        $exitCode = $LASTEXITCODE
        exit $exitCode
    } catch {
        Write-Warning "Self-update failed ($($_.Exception.Message)). Continuing with current version."
    } finally {
        if ($tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
        if ($zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
        if ($probePath) { Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue }
    }
}

# ==========================================================================
# Role / policy detection
# ==========================================================================

# ProductType: 1 = Workstation, 2 = Domain Controller, 3 = Server.
function Get-NtpDomainInfo {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $os = Get-CimInstance -ClassName Win32_OperatingSystem

    $info = [ordered]@{
        PartOfDomain       = [bool]$cs.PartOfDomain
        DomainName         = $cs.Domain
        IsDC               = ($os.ProductType -eq 2)
        IsPdcEmulator      = $false
        IsForestRoot       = $false
        PdcRoleOwner       = $null
        RoleDetectionError = $null
    }

    if ($info.PartOfDomain -and $info.IsDC) {
        try {
            Add-Type -AssemblyName System.DirectoryServices -ErrorAction SilentlyContinue
            $adDomain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
            $info.PdcRoleOwner = $adDomain.PdcRoleOwner.Name
            $info.IsForestRoot = $adDomain.Forest.RootDomain.Name.Equals($adDomain.Name, [StringComparison]::OrdinalIgnoreCase)

            # Resolved via an actual directory-service bind for this computer
            # rather than DNS name resolution, so a stale/mismatched local
            # DNS suffix can't make a real PDC emulator compare unequal to
            # itself the way comparing raw GetHostEntry() strings could.
            $context = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext('DirectoryServer', $env:COMPUTERNAME)
            $localDC = [System.DirectoryServices.ActiveDirectory.DomainController]::GetDomainController($context)
            $info.IsPdcEmulator = [bool]($localDC.Name -and $adDomain.PdcRoleOwner.Name -and
                $localDC.Name.Equals($adDomain.PdcRoleOwner.Name, [StringComparison]::OrdinalIgnoreCase))
        } catch {
            $info.RoleDetectionError = $_.Exception.Message
        }
    }

    return $info
}

function Get-NtpRoleLabel {
    param($DomainInfo)
    if (-not $DomainInfo.PartOfDomain) { return 'Standalone/Workgroup' }
    if ($DomainInfo.IsDC) {
        if ($DomainInfo.IsPdcEmulator) {
            $rootNote = if ($DomainInfo.IsForestRoot) { 'forest root' } else { 'child domain' }
            return "Domain Controller - PDC Emulator, $rootNote ($($DomainInfo.DomainName))"
        }
        if ($DomainInfo.RoleDetectionError) { return "Domain Controller - PDC emulator role undetermined ($($DomainInfo.DomainName))" }
        return "Domain Controller - secondary ($($DomainInfo.DomainName))"
    }
    return "Domain Member ($($DomainInfo.DomainName))"
}

# Detects the three "Configure Windows NTP Client" / "Enable Windows NTP
# Client" / "Enable Windows NTP Server" Group Policy settings under
# Computer Configuration > Administrative Templates > System > Windows
# Time Service > Time Providers. Any of these existing means a background
# policy refresh will overwrite local w32tm changes to that aspect, so
# their presence is what this tool treats as "policy managed."
function Get-NtpGpoEnforcement {
    $paramsPath = 'HKLM:\SOFTWARE\Policies\Microsoft\W32Time\Parameters'
    $clientEnabledPath = 'HKLM:\SOFTWARE\Policies\Microsoft\W32Time\TimeProviders\NtpClient'
    $serverEnabledPath = 'HKLM:\SOFTWARE\Policies\Microsoft\W32Time\TimeProviders\NtpServer'

    $result = [ordered]@{
        Enforced            = $false
        NtpServer           = $null
        Type                = $null
        ClientEnabledPolicy = $null
        ServerEnabledPolicy = $null
    }

    if (Test-Path -LiteralPath $paramsPath) {
        $p = Get-ItemProperty -LiteralPath $paramsPath -ErrorAction SilentlyContinue
        if ($p) {
            if ($p.PSObject.Properties.Name -contains 'NtpServer') { $result.NtpServer = $p.NtpServer }
            if ($p.PSObject.Properties.Name -contains 'Type') { $result.Type = $p.Type }
        }
    }
    if (Test-Path -LiteralPath $clientEnabledPath) {
        $c = Get-ItemProperty -LiteralPath $clientEnabledPath -ErrorAction SilentlyContinue
        if ($c -and ($c.PSObject.Properties.Name -contains 'Enabled')) { $result.ClientEnabledPolicy = [bool]$c.Enabled }
    }
    if (Test-Path -LiteralPath $serverEnabledPath) {
        $s = Get-ItemProperty -LiteralPath $serverEnabledPath -ErrorAction SilentlyContinue
        if ($s -and ($s.PSObject.Properties.Name -contains 'Enabled')) { $result.ServerEnabledPolicy = [bool]$s.Enabled }
    }

    # Any of the three policies being set means a background policy refresh
    # will re-apply it, so any of them present is enough to lock the tool
    # down - not just "Configure Windows NTP Client".
    $result.Enforced = ($null -ne $result.NtpServer -or $null -ne $result.Type -or
        $null -ne $result.ClientEnabledPolicy -or $null -ne $result.ServerEnabledPolicy)

    return $result
}

# Best-effort only - a Server Core install without ServerManager, or a
# client SKU where Get-WindowsOptionalFeature is restricted, returns
# $null (unknown) rather than a false "not a Hyper-V host".
function Test-NtpHyperVHost {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        if ($os.ProductType -eq 1) {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
            return ($feature.State -eq 'Enabled')
        } else {
            $feature = Get-WindowsFeature -Name Hyper-V -ErrorAction Stop
            return [bool]$feature.Installed
        }
    } catch {
        return $null
    }
}

# ==========================================================================
# Backup / restore (registry export, parity with the Linux tool's
# timestamped chrony.conf backups)
# ==========================================================================
function Backup-NtpConfig {
    # Unattended runs take ONE backup, before the first write, so the
    # automatic restore in Invoke-NtpApplyAndRestart always returns to the
    # state the run started from (a second backup taken after the first
    # change would capture an intermediate state instead).
    if ($Script:BackupOncePerRun -and $Script:LastBackup) { return }

    # $PSScriptRoot is $InstallDir itself - see Invoke-NtpSelfUpdate above.
    $installRoot = $PSScriptRoot
    $backupDir = Join-Path $installRoot 'Backups'
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }

    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $bak = Join-Path $backupDir "W32Time.$stamp.reg"
    $null = & reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Services\W32Time' $bak /y 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $bak)) {
        throw "Failed to back up W32Time registry configuration to $bak."
    }
    $Script:LastBackup = $bak
    Write-Host "Backup saved: $bak"
}

function Restore-NtpConfig {
    param([Parameter(Mandatory)][string]$BackupPath)
    $null = & reg.exe import $BackupPath 2>&1
    return ($LASTEXITCODE -eq 0)
}

# ==========================================================================
# Time source selection / apply
# ==========================================================================
function Select-NtpServerSet {
    param([string]$Prompt)
    Write-Host ""
    Write-Host $Prompt
    Write-Host "  1) Windows default    ($($WindowsDefaultSources -join ', '))"
    Write-Host "  2) NTP Pool for USA   ($($UsaPoolSources -join ', '))"
    Write-Host "  3) Preferred servers  ($($PreferredSources -join ', '))"
    Write-Host "  4) Custom"
    $choice = Read-Host "Choice [1]"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }

    switch ($choice) {
        '1' { return $WindowsDefaultSources }
        '2' { return $UsaPoolSources }
        '3' { return $PreferredSources }
        '4' {
            $custom = Read-Host "Enter custom server(s), space separated"
            $tokens = @(($custom -split '\s+') | Where-Object { $_ -ne '' })
            if ($tokens.Count -eq 0) { Write-Warning "No servers entered."; return $null }
            foreach ($t in $tokens) {
                if ($t -notmatch '^[A-Za-z0-9.:-]+$') {
                    Write-Warning "'$t' is not a valid hostname/IP (letters, digits, '.', ':', '-' only)."
                    return $null
                }
            }
            return $tokens
        }
        default { Write-Warning "Invalid choice."; return $null }
    }
}

# The ,0x9 suffix (Client + SpecialPollInterval) on each manualpeerlist
# entry is the standard value used in Microsoft's own documented steps for
# configuring an authoritative/external time source (e.g. KB816042-style
# guidance) - not an arbitrary magic number.
function Set-NtpManualSource {
    param(
        [Parameter(Mandatory)][string[]]$Servers,
        [Nullable[bool]]$Reliable = $null
    )
    $peerList = ($Servers | ForEach-Object { "$_,0x9" }) -join ' '

    Backup-NtpConfig
    $Script:LastApplyOk = $false
    $cmdArgs = @('/config', "/manualpeerlist:$peerList", '/syncfromflags:manual')
    if ($null -ne $Reliable) { $cmdArgs += "/reliable:$(if ($Reliable) { 'yes' } else { 'no' })" }
    $cmdArgs += '/update'
    $output = & w32tm @cmdArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "w32tm /config failed (exit $LASTEXITCODE): $output"
        Write-Warning "Time source was NOT applied."
        return
    }

    $Script:LastApplyOk = $true
    Write-Host "Time source(s) set to: $($Servers -join ', ')"
}

function Set-NtpDomainHierarchy {
    param([Nullable[bool]]$Reliable = $null)

    Backup-NtpConfig
    $Script:LastApplyOk = $false
    $cmdArgs = @('/config', '/syncfromflags:domhier')
    if ($null -ne $Reliable) { $cmdArgs += "/reliable:$(if ($Reliable) { 'yes' } else { 'no' })" }
    $cmdArgs += '/update'
    $output = & w32tm @cmdArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "w32tm /config failed (exit $LASTEXITCODE): $output"
        Write-Warning "Time source was NOT applied."
        return
    }

    $Script:LastApplyOk = $true
    Write-Host "Time source set to: domain hierarchy (nearest domain controller)."
}

function Invoke-NtpConfigureTimeSource {
    param($DomainInfo)

    if (-not $DomainInfo.PartOfDomain) {
        $servers = Select-NtpServerSet -Prompt "Select upstream time source set:"
        if (-not $servers) { return }
        Set-NtpManualSource -Servers $servers
        return
    }

    if ($DomainInfo.IsDC) {
        if ($DomainInfo.IsPdcEmulator) {
            if ($DomainInfo.IsForestRoot) {
                Write-Host ""
                Write-Host "This machine is the PDC Emulator for $($DomainInfo.DomainName), the forest"
                Write-Host "root domain. Microsoft's guidance is that the forest root's PDC emulator"
                Write-Host "syncs from an external time source, since it is the authoritative time"
                Write-Host "source for the whole forest. Every other domain-joined machine follows"
                Write-Host "this DC (directly or transitively) by default."
                Write-Host ""
                Write-Host "  1) Configure external time source(s) (recommended for the forest root"
                Write-Host "     PDC emulator)"
                Write-Host "  2) Follow domain hierarchy instead (not applicable for a forest root -"
                Write-Host "     there is no parent domain to follow)"
                $choice = Read-Host "Choice [1]"
                if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }
            } else {
                Write-Host ""
                Write-Host "This machine is the PDC Emulator for $($DomainInfo.DomainName), a child"
                Write-Host "domain of the forest. Microsoft's guidance is that only the FOREST ROOT's"
                Write-Host "PDC emulator syncs externally - a child-domain PDC emulator should follow"
                Write-Host "the domain hierarchy like any other DC, so it stays in the same hierarchy"
                Write-Host "as the rest of the forest instead of becoming its own time island."
                Write-Host ""
                Write-Host "  1) Configure external time source(s) (atypical for a child-domain PDC"
                Write-Host "     emulator - only correct if this domain's parent is unreachable)"
                Write-Host "  2) Follow domain hierarchy instead (recommended/default for a"
                Write-Host "     child-domain PDC emulator)"
                $choice = Read-Host "Choice [2]"
                if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '2' }
            }
            switch ($choice) {
                '1' {
                    $servers = Select-NtpServerSet -Prompt "Select external time source set:"
                    if (-not $servers) { return }
                    if (-not $DomainInfo.IsForestRoot) {
                        Write-Warning "Overriding a child-domain PDC emulator to sync externally is atypical."
                    }
                    Set-NtpManualSource -Servers $servers -Reliable $true
                }
                '2' { Set-NtpDomainHierarchy -Reliable $false }
                default { Write-Warning "Invalid choice." }
            }
            return
        }

        if ($DomainInfo.RoleDetectionError) {
            Write-Warning "Could not determine whether this DC is the PDC emulator ($($DomainInfo.RoleDetectionError))."
            Write-Warning "Defaulting to the safer choice (domain hierarchy). Verify this DC's FSMO"
            Write-Warning "roles manually (e.g. 'netdom query fsmo') before overriding."
        }

        Write-Host ""
        Write-Host "This is a Domain Controller for $($DomainInfo.DomainName) but not the PDC"
        Write-Host "emulator. It should follow the domain hierarchy like a normal domain member,"
        Write-Host "not sync independently from an external source."
        Write-Host ""
        Write-Host "  1) Use domain hierarchy (recommended/default)"
        Write-Host "  2) Override with explicit external time source(s) (atypical - can create a"
        Write-Host "     second, independent time island inside the domain)"
        $choice = Read-Host "Choice [1]"
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }
        switch ($choice) {
            '1' { Set-NtpDomainHierarchy -Reliable $false }
            '2' {
                $servers = Select-NtpServerSet -Prompt "Select external time source set:"
                if (-not $servers) { return }
                Write-Warning "Overriding a non-PDCe domain controller to sync externally is atypical."
                Set-NtpManualSource -Servers $servers -Reliable $false
            }
            default { Write-Warning "Invalid choice." }
        }
        return
    }

    # Domain member, not a DC.
    Write-Host ""
    Write-Host "This machine is domain-joined ($($DomainInfo.DomainName)). Windows syncs time"
    Write-Host "from the domain hierarchy (the nearest domain controller) by default, which is"
    Write-Host "almost always correct. Overriding this is atypical and can cause Kerberos or"
    Write-Host "replication problems if this machine's clock drifts from the domain."
    Write-Host ""
    Write-Host "  1) Use domain hierarchy (recommended/default)"
    Write-Host "  2) Override with explicit external time source(s)"
    $choice = Read-Host "Choice [1]"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }
    switch ($choice) {
        '1' { Set-NtpDomainHierarchy }
        '2' {
            $servers = Select-NtpServerSet -Prompt "Select external time source set:"
            if (-not $servers) { return }
            Write-Warning "Overriding domain-hierarchy time sync on a domain member is atypical."
            Set-NtpManualSource -Servers $servers
        }
        default { Write-Warning "Invalid choice." }
    }
}

# ==========================================================================
# NTP server role + allowed subnets (Windows Firewall)
#
# Unlike the Linux tool, there is no separate config-file allow-list to
# keep in sync with the firewall: a tagged inbound firewall rule IS the
# allow entry here, so there is nothing that can drift out of sync with
# itself and no separate "re-create firewall rules" step is needed.
# ==========================================================================
function Test-NtpCidr {
    param([string]$Cidr)
    $octet = '(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    return $Cidr -match "^$octet(\.$octet){3}/(3[0-2]|[12]?[0-9])$"
}

function ConvertTo-NtpRuleName {
    param([string]$Cidr)
    return "$AllowRulePrefix$($Cidr -replace '/', '-')"
}

function Get-NtpAllowedSubnet {
    Get-NetFirewallRule -DisplayName "$AllowRulePrefix*" -ErrorAction SilentlyContinue | ForEach-Object {
        $addr = $_ | Get-NetFirewallAddressFilter
        [PSCustomObject]@{ Name = $_.DisplayName; Subnet = $addr.RemoteAddress }
    }
}

function Add-NtpAllowedSubnet {
    param([string]$Cidr)
    $name = ConvertTo-NtpRuleName $Cidr
    if (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue) { return $false }
    New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol UDP -LocalPort 123 `
        -RemoteAddress $Cidr -Action Allow -Profile Any | Out-Null
    return $true
}

function Remove-NtpAllowedSubnet {
    param(
        [string]$Cidr,
        [string]$RuleName
    )
    # Prefer the caller's already-known exact rule DisplayName over
    # reconstructing one from $Cidr - Get-NetFirewallAddressFilter can
    # report RemoteAddress back in a normalized form that does not
    # byte-for-byte match the CIDR string New-NetFirewallRule was
    # originally given, which would make a reconstructed name miss.
    $name = if ($RuleName) { $RuleName } else { ConvertTo-NtpRuleName $Cidr }
    $rule = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
    if (-not $rule) { return $false }
    $rule | Remove-NetFirewallRule
    return $true
}

function Enable-NtpServerRole {
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer'
    $current = (Get-ItemProperty -Path $path -Name Enabled -ErrorAction SilentlyContinue).Enabled
    if ($current -ne 1) {
        Backup-NtpConfig
        Set-ItemProperty -Path $path -Name Enabled -Value 1 -Type DWord
        return $true
    }
    return $false
}

function Invoke-NtpManageSubnet {
    Write-Host ""
    Write-Host "Current allowed subnets (NTP server role):"
    $existing = @(Get-NtpAllowedSubnet)
    if ($existing.Count -eq 0) {
        Write-Host "  (none configured yet)"
    } else {
        $existing | ForEach-Object { Write-Host "  $($_.Subnet)" }
    }

    Write-Host ""
    Write-Host "  1) Add a subnet"
    Write-Host "  2) Remove a subnet"
    Write-Host "  3) Replace all subnets"
    Write-Host "  4) Back / done"
    $choice = Read-Host "Choice [4]"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '4' }

    switch ($choice) {
        '1' {
            $new = Read-Host "Subnet to allow (CIDR, e.g. 192.168.1.0/24)"
            if (-not (Test-NtpCidr $new)) {
                Write-Warning "'$new' is not a valid CIDR (expected format A.B.C.D/nn)."
                return
            }
            Enable-NtpServerRole | Out-Null
            if (Add-NtpAllowedSubnet $new) {
                Write-Host "Allowed and firewall rule created for: $new"
            } else {
                Write-Host "$new was already allowed."
            }
        }
        '2' {
            if ($existing.Count -eq 0) { Write-Host "No subnets to remove."; return }
            for ($i = 0; $i -lt $existing.Count; $i++) { Write-Host "  $($i + 1)) $($existing[$i].Subnet)" }
            $idx = Read-Host "Number to remove"
            if ($idx -notmatch '^\d+$' -or [int]$idx -lt 1 -or [int]$idx -gt $existing.Count) {
                Write-Warning "Invalid selection."
                return
            }
            $target = $existing[[int]$idx - 1]
            if (Remove-NtpAllowedSubnet -RuleName $target.Name) {
                Write-Host "Access revoked for: $($target.Subnet)"
            } else {
                Write-Warning "Could not find a matching firewall rule for $($target.Subnet) to remove - it may have already been removed outside this tool."
            }
        }
        '3' {
            $all = Read-Host "Enter all subnets to allow, space separated"
            $newSubnets = @(($all -split '\s+') | Where-Object { $_ -ne '' })
            foreach ($s in $newSubnets) {
                if (-not (Test-NtpCidr $s)) {
                    Write-Warning "'$s' is not a valid CIDR. Aborting, no changes made."
                    return
                }
            }
            # Compared by firewall rule name, not by the address Windows
            # reports back: Get-NetFirewallAddressFilter returns a normalized
            # form of the CIDR that was typed, so an address comparison never
            # matched and every replace removed and re-added every rule.
            $newNames = @($newSubnets | ForEach-Object { ConvertTo-NtpRuleName $_ })
            $existingNames = @($existing | ForEach-Object { $_.Name })
            $removed = @($existing | Where-Object { $newNames -notcontains $_.Name })
            $added = @($newSubnets | Where-Object { $existingNames -notcontains (ConvertTo-NtpRuleName $_) })
            if ($added.Count -gt 0) { Enable-NtpServerRole | Out-Null }
            foreach ($r in $removed) {
                if (-not (Remove-NtpAllowedSubnet -RuleName $r.Name)) {
                    Write-Warning "Could not find a matching firewall rule for $($r.Subnet) to remove - it may have already been removed outside this tool."
                }
            }
            foreach ($a in $added) { Add-NtpAllowedSubnet $a | Out-Null }

            Write-Host "Allowed subnets updated:"
            if ($newSubnets.Count -eq 0) {
                Write-Host "  (none - this host will not answer NTP queries from any subnet)"
            } else {
                $newSubnets | ForEach-Object { Write-Host "  $_" }
            }
        }
        '4' { return }
        default { Write-Warning "Invalid choice." }
    }
}

# ==========================================================================
# Apply / restart
# ==========================================================================
function Invoke-NtpApplyAndRestart {
    try { Restart-Service -Name w32time -Force -ErrorAction Stop } catch {
        Write-Warning "w32time restart threw an error: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 2
    $svc = Get-Service -Name w32time -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Host "w32time restarted successfully."
        & w32tm /resync /nowait 2>&1 | Out-Null
        return $true
    }

    Write-Warning "w32time failed to start after the configuration change."
    if (-not $Script:LastBackup -or -not (Test-Path -LiteralPath $Script:LastBackup)) {
        Write-Warning "No backup from this session to restore automatically."
        return $false
    }

    Write-Warning "Restoring last-known-good configuration from $($Script:LastBackup) and retrying..."
    if (-not (Restore-NtpConfig -BackupPath $Script:LastBackup)) {
        Write-Warning "Failed to import backup $($Script:LastBackup)."
        return $false
    }
    Restart-Service -Name w32time -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $svc = Get-Service -Name w32time -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Warning "The last change was reverted because w32time would not start with it. w32time is back up on the previous config."
        return $false
    }

    Write-Warning "w32time still will not start even after restoring $($Script:LastBackup). This config change is likely not the cause. Manual intervention required."
    return $false
}

# ==========================================================================
# View configuration
# ==========================================================================
function Show-NtpGpoBanner {
    param($Gpo)
    Write-Host ""
    Write-Host "===================================================================="
    Write-Host " NTP settings on this machine are ENFORCED BY GROUP POLICY"
    Write-Host "===================================================================="
    Write-Host "Local changes made by this tool would just be overwritten by the next"
    Write-Host "policy refresh (gpupdate / background refresh), so this tool will not make"
    Write-Host "any local changes. Change the GPO instead:"
    Write-Host "  Computer Configuration > Administrative Templates > System >"
    Write-Host "  Windows Time Service > Time Providers"
    Write-Host ""
    if ($Gpo.NtpServer) { Write-Host "Enforced NtpServer            : $($Gpo.NtpServer)" }
    if ($Gpo.Type) { Write-Host "Enforced Type                 : $($Gpo.Type)" }
    if ($null -ne $Gpo.ClientEnabledPolicy) { Write-Host "NTP Client enabled by policy  : $($Gpo.ClientEnabledPolicy)" }
    if ($null -ne $Gpo.ServerEnabledPolicy) { Write-Host "NTP Server enabled by policy  : $($Gpo.ServerEnabledPolicy)" }
    Write-Host "===================================================================="
}

function Show-NtpConfiguration {
    param($DomainInfo, $Gpo, $HyperV)

    Write-Host ""
    Write-Host "===================================================================="
    Write-Host " Current Windows Time Configuration"
    Write-Host "===================================================================="

    Write-Host ""
    Write-Host "-- Role --"
    Write-Host "  $(Get-NtpRoleLabel $DomainInfo)"
    if ($HyperV -eq $true) {
        Write-Host ""
        Write-Host "  Hyper-V host role detected. If any guest VM on this host is a domain"
        Write-Host "  controller, disable the Hyper-V 'Time synchronization' integration"
        Write-Host "  service inside that guest - otherwise it can fight with the domain"
        Write-Host "  hierarchy sync on every VM heartbeat."
    }

    if ($Gpo.Enforced) {
        Write-Host ""
        Write-Host "-- Group Policy enforcement --"
        Write-Host "  NTP settings on this machine are enforced by Group Policy."
        if ($Gpo.NtpServer) { Write-Host "  Policy NtpServer : $($Gpo.NtpServer)" }
        if ($Gpo.Type) { Write-Host "  Policy Type      : $($Gpo.Type)" }
    }

    Write-Host ""
    Write-Host "-- w32tm /query /status --"
    & w32tm /query /status 2>&1 | ForEach-Object { "  $_" }

    Write-Host ""
    Write-Host "-- w32tm /query /configuration --"
    & w32tm /query /configuration 2>&1 | ForEach-Object { "  $_" }

    Write-Host ""
    Write-Host "-- Service status --"
    $svc = Get-Service -Name w32time -ErrorAction SilentlyContinue
    if ($svc) { Write-Host "  w32time: $($svc.Status)" } else { Write-Host "  w32time: NOT FOUND" }

    Write-Host ""
    Write-Host "-- NTP server role allowed subnets --"
    $subnets = @(Get-NtpAllowedSubnet)
    if ($subnets.Count -eq 0) {
        Write-Host "  (none configured)"
    } else {
        $subnets | ForEach-Object { Write-Host "  $($_.Subnet)" }
    }
    Write-Host "===================================================================="
}

# ==========================================================================
# Unattended mode (driven by -TimeSource / -AllowSubnet)
#
# Declarative: each setting given is compared with what is configured and
# only written if it differs, so running the same command twice changes
# nothing and does not restart w32time. One registry backup is taken per
# run. Refusals and Group Policy enforcement leave the machine untouched and
# say so with a distinct exit code (see the header).
# ==========================================================================

# Called after each Read-Host in the menus. Read-Host returns $null when its
# input has closed (redirected stdin at end-of-file), which the menus would
# otherwise treat as an invalid choice forever.
function Assert-NtpMenuInput {
    param($Value)
    if ($null -eq $Value) {
        Write-Warning "Input closed before a menu choice was made. For scripted use, pass -TimeSource and/or -AllowSubnet (see Get-Help)."
        exit 1
    }
}

function Exit-NtpUsage {
    param([string]$Message)
    [Console]::Error.WriteLine("ERROR: $Message")
    [Console]::Error.WriteLine("Run Get-Help .\Configure-NtpConfig.ps1 -Full for usage.")
    exit 2
}

# Splits array or comma/space separated input into clean tokens. Needed
# because powershell.exe -File hands "a,b" over as one string, not two.
function ConvertTo-NtpTokenList {
    param([string[]]$Values)
    return @($Values | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ -ne '' })
}

# Validates everything on the command line and returns the parsed request.
# Runs before the admin check and before anything on the system is touched.
function Get-NtpRequest {
    $bound = $Script:BoundParams
    $req = [ordered]@{
        Unattended = $false
        TimeSource = $null
        Custom     = @()
        AllowSet   = $false
        Allow      = @()
    }
    $validSources = @('Default', 'Windows', 'UsaPool', 'Preferred', 'Custom', 'DomainHierarchy')

    $timeGiven = $bound.ContainsKey('TimeSource')
    $allowGiven = $bound.ContainsKey('AllowSubnet')

    if ($timeGiven) {
        $match = $validSources | Where-Object { $_ -ieq $TimeSource } | Select-Object -First 1
        if (-not $match) { Exit-NtpUsage "-TimeSource must be one of: $($validSources -join ', ')." }
        $req.TimeSource = $match
        if ($match -eq 'Custom') {
            $tokens = @(ConvertTo-NtpTokenList $CustomSource)
            if ($tokens.Count -eq 0) { Exit-NtpUsage "-TimeSource Custom needs -CustomSource with at least one hostname or IP." }
            foreach ($t in $tokens) {
                if ($t -notmatch '^[A-Za-z0-9.:-]+$') { Exit-NtpUsage "-CustomSource: '$t' is not a valid hostname/IP (letters, digits, '.', ':', '-' only)." }
            }
            $req.Custom = $tokens
        } elseif ($bound.ContainsKey('CustomSource')) {
            Exit-NtpUsage "-CustomSource only applies together with -TimeSource Custom."
        }
    } elseif ($bound.ContainsKey('CustomSource')) {
        Exit-NtpUsage "-CustomSource only applies together with -TimeSource Custom."
    }

    if ($allowGiven) {
        $tokens = @(ConvertTo-NtpTokenList $AllowSubnet)
        if ($tokens.Count -eq 0) { Exit-NtpUsage "-AllowSubnet needs at least one subnet, or 'none'." }
        $req.AllowSet = $true
        if ($tokens.Count -eq 1 -and $tokens[0] -ieq 'none') {
            $req.Allow = @()
        } else {
            $seen = @{}
            $list = @()
            foreach ($t in $tokens) {
                if ($t -ieq 'none') { Exit-NtpUsage "-AllowSubnet: 'none' cannot be combined with subnets." }
                if (-not (Test-NtpCidr $t)) { Exit-NtpUsage "-AllowSubnet: '$t' is not a valid CIDR (expected A.B.C.D/nn, e.g. 192.168.1.0/24)." }
                # Repeats are collapsed so the same subnet is never handled twice.
                if (-not $seen.ContainsKey($t)) { $seen[$t] = $true; $list += $t }
            }
            $req.Allow = $list
        }
    }

    $hasSettings = $timeGiven -or $allowGiven
    if ($Status -and $hasSettings) { Exit-NtpUsage "-Status only reports; it cannot be combined with -TimeSource or -AllowSubnet." }
    if ($Unattended -and -not $hasSettings -and -not $Status) { Exit-NtpUsage "-Unattended needs -TimeSource and/or -AllowSubnet (or use -Status)." }
    if ($AllowAtypical -and -not $timeGiven) { Exit-NtpUsage "-AllowAtypical only applies together with -TimeSource." }

    $req.Unattended = ($hasSettings -or [bool]$Unattended)
    return $req
}

# Turns the requested -TimeSource into a concrete plan for THIS machine's
# role, using the same rules the interactive tool applies. Returns a plan
# with Refused set (and nothing else meaningful) when the request does not
# suit the role.
function Resolve-NtpTimePlan {
    param($DomainInfo, [string]$Choice, [string[]]$Custom, [bool]$AllowAtypicalOverride)

    $plan = [ordered]@{ Refused = $null; Mode = $null; Servers = @(); Reliable = $null; Label = $null }

    $isStandalone = -not $DomainInfo.PartOfDomain
    $isMember = $DomainInfo.PartOfDomain -and -not $DomainInfo.IsDC
    $isForestRootPdc = $DomainInfo.IsDC -and $DomainInfo.IsPdcEmulator -and $DomainInfo.IsForestRoot
    $isChildPdc = $DomainInfo.IsDC -and $DomainInfo.IsPdcEmulator -and -not $DomainInfo.IsForestRoot
    $isSecondaryDc = $DomainInfo.IsDC -and -not $DomainInfo.IsPdcEmulator
    $role = Get-NtpRoleLabel $DomainInfo

    # /reliable follows the role exactly as the interactive tool sets it.
    $domHierReliable = if ($isMember -or $isStandalone) { $null } else { $false }

    if ($Choice -eq 'Default') {
        if ($isStandalone) {
            $plan.Mode = 'Manual'; $plan.Servers = $PreferredSources
        } elseif ($isForestRootPdc) {
            $plan.Mode = 'Manual'; $plan.Servers = $PreferredSources; $plan.Reliable = $true
        } else {
            $plan.Mode = 'DomHier'; $plan.Reliable = $domHierReliable
        }
    } elseif ($Choice -eq 'DomainHierarchy') {
        if ($isStandalone) { $plan.Refused = "-TimeSource DomainHierarchy does not apply: this machine is not domain-joined ($role)."; return $plan }
        if ($isForestRootPdc) { $plan.Refused = "-TimeSource DomainHierarchy does not apply: this is the forest root PDC emulator and has no parent domain to follow ($role)."; return $plan }
        $plan.Mode = 'DomHier'; $plan.Reliable = $domHierReliable
    } else {
        $plan.Mode = 'Manual'
        switch ($Choice) {
            'Windows'   { $plan.Servers = $WindowsDefaultSources }
            'UsaPool'   { $plan.Servers = $UsaPoolSources }
            'Preferred' { $plan.Servers = $PreferredSources }
            'Custom'    { $plan.Servers = $Custom }
        }
        $plan.Reliable = if ($isForestRootPdc -or $isChildPdc) { $true } elseif ($isSecondaryDc) { $false } else { $null }
        $atypical = $isMember -or $isSecondaryDc -or $isChildPdc
        if ($atypical -and -not $AllowAtypicalOverride) {
            $plan.Refused = "An explicit external time source is atypical for this role ($role) and can create a disconnected time island. Use -TimeSource Default or DomainHierarchy, or add -AllowAtypical to do it anyway."
            return $plan
        }
    }

    $plan.Label = if ($plan.Mode -eq 'DomHier') { 'domain hierarchy' } else { $plan.Servers -join ', ' }
    return $plan
}

# True when the registry already holds what the plan would write. The peer
# list is compared as a case-insensitive set (w32tm may re-space it), and
# /reliable is compared via AnnounceFlags (5 = reliable, 10 = not).
function Test-NtpTimePlanApplied {
    param($Plan)
    $params = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -ErrorAction SilentlyContinue
    $config = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config' -ErrorAction SilentlyContinue
    if (-not $params) { return $false }

    if ($Plan.Mode -eq 'DomHier') {
        if ($params.Type -ne 'NT5DS') { return $false }
    } else {
        if ($params.Type -ne 'NTP') { return $false }
        $want = @($Plan.Servers | ForEach-Object { "$_,0x9".ToLowerInvariant() } | Sort-Object)
        $have = @(([string]$params.NtpServer -split '\s+') | Where-Object { $_ -ne '' } | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
        if (($want -join ' ') -ne ($have -join ' ')) { return $false }
    }

    if ($null -ne $Plan.Reliable) {
        $expected = if ($Plan.Reliable) { 5 } else { 10 }
        if (-not $config -or $config.AnnounceFlags -ne $expected) { return $false }
    }
    return $true
}

function Invoke-NtpUnattended {
    param($DomainInfo, $Gpo, $Request)

    if ($Gpo.Enforced) {
        Write-Warning "NTP settings on this machine are enforced by Group Policy; nothing was changed. Change the GPO (Computer Configuration > Administrative Templates > System > Windows Time Service > Time Providers) instead."
        Write-Host "RESULT: refused"
        exit 4
    }

    # Decide everything that can be refused BEFORE changing anything, so a
    # refusal never leaves a half-applied run behind.
    $plan = $null
    if ($Request.TimeSource) {
        $plan = Resolve-NtpTimePlan -DomainInfo $DomainInfo -Choice $Request.TimeSource -Custom $Request.Custom -AllowAtypicalOverride ([bool]$AllowAtypical)
        if ($plan.Refused) {
            Write-Warning $plan.Refused
            Write-Host "RESULT: refused"
            exit 3
        }
    }

    $Script:BackupOncePerRun = $true
    $changed = $false
    $needsRestart = $false

    if ($plan) {
        if (Test-NtpTimePlanApplied -Plan $plan) {
            Write-Host "Time source already set: $($plan.Label)"
        } else {
            if ($plan.Mode -eq 'DomHier') {
                Set-NtpDomainHierarchy -Reliable $plan.Reliable
            } else {
                Set-NtpManualSource -Servers $plan.Servers -Reliable $plan.Reliable
            }
            if (-not $Script:LastApplyOk) {
                Write-Warning "The time source could not be applied."
                exit 1
            }
            $changed = $true
            $needsRestart = $true
        }
    }

    if ($Request.AllowSet) {
        $existing = @(Get-NtpAllowedSubnet)
        $wantNames = @($Request.Allow | ForEach-Object { ConvertTo-NtpRuleName $_ })
        $existingNames = @($existing | ForEach-Object { $_.Name })
        $toRemove = @($existing | Where-Object { $wantNames -notcontains $_.Name })
        $toAdd = @($Request.Allow | Where-Object { $existingNames -notcontains (ConvertTo-NtpRuleName $_) })

        if ($Request.Allow.Count -gt 0 -and (Enable-NtpServerRole)) {
            Write-Host "NTP server role enabled."
            $changed = $true
            $needsRestart = $true   # the role flag only takes effect on a service restart
        }
        foreach ($r in $toRemove) {
            if (Remove-NtpAllowedSubnet -RuleName $r.Name) {
                Write-Host "Access revoked for: $($r.Subnet)"
                $changed = $true
            }
        }
        foreach ($a in $toAdd) {
            if (Add-NtpAllowedSubnet $a) {
                Write-Host "Allowed and firewall rule created for: $a"
                $changed = $true
            }
        }
        if ($toAdd.Count -eq 0 -and $toRemove.Count -eq 0) {
            Write-Host "Allowed subnets already set: $(if ($Request.Allow.Count -gt 0) { $Request.Allow -join ', ' } else { '(none)' })"
        }
    }

    # Restart only when a setting that needs it changed. Firewall-only
    # changes take effect immediately and do not bounce the time service.
    if ($needsRestart) {
        if (-not (Invoke-NtpApplyAndRestart)) {
            Write-Warning "w32time did not come up cleanly after the change."
            exit 1
        }
    }

    Write-Host $(if ($changed) { 'RESULT: changed' } else { 'RESULT: unchanged' })
    exit 0
}

# ==========================================================================
# Main menu
# ==========================================================================
function Start-NtpMainMenu {
    param($DomainInfo, $Gpo, $HyperV)

    if ($Gpo.Enforced) {
        Show-NtpGpoBanner -Gpo $Gpo
        while ($true) {
            Write-Host ""
            Write-Host "Configure-NtpConfig.ps1 $ScriptVersion  |  Role: $(Get-NtpRoleLabel $DomainInfo)  |  Group Policy managed"
            Write-Host "  1) View current configuration"
            Write-Host "  2) Exit"
            $opt = Read-Host "Choice"
            Assert-NtpMenuInput $opt
            switch ($opt) {
                '1' { Show-NtpConfiguration -DomainInfo $DomainInfo -Gpo $Gpo -HyperV $HyperV }
                '2' { Write-Host "Exiting."; return }
                default { Write-Warning "Invalid choice." }
            }
        }
    }

    while ($true) {
        Write-Host ""
        Write-Host "Configure-NtpConfig.ps1 $ScriptVersion  |  Role: $(Get-NtpRoleLabel $DomainInfo)"
        Write-Host "  1) View current configuration"
        Write-Host "  2) Configure time source(s)"
        Write-Host "  3) Configure NTP server role + allowed subnets"
        Write-Host "  4) Apply changes and restart w32time"
        Write-Host "  5) Exit"
        $opt = Read-Host "Choice"
        Assert-NtpMenuInput $opt
        switch ($opt) {
            '1' { Show-NtpConfiguration -DomainInfo $DomainInfo -Gpo $Gpo -HyperV $HyperV }
            '2' { Invoke-NtpConfigureTimeSource -DomainInfo $DomainInfo }
            '3' { Invoke-NtpManageSubnet }
            '4' { Invoke-NtpApplyAndRestart | Out-Null }
            '5' { Write-Host "Exiting."; return }
            default { Write-Warning "Invalid choice." }
        }
    }
}

# ==========================================================================
# Entry point
# ==========================================================================
# Validated first: a bad parameter must exit 2 without touching anything,
# and without needing elevation to find out.
$request = Get-NtpRequest

if (-not (Test-NtpIsAdmin)) {
    [Console]::Error.WriteLine("ERROR: This script must be run as Administrator.")
    exit 1
}
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

Invoke-NtpSelfUpdate

$svcCheck = Get-Service -Name w32time -ErrorAction SilentlyContinue
if (-not $svcCheck) {
    [Console]::Error.WriteLine("ERROR: The Windows Time (w32time) service was not found on this host.")
    exit 1
}
# -Status only reports, so it must not re-enable or start the service.
if (-not $Status) {
    if ($svcCheck.StartType -eq 'Disabled') {
        Set-Service -Name w32time -StartupType Automatic
        Write-Host "w32time was disabled; set it to Automatic startup."
    }
    if ($svcCheck.Status -ne 'Running') {
        Start-Service -Name w32time
    }
}

$domainInfo = Get-NtpDomainInfo
$gpo = Get-NtpGpoEnforcement
$hyperV = Test-NtpHyperVHost

Write-Host "Detected role: $(Get-NtpRoleLabel $domainInfo)"

if ($Status) {
    Show-NtpConfiguration -DomainInfo $domainInfo -Gpo $gpo -HyperV $hyperV
    exit 0
}

if ($request.Unattended) {
    try {
        Invoke-NtpUnattended -DomainInfo $domainInfo -Gpo $gpo -Request $request
    } catch {
        [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
        exit 1
    }
    exit 0
}

Start-NtpMainMenu -DomainInfo $domainInfo -Gpo $gpo -HyperV $hyperV
