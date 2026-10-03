# SPDX-FileCopyrightText: 2026 Metacraft Labs
# SPDX-License-Identifier: Apache-2.0
param([Parameter(Mandatory = $true)][string]$Target)
. "$env:RELEASE_TOOLS/common.ps1"
Invoke-ReleaseNim 'src/vm_harness/cli.nim' 'build/gosti-release.exe'
& ./scripts/install-binaries.ps1 -BuiltCli 'build/gosti-release.exe' -BinDir "$ReleaseStage/bin"
& ./scripts/release/pcre-windows.ps1 -Stage $ReleaseStage
New-Item -ItemType Directory -Force "$ReleaseStage/share/vm-harness" | Out-Null
Copy-Item -Recurse guest-scripts, guest-recipes "$ReleaseStage/share/vm-harness/"
Copy-Item LICENSE, NOTICE $ReleaseStage
Complete-Release
