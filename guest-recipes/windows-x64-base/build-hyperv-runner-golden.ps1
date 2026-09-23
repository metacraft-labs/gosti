<#
.SYNOPSIS
  Reproducibly build the Hyper-V Windows 11 x64 RUNNER golden from pinned
  inputs: one entry point, idempotent, verified before it is published.

.DESCRIPTION
  The golden an ephemeral Hyper-V runner pool clones per job is the product of
  several recipe pieces that were, until now, assembled partly by hand (the
  base install, then pwsh / the actions runner / Defender retrofitted into it).
  This script is the whole pipeline, so a host can rebuild the identical golden
  from nothing but pinned inputs:

    1. verify the Windows ISO against its pinned SHA-256
    2. fetch PortableGit + PowerShell 7 (versions/digests pinned in the
       provision-*.ps1 recipes) and build the autounattend seed ISO
       (--target hyperv) with a first-boot hook that stages the pinned
       actions runner (../lib/stage-actions-runner.ps1)
    3. install unattended via build-golden-hyperv.ps1 (optionally
       -DisableDefender, the ephemeral-pool opt-in)
    4. VERIFY the captured disk offline (runner staged and unregistered,
       Git bash, pwsh) — a golden missing any of them is refused
    5. publish atomically to -OutputVhdx, plus <OutputVhdx>.manifest.json
       recording every input digest

  IDEMPOTENT. The manifest keys the build on the ISO digest, the runner
  pin, the Defender choice, and a digest of every recipe file used — so an
  unchanged pin is a no-op and ANY recipe edit rebuilds. Nothing is replaced
  until the new disk has passed verification (it is built beside the output
  and moved into place last), and a golden that is still the differencing
  parent of a VM is never replaced underneath it.

  Needs an elevated Hyper-V host with network, and Git Bash (for the
  recipe's fetch/ISO shell steps). Wall clock is dominated by Windows setup
  (tens of minutes).

.EXAMPLE
  .\build-hyperv-runner-golden.ps1 -WindowsIso D:\iso\Win11_25H2_x64.iso `
     -WindowsIsoSha256 <sha> -RunnerVersion 2.335.1 -RunnerSha256 <sha> `
     -OutputVhdx D:\storage\golden-win11-hyperv.vhdx -DisableDefender
#>
param(
  [Parameter(Mandatory = $true)][string] $WindowsIso,
  [Parameter(Mandatory = $true)][string] $WindowsIsoSha256,
  [Parameter(Mandatory = $true)][string] $RunnerVersion,
  [Parameter(Mandatory = $true)][string] $RunnerSha256,
  [Parameter(Mandatory = $true)][string] $OutputVhdx,
  [string] $WorkDir = '',
  [string] $SwitchName = 'Default Switch',
  # Distinct from build-golden-hyperv.ps1's default so a hand-kept authoring VM
  # of that name is never removed by a pipeline run.
  [string] $VmName = 'vmh-runner-golden-build',
  [string] $Bash = 'C:\PortableGit\bin\bash.exe',
  [int] $TimeoutMinutes = 120,
  [switch] $DisableDefender,
  [switch] $Force
)
$ErrorActionPreference = 'Stop'
function Log([string]$m) { Write-Host ("[runner-golden] {0:HH:mm:ss} {1}" -f (Get-Date), $m) }

$recipeDir = $PSScriptRoot
$libDir = (Resolve-Path (Join-Path $recipeDir '..\lib')).Path
$manifestPath = "$OutputVhdx.manifest.json"
if (-not $WorkDir) { $WorkDir = Join-Path (Split-Path -Parent $OutputVhdx) '.runner-golden-build' }

# ---- 1. the input digest the manifest is keyed on --------------------------
$recipeFiles = @(
  "$recipeDir\build-hyperv-runner-golden.ps1", "$recipeDir\build-golden-hyperv.ps1",
  "$recipeDir\build-autounattend-iso.sh", "$recipeDir\autounattend.xml", "$recipeDir\make-iso.ps1"
) + @(Get-ChildItem -LiteralPath $libDir -File | Where-Object {
  $_.Name -match '^(provision-|assert-|stage-actions-runner|harden-defender|defender-off|fetch-portable-git|fetch-powershell)'
} | ForEach-Object FullName)
$sha = [Security.Cryptography.SHA256]::Create()
function Get-TextDigest([string]$path) {
  # Hash with line endings normalized (CRLF -> LF): the same commit checked out
  # with and without core.autocrlf must key the same golden, or a checkout
  # detail would trigger an hour-long rebuild.
  $bytes = [IO.File]::ReadAllBytes($path)
  $norm = New-Object System.Collections.Generic.List[byte] $bytes.Length
  for ($i = 0; $i -lt $bytes.Length; $i++) {
    if ($bytes[$i] -eq 13 -and $i + 1 -lt $bytes.Length -and $bytes[$i + 1] -eq 10) { continue }
    $norm.Add($bytes[$i])
  }
  -join ($sha.ComputeHash($norm.ToArray()) | ForEach-Object { $_.ToString('x2') })
}
$recipeLines = foreach ($f in ($recipeFiles | Sort-Object { Split-Path -Leaf $_ })) {
  if (-not (Test-Path -LiteralPath $f)) { throw "recipe file missing: $f" }
  '{0} {1}' -f (Split-Path -Leaf $f), (Get-TextDigest $f)
}
$recipeDigest = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($recipeLines -join "`n"))) |
  ForEach-Object { $_.ToString('x2') })
