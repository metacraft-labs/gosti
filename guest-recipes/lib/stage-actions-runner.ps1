<#
.SYNOPSIS
  Stage (NOT configure) the GitHub Actions runner into a Windows golden.

.DESCRIPTION
  Downloads the pinned actions-runner release, verifies its SHA-256, and
  extracts it to C:\actions-runner with NO registration state (.runner,
  .credentials, _diag). A clone of the golden then only needs
  `config.cmd --jitconfig ...` / `run.cmd` — no per-job download — whether the
  runner is started by an orchestrator's bootstrap or by hand.

  Designed to run as the autounattend `first-boot.ps1` hook (FirstLogonCommands,
  as the local admin, after the network-wait step). That hook passes no
  arguments, so the build orchestrator (build-hyperv-runner-golden.ps1)
  substitutes the __RUNNER_*__ placeholders below with the pinned values when it
  generates first-boot.ps1. Run standalone by passing -Version/-Sha256.

  Failure never aborts the FirstLogonCommands chain (the golden must still
  finish and shut down): it leaves C:\Windows\Temp\vmh-runner-stage-failed and
  exits 0, and the orchestrator's post-build verification refuses to capture a
  golden without the runner. This mirrors provision-git.ps1 / provision-pwsh.ps1.
#>
param(
  [string] $Version = '__RUNNER_VERSION__',
  [string] $Sha256 = '__RUNNER_SHA256__',
  [string] $InstallDir = 'C:\actions-runner'
)

$log = 'C:\Windows\Temp\vmh-runner-stage.log'
$failMarker = 'C:\Windows\Temp\vmh-runner-stage-failed'
function Log([string]$m) { Add-Content -LiteralPath $log -Value ("{0:o} {1}" -f (Get-Date), $m) }

try {
  $ErrorActionPreference = 'Stop'
  if ($Version -like '__*__' -or $Sha256 -like '__*__') {
    throw 'stage-actions-runner: -Version/-Sha256 not provided (placeholders not substituted)'
  }
  $Sha256 = $Sha256.ToLowerInvariant()
  $name = "actions-runner-win-x64-$Version.zip"
  $url = "https://github.com/actions/runner/releases/download/v$Version/$name"
  $zip = Join-Path $env:TEMP $name
  Log "downloading $url"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $ProgressPreference = 'SilentlyContinue'
  $attempt = 0
  while ($true) {
    try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing; break }
    catch {
      $attempt++
      if ($attempt -ge 5) { throw }
      Log "download attempt $attempt failed: $($_.Exception.Message); retrying"
      Start-Sleep -Seconds (10 * $attempt)
    }
  }
  $have = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($have -ne $Sha256) { throw "SHA-256 mismatch for ${name}: expected $Sha256, got $have" }

  if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  Expand-Archive -LiteralPath $zip -DestinationPath $InstallDir -Force
  Remove-Item -LiteralPath $zip -Force

  # A golden must carry NO registration: every clone registers itself.
  foreach ($t in '.runner', '.credentials', '.credentials_rsaparams', '.service', '_diag') {
    $p = Join-Path $InstallDir $t
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
  }
  foreach ($must in 'config.cmd', 'run.cmd', 'bin\Runner.Listener.exe') {
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir $must))) {
      throw "staged runner is missing $must"
    }
  }
  Set-Content -LiteralPath (Join-Path $InstallDir '.vmh-staged') -Value $Version -Encoding ASCII
  Log "staged actions-runner $Version at $InstallDir"
}
catch {
  Log "FAILED: $($_.Exception.Message)"
  Set-Content -LiteralPath $failMarker -Value $_.Exception.Message -Encoding UTF8 -Force
}
exit 0
