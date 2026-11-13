# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
# assert-vs-buildtools.ps1 -- HARD GATE: refuse to let a Windows golden be
# captured unless MSVC is actually usable on every clone of it.
#
# WHY THIS EXISTS. The Windows-ARM golden shipped without any Visual Studio
# Build Tools, and nothing noticed until CI did: every MSVC cargo link on the
# eph-win-arm64 runners failed with "error: linker `link.exe` not found", and
# reprobuild reported "MSVC dev-env activation skipped: vswhere.exe not
# found". provision-vs-buildtools.ps1 now installs them, but in the ARM
# recipe it runs from FirstLogonCommands and exits 0 even when it fails (a
# non-zero exit there can wedge the install-done sentinel). That is safe only
# if something refuses to capture the resulting image. This script is that
# refusal; the headless ARM golden build runs it over SSH before sysprep and
# fails the build when it exits non-zero.
#
# WHAT IT ASSERTS, each one a thing a CI job actually depends on:
#   1. No failure marker from provision-vs-buildtools.ps1.
#   2. vswhere.exe exists at the fixed location every consumer probes
#      (<ProgramFiles(x86)>\Microsoft Visual Studio\Installer\vswhere.exe).
#   3. `vswhere -products * -requires <each VS_COMPONENTS id>` finds an
#      installation -- the exact query agent-harbor's workflow and infra's
#      persistent runner run -- and it is at the pinned install path.
#   4. For each VS_REQUIRED_TARGETS target (x64, arm64): the default MSVC
#      toolset has link.exe AND cl.exe for that target under at least one
#      host directory, plus the CRT import libraries. "The component is
#      registered" and "the linker is on disk" are different facts; the
#      original failure was literally a missing link.exe.
#   5. The pinned Windows SDK carries windows.h and the kernel32/ucrt import
#      libraries for each target.
# The installed product version is REPORTED, not enforced: the bootstrapper is
# the fixed-version one, so a mismatch is worth seeing, but the property CI
# needs is the components, not the patch level.
#
# Exit codes: 0 = image is fit to capture. 1 = do not capture it.
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File assert-vs-buildtools.ps1

[CmdletBinding()]
param(
    [string]$PinsPath = '',
    [string]$FailureMarker = 'C:\Windows\Temp\gosti-vs-buildtools-provision-failed',
    [string]$LogPath = 'C:\Windows\Temp\gosti-vs-buildtools-provision.log'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$problems = New-Object System.Collections.Generic.List[string]
function Bad([string]$m) { $problems.Add($m); Write-Host "  [FAIL] $m" }
function Good([string]$m) { Write-Host "  [ ok ] $m" }

if (-not $PinsPath) { $PinsPath = Join-Path $PSScriptRoot 'vs-buildtools.pins' }
$pins = @{}
if (Test-Path -LiteralPath $PinsPath) {
    foreach ($raw in Get-Content -LiteralPath $PinsPath) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -le 0) { continue }
        $pins[$line.Substring(0, $eq).Trim()] = $line.Substring($eq + 1).Trim()
    }
}
foreach ($k in 'VS_INSTALL_PATH', 'VS_COMPONENTS', 'WINDOWS_SDK_VERSION', 'VS_REQUIRED_TARGETS') {
    if (-not $pins.ContainsKey($k)) {
        Write-Host "assert-vs-buildtools: $PinsPath is missing $k"
        exit 1
    }
}
$components = @($pins['VS_COMPONENTS'] -split '\s+' | Where-Object { $_ })
$targets = @($pins['VS_REQUIRED_TARGETS'] -split '\s+' | Where-Object { $_ })

Write-Host "assert-vs-buildtools: checking MSVC for targets $($targets -join ', ')"

# 1. Provisioning did not record a failure.
if (Test-Path -LiteralPath $FailureMarker) {
    Bad "provision-vs-buildtools.ps1 left $FailureMarker : $((Get-Content -LiteralPath $FailureMarker -Raw).Trim())"
    if (Test-Path -LiteralPath $LogPath) {
        Write-Host "  ---- tail $LogPath"
        Get-Content -LiteralPath $LogPath -Tail 40 | ForEach-Object { Write-Host "  $_" }
    }
} else { Good 'no provisioning failure marker' }

