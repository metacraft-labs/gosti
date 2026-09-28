# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
  Go/no-go gate for the CI toolchain layer of the Windows x64 golden.

.DESCRIPTION
  Exit 0 = every property a CI job depends on holds; exit 1 = do not capture /
  do not promote. Runs in the work guest before capture AND on a fresh CoW
  clone of the captured image (build-ci-toolchain-golden.sh does both).

  Each check asserts that the expected thing is POSITIVELY present, never
  merely that a bad thing is absent: a probe that matches nothing must fail.

.PARAMETER StageDir
  Directory holding ci-toolchain.pins.

.PARAMETER ClockMode
  utc | keep, as given to provision-ci-toolchain.ps1.

.PARAMETER ExpectLogicalProcessors
  When > 0, assert Windows sees exactly this many logical processors (the
  host driver passes the vCPU count it booted the domain with, proving the
  1-socket x N-core topology; Windows 11 Pro uses at most 2 sockets).

.PARAMETER ExpectDefenderOff
  Assert the antivirus services are disabled (after the offline hardening).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StageDir,
    [ValidateSet('utc', 'keep')][string]$ClockMode = 'utc',
    [int]$ExpectLogicalProcessors = 0,
    [switch]$ExpectDefenderOff
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$failures = New-Object System.Collections.Generic.List[string]
function Ok   { param($m) Write-Host "  ok    $m" }
function Bad  { param($m) Write-Host "  FAIL  $m"; $script:failures.Add($m) }

$pins = @{}
foreach ($raw in Get-Content -LiteralPath (Join-Path $StageDir 'ci-toolchain.pins')) {
    $line = $raw.Trim()
    if (-not $line -or $line.StartsWith('#')) { continue }
    $eq = $line.IndexOf('=')
    if ($eq -gt 0) { $pins[$line.Substring(0, $eq).Trim()] = $line.Substring($eq + 1).Trim() }
}
$pf86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)

# -- Visual Studio: the exact query agent-harbor's workflow step runs ----------
$vswhere = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsInstaller = Join-Path $pf86 'Microsoft Visual Studio\Installer\vs_installer.exe'
if (Test-Path -LiteralPath $vsInstaller) { Ok "vs_installer.exe present" } else { Bad "vs_installer.exe missing ($vsInstaller)" }
$vs = $null
if (Test-Path -LiteralPath $vswhere) {
    $q = @('-products', '*', '-format', 'json')
    foreach ($c in @($pins['VS_COMPONENTS'] -split '\s+' | Where-Object { $_ })) { $q += @('-requires', $c) }
    $vs = & $vswhere @q | Out-String | ConvertFrom-Json | Select-Object -First 1
}
if ($vs) { Ok "vswhere: $($vs.displayName) $($vs.installationVersion) at $($vs.installationPath) carries every VS_COMPONENTS id" }
else { Bad "vswhere finds no installation carrying: $($pins['VS_COMPONENTS'])" }

if ($vs) {
    $verFile = Join-Path $vs.installationPath 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
    if (Test-Path -LiteralPath $verFile) {
        $vc = (Get-Content -LiteralPath $verFile | Select-Object -First 1).Trim()
        $vcRoot = Join-Path $vs.installationPath "VC\Tools\MSVC\$vc"
        foreach ($exe in 'cl.exe', 'link.exe', 'lib.exe') {
            $p = Join-Path $vcRoot "bin\Hostx64\x64\$exe"
            if (Test-Path -LiteralPath $p) { Ok "MSVC $vc $exe" } else { Bad "MSVC $vc has no $p" }
        }
        foreach ($lib in 'msvcrt.lib', 'vcruntime.lib') {
            if (Test-Path -LiteralPath (Join-Path $vcRoot "lib\x64\$lib")) { Ok "MSVC lib\x64\$lib" } else { Bad "MSVC lib\x64\$lib missing" }
        }
    } else { Bad "no $verFile" }
}

# -- Windows SDK ---------------------------------------------------------------
$sdk = $pins['WINDOWS_SDK_VERSION']
$kits = Join-Path $pf86 'Windows Kits\10'
foreach ($rel in "Include\$sdk\um\windows.h", "Include\$sdk\ucrt\stdio.h", "Lib\$sdk\um\x64\kernel32.lib", "Lib\$sdk\ucrt\x64\ucrt.lib", "bin\$sdk\x64\rc.exe") {
    $p = Join-Path $kits $rel
    if (Test-Path -LiteralPath $p) { Ok "Windows SDK $rel" } else { Bad "Windows SDK missing $p" }
}

