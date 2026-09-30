# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
  Provision the CI toolchain layer into a running Windows x64 golden.

.DESCRIPTION
  Runs INSIDE the throwaway work guest that build-ci-toolchain-golden.sh boots
  off a copy of the golden. Elevated (the recipe's admin account). Idempotent:
  every step checks before it acts, so a re-run on an already-provisioned image
  is a verification pass.

  Installs / sets, from the pins in ci-toolchain.pins (staged alongside):
    1. Visual Studio 2022 Build Tools with VS_COMPONENTS (+ recommended),
       which brings the MSVC x64 toolset and the Windows SDK.
    2. WinFsp (MSI, digest-checked).
    3. Win32 long paths (LongPathsEnabled=1) and Git's core.longpaths.
    4. The actions runner at C:\actions-runner, re-staged only when the staged
       version differs from the pin (zip digest-checked).
    5. The guest clock contract (-ClockMode, see below).
    6. Optionally grows C: into unallocated space the host added.

  Antivirus, Windows Update and Windows Search are NOT handled here. A running
  guest cannot turn its own real-time scanning off
  (../lib/harden-defender.README.md), and UsoSvc / WaaSMedicSvc refuse an
  online change. The host driver disables all of them offline, after shutdown,
  with ../lib/apply-offline-service-payloads.sh (payloads defender-off and
  ci-background-off).

.PARAMETER StageDir
  Directory holding ci-toolchain.pins and the host-fetched installers.

.PARAMETER ClockMode
  utc   - RealTimeIsUniversal=1 and time zone UTC. Correct ONLY on a domain
          whose RTC is <clock offset='utc'> (gosti's ephemeral libvirt XML).
  keep  - leave the image's clock settings exactly as they are. For a golden
          that must keep working under an older, offset='localtime' domain.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StageDir,
    [ValidateSet('utc', 'keep')][string]$ClockMode = 'utc',
    [switch]$GrowSystemVolume
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

function Log { param($m) Write-Host "[ci-toolchain] $m" }

function Read-Pins {
    param([string]$Path)
    $pins = @{}
    foreach ($raw in Get-Content -LiteralPath $Path) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -le 0) { continue }
        $pins[$line.Substring(0, $eq).Trim()] = $line.Substring($eq + 1).Trim()
    }
    return $pins
}

function Assert-Sha256 {
    param([string]$Path, [string]$Expected, [string]$Label)
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    if ($got -ne $Expected.ToLowerInvariant()) {
        throw "$Label digest mismatch: expected $Expected, got $got"
    }
    Log "$Label digest OK ($got)"
}

$pins = Read-Pins (Join-Path $StageDir 'ci-toolchain.pins')
foreach ($k in 'ACTIONS_RUNNER_VERSION', 'ACTIONS_RUNNER_SHA256_WIN_X64', 'WINFSP_VERSION',
    'WINFSP_MSI_SHA256', 'VS_INSTALL_PATH', 'VS_COMPONENTS', 'WINDOWS_SDK_VERSION') {
    if (-not $pins.ContainsKey($k)) { throw "ci-toolchain.pins is missing $k" }
}
$pf86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)

