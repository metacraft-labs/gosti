# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
  Install Visual Studio 2022 Build Tools into a Windows golden, verified.

.DESCRIPTION
  The ONE implementation of "install the VS Build Tools" shared by the
  Windows goldens:

    * windows-arm-base runs it from autounattend.xml's FirstLogonCommands,
      with the pins in vs-buildtools.pins (a digest-pinned bootstrapper it
      downloads itself) and -FailureMarker.
    * windows-x64-base/provision-ci-toolchain.ps1 calls it for its step 1,
      handing it the evergreen bootstrapper the host driver staged and
      -SignatureOnly (see ../windows-x64-base/ci-toolchain-golden.md for why
      that golden's bootstrapper is signature-checked rather than pinned).

  Steps, every one checked before it acts, so a re-run is a verification:

    1. If vswhere already finds an installation carrying EVERY component,
       stop: nothing to do.
    2. Obtain the bootstrapper: use -Bootstrapper if it exists, otherwise
       download VS_BUILDTOOLS_URL to it (not in -SignatureOnly mode, which
       has no URL it may trust by digest).
    3. Verify it: SHA-256 against VS_BUILDTOOLS_SHA256 (skipped only with
       -SignatureOnly) AND a valid Microsoft Authenticode signature.
    4. Run it: --quiet --wait --norestart --nocache --installPath <pin>
       --add <each component> --includeRecommended. Exit 0 and 3010 (success,
       reboot required) are success.
    5. Re-run the vswhere query from step 1. An installer that reports
       success while vswhere cannot see every component is a FAILURE: that
       is exactly the state that leaves a CI job with "link.exe not found".

  Failure handling depends on the caller:

    * Without -FailureMarker it throws, so a calling script (x64) fails.
    * With -FailureMarker it writes that marker file, logs, and EXITS 0. A
      non-zero exit from a FirstLogonCommand can wedge the rest of the chain,
      including the install-done sentinel. That is safe ONLY because the
      capture gate assert-vs-buildtools.ps1 refuses an image that carries the
      marker, and the headless ARM build runs that gate before sysprep.

  Windows PowerShell 5.1 compatible: FirstLogonCommands run it under 5.1.

.PARAMETER PinsPath
  The KEY=VALUE pins file. Defaults to vs-buildtools.pins next to this script.

.PARAMETER Bootstrapper
  Where the bootstrapper is, or is to be downloaded to. Defaults to
  C:\Windows\Temp\vs\vs_BuildTools-<VS_BUILDTOOLS_VERSION>.exe.

.PARAMETER Components
  Overrides VS_COMPONENTS from the pins file.

.PARAMETER InstallPath
  Overrides VS_INSTALL_PATH from the pins file.

.PARAMETER SignatureOnly
  Trust the bootstrapper by Authenticode alone: no digest check and no
  download. For an evergreen bootstrapper the caller staged.

.PARAMETER FailureMarker
  FirstLogonCommands mode; see above.

.PARAMETER LogPath
  Also append every log line to this file.
#>
[CmdletBinding()]
param(
    [string]$PinsPath = '',
    [string]$Bootstrapper = '',
    [string[]]$Components = @(),
    [string]$InstallPath = '',
    [switch]$SignatureOnly,
    [string]$FailureMarker = '',
    [string]$LogPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

function Write-VsLog {
    param([string]$Message)
    $line = "[vs-buildtools] $Message"
    Write-Host $line
    if ($LogPath) {
        try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
    }
}

function Read-VsPins {
    param([string]$Path)
    $pins = @{}
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $pins }
    foreach ($raw in Get-Content -LiteralPath $Path) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -le 0) { continue }
        $pins[$line.Substring(0, $eq).Trim()] = $line.Substring($eq + 1).Trim()
    }
    return $pins
}

