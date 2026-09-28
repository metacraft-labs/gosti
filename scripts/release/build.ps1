# SPDX-FileCopyrightText: 2026 Metacraft Labs
# SPDX-License-Identifier: Apache-2.0
param([Parameter(Mandatory = $true)][string]$Target)
. "$env:RELEASE_TOOLS/common.ps1"
Invoke-ReleaseNim 'src/vm_harness/cli.nim' "$ReleaseStage/bin/gosti.exe"
# Windows installs use a byte-identical compatibility executable, avoiding
# symlink privileges and ZIP extraction differences on ordinary accounts.
Copy-Item "$ReleaseStage/bin/gosti.exe" "$ReleaseStage/bin/vm-harness.exe"
New-Item -ItemType Directory -Force "$ReleaseStage/share/vm-harness" | Out-Null
Copy-Item -Recurse guest-scripts, guest-recipes "$ReleaseStage/share/vm-harness/"
Copy-Item LICENSE, NOTICE $ReleaseStage
Complete-Release