# ---- 1. Visual Studio 2022 Build Tools ---------------------------------------
$vswhere = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
$components = @($pins['VS_COMPONENTS'] -split '\s+' | Where-Object { $_ })
$haveVs = $false
if (Test-Path -LiteralPath $vswhere) {
    $reqArgs = @('-products', '*', '-format', 'json')
    foreach ($c in $components) { $reqArgs += @('-requires', $c) }
    $found = & $vswhere @reqArgs | Out-String | ConvertFrom-Json
    if ($found) { $haveVs = $true; Log "VS Build Tools already carry every component: $($found[0].installationPath)" }
}
if (-not $haveVs) {
    $boot = Join-Path $StageDir 'vs_buildtools.exe'
    if (-not (Test-Path -LiteralPath $boot)) { throw "vs_buildtools.exe not staged in $StageDir" }
    # The evergreen bootstrapper has no stable digest; trust is its Microsoft
    # Authenticode signature, which Windows verifies against its own roots.
    $sig = Get-AuthenticodeSignature -LiteralPath $boot
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "vs_buildtools.exe signature not valid Microsoft: $($sig.Status) $($sig.SignerCertificate.Subject)"
    }
    Log "vs_buildtools.exe signature OK ($($sig.SignerCertificate.Subject))"
    $vsArgs = @('--quiet', '--wait', '--norestart', '--nocache',
        '--installPath', "`"$($pins['VS_INSTALL_PATH'])`"")
    foreach ($c in $components) { $vsArgs += @('--add', $c) }
    $vsArgs += '--includeRecommended'
    Log "installing VS Build Tools: $($vsArgs -join ' ')"
    $p = Start-Process -FilePath $boot -ArgumentList $vsArgs -Wait -PassThru -NoNewWindow
    # 3010 = success, reboot required. The host driver reboots before the gate.
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Get-ChildItem -Path $env:TEMP -Filter 'dd_*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 2 |
            ForEach-Object { Log "---- tail $($_.Name)"; Get-Content $_.FullName -Tail 40 }
        throw "VS Build Tools install failed, exit $($p.ExitCode)"
    }
    Log "VS Build Tools installer exit $($p.ExitCode)"
}

# ---- 2. WinFsp ----------------------------------------------------------------
$winfspDll = Join-Path $pf86 'WinFsp\bin\winfsp-x64.dll'
$winfspHave = $null
# FileVersion carries the build (2.1.25156); ProductVersion is only the year.
if (Test-Path -LiteralPath $winfspDll) { $winfspHave = (Get-Item $winfspDll).VersionInfo.FileVersion }
if ($winfspHave -and $winfspHave -like "*$($pins['WINFSP_VERSION'])*") {
    Log "WinFsp already installed ($winfspHave)"
} else {
    $msi = Join-Path $StageDir "winfsp-$($pins['WINFSP_VERSION']).msi"
    if (-not (Test-Path -LiteralPath $msi)) { throw "WinFsp MSI not staged: $msi" }
    Assert-Sha256 -Path $msi -Expected $pins['WINFSP_MSI_SHA256'] -Label 'WinFsp MSI'
    $p = Start-Process -FilePath msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "WinFsp MSI failed, exit $($p.ExitCode)" }
    Log "WinFsp $($pins['WINFSP_VERSION']) installed (msiexec exit $($p.ExitCode))"
}

# ---- 3. Long paths ------------------------------------------------------------
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled `
    -PropertyType DWord -Value 1 -Force | Out-Null
Log 'LongPathsEnabled=1'
$git = Get-Command git.exe -ErrorAction SilentlyContinue
if ($git) {
    & $git.Source config --system core.longpaths true
    Log "git core.longpaths=true (system config of $($git.Source))"
} else {
    Log 'WARNING: git.exe not on PATH; core.longpaths not set (the Git gate will fail this image)'
}

# ---- 4. Actions runner --------------------------------------------------------
$runnerDir = 'C:\actions-runner'
$listener = Join-Path $runnerDir 'bin\Runner.Listener.exe'
$runnerHave = $null
if (Test-Path -LiteralPath $listener) { $runnerHave = ((& $listener --version) | Out-String).Trim() }
if ($runnerHave -eq $pins['ACTIONS_RUNNER_VERSION']) {
    Log "actions runner already at $runnerHave"
} else {
    $zip = Join-Path $StageDir "actions-runner-win-x64-$($pins['ACTIONS_RUNNER_VERSION']).zip"
    if (-not (Test-Path -LiteralPath $zip)) { throw "runner zip not staged: $zip" }
    Assert-Sha256 -Path $zip -Expected $pins['ACTIONS_RUNNER_SHA256_WIN_X64'] -Label 'actions runner zip'
    Log "re-staging actions runner: '$runnerHave' -> $($pins['ACTIONS_RUNNER_VERSION'])"
    if (Test-Path -LiteralPath $runnerDir) { Remove-Item -LiteralPath $runnerDir -Recurse -Force }
    New-Item -ItemType Directory -Path $runnerDir | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $runnerDir)
}
foreach ($t in '.runner', '.credentials', '.credentials_rsaparams', '.service', '_diag', '_work') {
    $p = Join-Path $runnerDir $t
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force; Log "removed runner state $t" }
}

# ---- 5. Clock -------------------------------------------------------------------
if ($ClockMode -eq 'utc') {
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' -Name RealTimeIsUniversal `
        -PropertyType DWord -Value 1 -Force | Out-Null
    & tzutil.exe /s 'UTC'
    Log "clock: RealTimeIsUniversal=1, time zone $(& tzutil.exe /g)"
} else {
    Log "clock: left as-is (time zone $(& tzutil.exe /g))"
}

# ---- 6. Grow C: -------------------------------------------------------------------
if ($GrowSystemVolume) {
    $max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
    $cur = (Get-Partition -DriveLetter C).Size
    if ($max -gt $cur + 1GB) {
        Resize-Partition -DriveLetter C -Size $max
        Log ("C: grown {0:N1} -> {1:N1} GiB" -f ($cur / 1GB), ($max / 1GB))
    } else {
        Log ("C: not grown (size {0:N1} GiB, supported max {1:N1} GiB; a partition after C: blocks growth)" -f ($cur / 1GB), ($max / 1GB))
    }
}

# ---- cleanup of the staging area is the host driver's job (it owns StageDir) --
Log 'done'