# -- WinFsp --------------------------------------------------------------------
# The RUNTIME half only: the kernel driver, its user-mode DLL and the launcher.
# The MSI's default feature set omits the developer files (inc\, lib\), and
# consumers such as winfsp-rs's winfsp-sys vendor their own headers and import
# libraries unless built with its `system` feature, so they are not required.
$wf = Join-Path $pf86 'WinFsp'
foreach ($rel in 'bin\winfsp-x64.dll', 'bin\winfsp-x64.sys', 'bin\launcher-x64.exe', 'bin\launchctl-x64.exe') {
    if (Test-Path -LiteralPath (Join-Path $wf $rel)) { Ok "WinFsp $rel" } else { Bad "WinFsp missing $rel" }
}
$dllVer = $null
if (Test-Path -LiteralPath (Join-Path $wf 'bin\winfsp-x64.dll')) {
    # FileVersion carries the build (e.g. 2.1.25156); ProductVersion is the
    # marketing year ("2025") and cannot tell releases apart.
    $dllVer = (Get-Item (Join-Path $wf 'bin\winfsp-x64.dll')).VersionInfo.FileVersion
}
if ($dllVer -and $dllVer -like "*$($pins['WINFSP_VERSION'])*") { Ok "WinFsp version $dllVer" } else { Bad "WinFsp FileVersion '$dllVer' is not $($pins['WINFSP_VERSION'])" }
$svc = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
if ($svc) { Ok "WinFsp.Launcher service ($($svc.Status), $($svc.StartType))" } else { Bad 'WinFsp.Launcher service missing' }

# -- Long paths ----------------------------------------------------------------
$lp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
if ($lp -eq 1) { Ok 'LongPathsEnabled=1' } else { Bad "LongPathsEnabled='$lp'" }
$git = Get-Command git.exe -ErrorAction SilentlyContinue
if ($git) {
    $cl = ((& $git.Source config --system --get core.longpaths) | Out-String).Trim()
    if ($cl -eq 'true') { Ok 'git core.longpaths=true (system)' } else { Bad "git core.longpaths='$cl'" }
} else { Bad 'git.exe not on PATH' }

# -- Actions runner ------------------------------------------------------------
$listener = 'C:\actions-runner\bin\Runner.Listener.exe'
if (Test-Path -LiteralPath $listener) {
    $rv = ((& $listener --version) | Out-String).Trim()
    if ($rv -eq $pins['ACTIONS_RUNNER_VERSION']) { Ok "actions runner $rv" } else { Bad "actions runner '$rv' is not $($pins['ACTIONS_RUNNER_VERSION'])" }
} else { Bad "no $listener" }
foreach ($t in '.runner', '.credentials') {
    if (Test-Path -LiteralPath (Join-Path 'C:\actions-runner' $t)) { Bad "runner state $t present (a golden must ship a clean runner dir)" }
}

# -- Clock ---------------------------------------------------------------------
if ($ClockMode -eq 'utc') {
    $rtu = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' -Name RealTimeIsUniversal -ErrorAction SilentlyContinue).RealTimeIsUniversal
    if ($rtu -eq 1) { Ok 'RealTimeIsUniversal=1' } else { Bad "RealTimeIsUniversal='$rtu'" }
    $tz = (& tzutil.exe /g)
    if ($tz -eq 'UTC') { Ok 'time zone UTC' } else { Bad "time zone '$tz'" }
}
Write-Host ("  info  guest UTC now {0:yyyy-MM-ddTHH:mm:ssZ}" -f [DateTime]::UtcNow)

# -- CPU topology --------------------------------------------------------------
$cs = Get-CimInstance Win32_ComputerSystem
$lps = [int]$cs.NumberOfLogicalProcessors
Write-Host "  info  sockets=$($cs.NumberOfProcessors) logical processors=$lps"
if ($ExpectLogicalProcessors -gt 0) {
    if ($lps -eq $ExpectLogicalProcessors) { Ok "Windows uses all $lps vCPUs" } else { Bad "Windows sees $lps logical processors, expected $ExpectLogicalProcessors" }
}

# -- Antivirus -----------------------------------------------------------------
if ($ExpectDefenderOff) {
    foreach ($name in 'WinDefend', 'WdFilter') {
        $s = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Stopped' -and "$($s.StartType)" -eq 'Disabled') { Ok "$name Stopped/Disabled" }
        elseif (-not $s) { Bad "$name service not found (cannot prove it is off)" }
        else { Bad "$name is $($s.Status)/$($s.StartType)" }
    }
}

# -- Disk ------------------------------------------------------------------------
$c = Get-PSDrive -Name C
Write-Host ("  info  C: {0:N1} GiB free of {1:N1} GiB" -f ($c.Free / 1GB), (($c.Free + $c.Used) / 1GB))
if ($c.Free -lt 30GB) { Bad ("C: has only {0:N1} GiB free" -f ($c.Free / 1GB)) }

if ($failures.Count -gt 0) {
    Write-Host "CI toolchain gate: $($failures.Count) failure(s)"
    exit 1
}
Write-Host 'CI toolchain gate: PASS'
exit 0