$want = [ordered]@{
  schema           = 1
  windowsIsoSha256 = $WindowsIsoSha256.ToLowerInvariant()
  runnerVersion    = $RunnerVersion
  runnerSha256     = $RunnerSha256.ToLowerInvariant()
  disableDefender  = [bool]$DisableDefender
  recipeDigest     = $recipeDigest
}
$wantJson = $want | ConvertTo-Json -Compress

if (-not $Force -and (Test-Path -LiteralPath $OutputVhdx) -and (Test-Path -LiteralPath $manifestPath)) {
  $have = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $haveJson = [ordered]@{
    schema = $have.schema; windowsIsoSha256 = $have.windowsIsoSha256
    runnerVersion = $have.runnerVersion; runnerSha256 = $have.runnerSha256
    disableDefender = [bool]$have.disableDefender; recipeDigest = $have.recipeDigest
  } | ConvertTo-Json -Compress
  if ($haveJson -eq $wantJson) { Log "golden up to date ($OutputVhdx)"; exit 0 }
  Log "inputs changed; rebuilding (was $haveJson)"
} else {
  Log "no current manifest for $OutputVhdx; building"
}

# Refuse early rather than after an hour-long build: a golden that is the
# differencing parent of a VM cannot be replaced underneath it.
function Get-GoldenUsers([string]$path) {
  $full = [IO.Path]::GetFullPath($path)
  foreach ($vm in Get-VM) {
    foreach ($d in (Get-VMHardDiskDrive -VMName $vm.Name)) {
      $p = $d.Path
      while ($p) {
        if ([IO.Path]::GetFullPath($p) -ieq $full) { $vm.Name; break }
        $p = try { (Get-VHD -Path $p -ErrorAction Stop).ParentPath } catch { $null }
      }
    }
  }
}
$users = @(Get-GoldenUsers $OutputVhdx | Sort-Object -Unique)
if ($users.Count) { throw "refusing to rebuild: $OutputVhdx is in use by VM(s): $($users -join ', ')" }

# ---- 2. inputs + seed ISO ---------------------------------------------------
if (-not (Test-Path -LiteralPath $WindowsIso)) { throw "Windows ISO not found: $WindowsIso" }
Log "verifying $WindowsIso"
$isoHave = (Get-FileHash -LiteralPath $WindowsIso -Algorithm SHA256).Hash.ToLowerInvariant()
if ($isoHave -ne $want.windowsIsoSha256) {
  throw "Windows ISO SHA-256 mismatch: expected $($want.windowsIsoSha256), got $isoHave"
}
if (-not (Test-Path -LiteralPath $Bash)) { throw "Git Bash not found at $Bash" }

if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
$buildDir = Join-Path $WorkDir 'build'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$firstBoot = Join-Path $WorkDir 'first-boot.ps1'
(Get-Content -LiteralPath (Join-Path $libDir 'stage-actions-runner.ps1') -Raw).
  Replace('__RUNNER_VERSION__', $RunnerVersion).
  Replace('__RUNNER_SHA256__', $want.runnerSha256) |
  Set-Content -LiteralPath $firstBoot -Encoding UTF8

