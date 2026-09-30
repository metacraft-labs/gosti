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

.PARAMETER ExpectBackgroundServicesOff
  First start every task in ci-background-off.trigger-tasks (the scheduled
  tasks that can re-enable Windows Update) and wait 90 s. Then assert every
  service in ci-background-off.targets (Windows Update, its orchestrator and
  Medic, Delivery Optimization, Windows Search, the Store Install Service) is
  present, Disabled and Stopped, that the automatic-update policy is off, and that none
  of their worker processes is running. Only meaningful after the offline
  payload, i.e. on the clone.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StageDir,
    [ValidateSet('utc', 'keep')][string]$ClockMode = 'utc',
    [int]$ExpectLogicalProcessors = 0,
    [switch]$ExpectDefenderOff,
    [switch]$ExpectBackgroundServicesOff
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

# -- Debugging Tools for Windows (cdb.exe) --------------------------------------
# The exact location reprobuild's HCR drivers probe (find_cdb in
# tests/windows/hx_w6_*.py): <ProgramFiles(x86)>\Windows Kits\10\Debuggers\x64.
# Present is not enough: it must be the x64 image, Microsoft-signed, and run.
$cdb = Join-Path $kits 'Debuggers\x64\cdb.exe'
if (Test-Path -LiteralPath $cdb) {
    $fs = [System.IO.File]::OpenRead($cdb)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Position = 0x3C; $pe = $br.ReadInt32()
        $fs.Position = $pe + 4; $machine = $br.ReadUInt16()
    } finally { $fs.Dispose() }
    if ($machine -eq 0x8664) { Ok 'cdb.exe is an x64 image' } else { Bad ("cdb.exe machine type 0x{0:X4}, expected 0x8664 (x64)" -f $machine) }
    $sig = Get-AuthenticodeSignature -LiteralPath $cdb
    if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'O=Microsoft Corporation') { Ok 'cdb.exe Microsoft signature valid' }
    else { Bad "cdb.exe signature: $($sig.Status) $($sig.SignerCertificate.Subject)" }
    $cv = ((& $cdb -version 2>&1) | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $cv -match 'cdb version\s+(\S+)') { Ok "cdb.exe runs: cdb version $($Matches[1]) (FileVersion $((Get-Item $cdb).VersionInfo.FileVersion))" }
    else { Bad "cdb.exe -version failed (exit $LASTEXITCODE): $cv" }
} else { Bad "Debugging Tools for Windows missing: no $cdb" }

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

# -- Background services (Windows Update, Windows Search) ------------------------
if ($ExpectBackgroundServicesOff) {
    $targets = @(Get-Content -LiteralPath (Join-Path $StageDir 'ci-background-off.targets') |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($targets.Count -eq 0) { Bad 'ci-background-off.targets lists no services' }
    # Start every task known to re-enable Windows Update BEFORE checking, so
    # the check sees the state a job sees after those tasks have fired, not
    # the state of a freshly booted clone (they fire minutes after boot, on
    # wall-clock triggers). A task that refuses an on-demand start is
    # reported, not failed: it cannot run in a job that way either.
    $triggerFile = Join-Path $StageDir 'ci-background-off.trigger-tasks'
    $triggers = @()
    if (Test-Path -LiteralPath $triggerFile) {
        $triggers = @(Get-Content -LiteralPath $triggerFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    }
    if ($triggers.Count -eq 0) { Bad "no tasks to trigger ($triggerFile missing or empty)" }
    $started = 0
    foreach ($t in $triggers) {
        $cut = $t.LastIndexOf('\')
        $tp = $t.Substring(0, $cut + 1); $tn = $t.Substring($cut + 1)
        if (-not (Get-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction SilentlyContinue)) { Write-Host "  info  task $t not present"; continue }
        try { Start-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction Stop; $started++; Write-Host "  info  started $t" }
        catch { Write-Host "  info  $t refused an on-demand start: $($_.Exception.Message.Trim())" }
    }
    if ($triggers.Count -gt 0 -and $started -eq 0) { Bad 'none of the trigger tasks could be started, so the check below proves nothing' }
    # InstallService\ScanForUpdates flipped wuauserv within 75 s when it was
    # not disabled (2026-09-30); wait longer than that.
    Start-Sleep -Seconds 90
    foreach ($t in $triggers) {
        $cut = $t.LastIndexOf('\')
        $i = Get-ScheduledTaskInfo -TaskPath $t.Substring(0, $cut + 1) -TaskName $t.Substring($cut + 1) -ErrorAction SilentlyContinue
        if ($i) { Write-Host ("  info  {0} last result 0x{1:X}" -f $t, $i.LastTaskResult) }
    }
    foreach ($name in $targets) {
        # Read Start from the registry as well as the SCM. The registry value is
        # what the offline payload wrote, and the SCM view proves Windows
        # honoured it at boot.
        $start = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -Name Start -ErrorAction SilentlyContinue).Start
        $s = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $s) { Bad "$name service not found (cannot prove it is off)" }
        elseif ($s.Status -eq 'Stopped' -and "$($s.StartType)" -eq 'Disabled' -and $start -eq 4) { Ok "$name Stopped/Disabled" }
        else { Bad "$name is $($s.Status)/$($s.StartType) (Start=$start)" }
    }
    $au = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -ErrorAction SilentlyContinue).NoAutoUpdate
    if ($au -eq 1) { Ok 'policy WindowsUpdate\AU NoAutoUpdate=1' } else { Bad "policy WindowsUpdate\AU NoAutoUpdate='$au'" }
    # The worker processes of the disabled services. TiWorker is not listed:
    # it belongs to TrustedInstaller, which stays enabled because installing
    # Windows features needs it.
    foreach ($proc in 'wuaucltcore', 'MoUsoCoreWorker', 'SearchIndexer') {
        $running = @(Get-Process -Name $proc -ErrorAction SilentlyContinue)
        if ($running.Count -eq 0) { Ok "$proc not running" } else { Bad "$proc is running (pid $($running.Id -join ','))" }
    }
    # Informational: the scheduled tasks that would start them. With the
    # services disabled these tasks cannot do any work, so the gate does not
    # require them disabled. Several of them refuse a change even from SYSTEM.
    foreach ($path in '\Microsoft\Windows\UpdateOrchestrator\', '\Microsoft\Windows\WindowsUpdate\') {
        $tasks = @(Get-ScheduledTask -TaskPath $path -ErrorAction SilentlyContinue)
        $ready = @($tasks | Where-Object { $_.State -ne 'Disabled' })
        Write-Host "  info  $path $($tasks.Count) task(s), $($ready.Count) not disabled (inert: their services are disabled)"
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