# 2-3. vswhere, and the installation carrying every component.
$pf86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
$vswhere = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = $null
if (Test-Path -LiteralPath $vswhere) {
    Good "vswhere.exe present: $vswhere"
    $q = @('-products', '*', '-format', 'json')
    foreach ($c in $components) { $q += @('-requires', $c) }
    $vs = & $vswhere @q | Out-String | ConvertFrom-Json | Select-Object -First 1
    if ($vs) {
        Good "vswhere: $($vs.displayName) $($vs.installationVersion) at $($vs.installationPath) carries every component"
        if ($pins.ContainsKey('VS_BUILDTOOLS_VERSION') -and $vs.installationVersion -ne $pins['VS_BUILDTOOLS_VERSION']) {
            Write-Host "  [note] installed $($vs.installationVersion), pin names $($pins['VS_BUILDTOOLS_VERSION'])"
        }
        if ($vs.installationPath.TrimEnd('\') -ne $pins['VS_INSTALL_PATH'].TrimEnd('\')) {
            Bad "installation is at $($vs.installationPath), not the pinned $($pins['VS_INSTALL_PATH'])"
        }
    } else {
        Bad "vswhere finds no installation carrying: $($components -join ' ')"
        # Say which component is missing, not just that one is.
        foreach ($c in $components) {
            $one = & $vswhere -products * -format json -requires $c | Out-String | ConvertFrom-Json
            if (-not $one) { Bad "  no installation carries $c" }
        }
    }
} else { Bad "vswhere.exe missing ($vswhere): VS Build Tools are not installed" }

# 4. The MSVC toolset really has a linker, a compiler and the CRT per target.
if ($vs) {
    $verFile = Join-Path $vs.installationPath 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
    if (Test-Path -LiteralPath $verFile) {
        $vc = (Get-Content -LiteralPath $verFile | Select-Object -First 1).Trim()
        $vcRoot = Join-Path $vs.installationPath "VC\Tools\MSVC\$vc"
        Good "default MSVC toolset $vc"
        $hosts = @(Get-ChildItem -LiteralPath (Join-Path $vcRoot 'bin') -Directory -Filter 'Host*' -ErrorAction SilentlyContinue)
        Write-Host "  host directories: $(($hosts | ForEach-Object { $_.Name }) -join ', ')"
        foreach ($t in $targets) {
            $linkers = @($hosts | ForEach-Object { Join-Path $_.FullName "$t\link.exe" } | Where-Object { Test-Path -LiteralPath $_ })
            $compilers = @($hosts | ForEach-Object { Join-Path $_.FullName "$t\cl.exe" } | Where-Object { Test-Path -LiteralPath $_ })
            if ($linkers.Count -gt 0) { Good "MSVC $t link.exe: $($linkers -join '; ')" } else { Bad "MSVC $vc has no link.exe for target $t under any $vcRoot\bin\Host*" }
            if ($compilers.Count -gt 0) { Good "MSVC $t cl.exe: $($compilers -join '; ')" } else { Bad "MSVC $vc has no cl.exe for target $t" }
            foreach ($lib in 'msvcrt.lib', 'vcruntime.lib') {
                $p = Join-Path $vcRoot "lib\$t\$lib"
                if (Test-Path -LiteralPath $p) { Good "MSVC lib\$t\$lib" } else { Bad "MSVC lib\$t\$lib missing ($p)" }
            }
        }
    } else { Bad "no $verFile" }
}

# 5. Windows SDK headers and import libraries per target.
$sdk = $pins['WINDOWS_SDK_VERSION']
$kits = Join-Path $pf86 'Windows Kits\10'
$sdkFiles = @("Include\$sdk\um\windows.h", "Include\$sdk\ucrt\stdio.h")
foreach ($t in $targets) { $sdkFiles += @("Lib\$sdk\um\$t\kernel32.lib", "Lib\$sdk\ucrt\$t\ucrt.lib") }
foreach ($rel in $sdkFiles) {
    $p = Join-Path $kits $rel
    if (Test-Path -LiteralPath $p) { Good "Windows SDK $rel" } else { Bad "Windows SDK missing $p" }
}

if ($problems.Count -gt 0) {
    Write-Host "assert-vs-buildtools: $($problems.Count) problem(s)."
    Write-Host 'DO NOT capture this image. Clones of it will run GitHub Actions jobs, and'
    Write-Host 'every MSVC link there fails with "linker `link.exe` not found". Re-run'
    Write-Host 'guest-recipes/lib/provision-vs-buildtools.ps1 in the guest (elevated) and'
    Write-Host 'inspect C:\Windows\Temp\gosti-vs-buildtools-provision.log.'
    exit 1
}
Write-Host 'assert-vs-buildtools: OK -- MSVC links and compiles for every required'
Write-Host 'target and the SDK is present. This image is fit to capture.'
exit 0