function Bash([string]$script, [string[]]$argv) {
  $env:VMH_BUILD_DIR = $buildDir -replace '\\', '/'
  & $Bash $script @argv
  if ($LASTEXITCODE -ne 0) { throw "$script failed ($LASTEXITCODE)" }
}
$fwd = { param($p) $p -replace '\\', '/' }
Log 'fetching PortableGit + PowerShell 7 (pinned by the provision recipes)'
Bash (& $fwd "$libDir\fetch-portable-git.sh") @('--arch', 'x64', '--output', (& $fwd $buildDir))
Bash (& $fwd "$libDir\fetch-powershell.sh") @('--arch', 'x64', '--output', (& $fwd $buildDir))
Log 'building the autounattend seed ISO (--target hyperv)'
Bash (& $fwd "$recipeDir\build-autounattend-iso.sh") @(
  '--target', 'hyperv', '--first-boot-script', (& $fwd $firstBoot), '--require-portable-git')
$seed = Join-Path $buildDir 'autounattend.iso'
if (-not (Test-Path -LiteralPath $seed)) { throw "seed ISO not produced at $seed" }

# ---- 3. unattended install --------------------------------------------------
$tmp = "$OutputVhdx.building.vhdx"
if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
$gArgs = @{
  WindowsIso = $WindowsIso; AutounattendIso = $seed; VmName = $VmName
  OutputVhdx = $tmp; SwitchName = $SwitchName; TimeoutMinutes = $TimeoutMinutes
}
if ($DisableDefender) { $gArgs.DisableDefender = $true }
& (Join-Path $recipeDir 'build-golden-hyperv.ps1') @gArgs
if (-not (Test-Path -LiteralPath $tmp)) { throw "build-golden-hyperv.ps1 produced no disk at $tmp" }

# ---- 4. offline verification ------------------------------------------------
Log "verifying the captured disk offline"
$problems = @()
Mount-VHD -Path $tmp -ReadOnly
try {
  $disk = Get-VHD -Path $tmp | Get-Disk
  $win = Get-Partition -DiskNumber $disk.Number | Get-Volume |
    Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\Windows\System32\ntoskrnl.exe") } |
    Select-Object -First 1
  if (-not $win) {
    # Read-only mounts may not auto-assign letters; give the largest partition one.
    $part = Get-Partition -DiskNumber $disk.Number | Sort-Object Size -Descending | Select-Object -First 1
    $part | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
    $win = $part | Get-Volume
  }
  $r = "$($win.DriveLetter):"
  foreach ($must in 'actions-runner\config.cmd', 'actions-runner\run.cmd',
                    'actions-runner\bin\Runner.Listener.exe', 'actions-runner\.vmh-staged',
                    'PortableGit\bin\bash.exe', 'pwsh\pwsh.exe') {
    if (-not (Test-Path -LiteralPath "$r\$must")) { $problems += "missing $must" }
  }
  foreach ($mustNot in 'actions-runner\.runner', 'actions-runner\.credentials') {
    if (Test-Path -LiteralPath "$r\$mustNot") { $problems += "golden carries registration state: $mustNot" }
  }
  foreach ($failed in 'vmh-runner-stage-failed', 'vmh-git-provision-failed', 'vmh-pwsh-provision-failed') {
    $f = "$r\Windows\Temp\$failed"
    if (Test-Path -LiteralPath $f) { $problems += "${failed}: $((Get-Content -LiteralPath $f -Raw).Trim())" }
  }
  $staged = if (Test-Path "$r\actions-runner\.vmh-staged") { (Get-Content "$r\actions-runner\.vmh-staged" -Raw).Trim() } else { '' }
  if ($staged -and $staged -ne $RunnerVersion) { $problems += "staged runner $staged != pinned $RunnerVersion" }
} finally {
  Dismount-VHD -Path $tmp
}
if ($problems.Count) {
  throw "refusing to publish the golden ($tmp kept for inspection):`n  " + ($problems -join "`n  ")
}

# ---- 5. publish -------------------------------------------------------------
$users = @(Get-GoldenUsers $OutputVhdx | Sort-Object -Unique)
if ($users.Count) { throw "refusing to publish: $OutputVhdx came into use by VM(s): $($users -join ', ') ($tmp kept)" }
if (Test-Path -LiteralPath $OutputVhdx) {
  Move-Item -LiteralPath $OutputVhdx -Destination "$OutputVhdx.prev" -Force
}
Move-Item -LiteralPath $tmp -Destination $OutputVhdx
$want.builtAt = (Get-Date).ToUniversalTime().ToString('o')
$want.recipeFiles = $recipeLines
$want | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
if (Test-Path -LiteralPath "$OutputVhdx.prev") { Remove-Item -LiteralPath "$OutputVhdx.prev" -Force }
Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
Log "published $OutputVhdx ($([math]::Round((Get-Item $OutputVhdx).Length/1GB,1)) GB) + manifest"
