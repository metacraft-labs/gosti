# SPDX-FileCopyrightText: 2026 Metacraft Labs
# SPDX-License-Identifier: Apache-2.0
# Windows command layout, shared by the release builder and command tests.
# Ordinary Windows accounts can install both names without symlink privileges.
param(
  [Parameter(Mandatory = $true)][string]$BuiltCli,
  [Parameter(Mandatory = $true)][string]$BinDir
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Force $BinDir | Out-Null
Copy-Item -LiteralPath $BuiltCli -Destination (Join-Path $BinDir 'gosti.exe') -Force
Copy-Item -LiteralPath $BuiltCli -Destination (Join-Path $BinDir 'vm-harness.exe') -Force