function Get-VsWherePath {
    $pf86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
    if (-not $pf86) { return '' }   # not Windows: there is no vswhere to find
    return (Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe')
}

# The installation vswhere reports as carrying EVERY component, or $null. The
# same query agent-harbor's workflow and infra's persistent runner run.
function Find-VsInstall {
    param([string[]]$Required)
    $vswhere = Get-VsWherePath
    if (-not $vswhere -or -not (Test-Path -LiteralPath $vswhere)) { return $null }
    $q = @('-products', '*', '-format', 'json')
    foreach ($c in $Required) { $q += @('-requires', $c) }
    $found = & $vswhere @q | Out-String | ConvertFrom-Json
    if ($found) { return @($found)[0] }
    return $null
}

function Invoke-ProvisionVsBuildTools {
    $pinsFile = $PinsPath
    if (-not $pinsFile) { $pinsFile = Join-Path $PSScriptRoot 'vs-buildtools.pins' }
    $pins = Read-VsPins $pinsFile

    $want = @($Components | Where-Object { $_ })
    if ($want.Count -eq 0 -and $pins.ContainsKey('VS_COMPONENTS')) {
        $want = @($pins['VS_COMPONENTS'] -split '\s+' | Where-Object { $_ })
    }
    if ($want.Count -eq 0) { throw "no components given and $pinsFile has no VS_COMPONENTS" }

    $target = $InstallPath
    if (-not $target -and $pins.ContainsKey('VS_INSTALL_PATH')) { $target = $pins['VS_INSTALL_PATH'] }
    if (-not $target) { throw "no install path given and $pinsFile has no VS_INSTALL_PATH" }

    # 1. Already there?
    $have = Find-VsInstall $want
    if ($have) {
        Write-VsLog "already installed with every component: $($have.installationPath) $($have.installationVersion)"
        return
    }

    # 2. Obtain the bootstrapper.
    $version = ''
    if ($pins.ContainsKey('VS_BUILDTOOLS_VERSION')) { $version = $pins['VS_BUILDTOOLS_VERSION'] }
    $boot = $Bootstrapper
    if (-not $boot) {
        if (-not $version) { throw "no -Bootstrapper given and $pinsFile has no VS_BUILDTOOLS_VERSION" }
        $boot = "C:\Windows\Temp\vs\vs_BuildTools-$version.exe"
    }
    if (-not (Test-Path -LiteralPath $boot)) {
        if ($SignatureOnly) { throw "bootstrapper not staged: $boot (-SignatureOnly never downloads)" }
        foreach ($k in 'VS_BUILDTOOLS_URL', 'VS_BUILDTOOLS_SHA256') {
            if (-not $pins.ContainsKey($k)) { throw "$pinsFile is missing $k" }
        }
        $dir = Split-Path -Parent $boot
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # Windows PowerShell 5.1 may default to TLS 1.0, which Microsoft's
        # download CDN refuses.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Write-VsLog "downloading $($pins['VS_BUILDTOOLS_URL'])"
        Invoke-WebRequest -UseBasicParsing -Uri $pins['VS_BUILDTOOLS_URL'] -OutFile $boot
    }

    # 3. Verify it: digest (unless evergreen) and Microsoft Authenticode.
    if (-not $SignatureOnly) {
        if (-not $pins.ContainsKey('VS_BUILDTOOLS_SHA256')) { throw "$pinsFile is missing VS_BUILDTOOLS_SHA256" }
        $expected = $pins['VS_BUILDTOOLS_SHA256'].ToLowerInvariant()
        $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $boot).Hash.ToLowerInvariant()
        if ($got -ne $expected) {
            # Never leave a bad download where the next run would pick it up.
            Remove-Item -LiteralPath $boot -Force -ErrorAction SilentlyContinue
            throw "vs_BuildTools.exe digest mismatch: expected $expected, got $got"
        }
        Write-VsLog "vs_BuildTools.exe $version digest OK ($got)"
    }
    $sig = Get-AuthenticodeSignature -LiteralPath $boot
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "vs_BuildTools.exe signature not valid Microsoft: $($sig.Status) $($sig.SignerCertificate.Subject)"
    }
    Write-VsLog "vs_BuildTools.exe signature OK ($($sig.SignerCertificate.Subject))"

    # 4. Install.
    $vsArgs = @('--quiet', '--wait', '--norestart', '--nocache', '--installPath', "`"$target`"")
    foreach ($c in $want) { $vsArgs += @('--add', $c) }
    $vsArgs += '--includeRecommended'
    Write-VsLog "installing VS Build Tools: $($vsArgs -join ' ')"
    $p = Start-Process -FilePath $boot -ArgumentList $vsArgs -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        # The installer's own logs are the only account of what went wrong.
        Get-ChildItem -Path $env:TEMP -Filter 'dd_*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 2 |
            ForEach-Object {
                Write-VsLog "---- tail $($_.Name)"
                Get-Content -LiteralPath $_.FullName -Tail 40 | ForEach-Object { Write-VsLog $_ }
            }
        throw "VS Build Tools install failed, exit $($p.ExitCode)"
    }
    Write-VsLog "VS Build Tools installer exit $($p.ExitCode)"

    # 5. A success exit is not the property; vswhere seeing every component is.
    $have = Find-VsInstall $want
    if (-not $have) {
        throw "VS Build Tools installer exited $($p.ExitCode) but vswhere does not find every component: $($want -join ' ')"
    }
    Write-VsLog "installed: $($have.installationPath) $($have.installationVersion)"
}

if ($FailureMarker) {
    try {
        Remove-Item -LiteralPath $FailureMarker -Force -ErrorAction SilentlyContinue
        Invoke-ProvisionVsBuildTools
    } catch {
        $msg = "VS Build Tools provisioning FAILED: $($_.Exception.Message)"
        Write-VsLog $msg
        try { Set-Content -LiteralPath $FailureMarker -Value $msg -Encoding UTF8 -Force } catch { }
    }
    exit 0
}
Invoke-ProvisionVsBuildTools
