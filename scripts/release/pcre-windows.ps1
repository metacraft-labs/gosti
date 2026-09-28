# SPDX-FileCopyrightText: 2026 Metacraft Labs
# SPDX-License-Identifier: Apache-2.0
# Nim std/re loads pcre64.dll by name on both 64-bit Windows architectures.
# Build the declared PCRE 8 sources with the same target compiler as gosti.
# The source list/configuration follows upstream NON-AUTOTOOLS-BUILD §5.
param([Parameter(Mandatory = $true)][string]$Stage)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$source = (Get-Content -Raw .github/release.json | ConvertFrom-Json).runtimeSources.pcre
$dir = Join-Path (Get-Location) 'build/release-pcre'
New-Item -ItemType Directory -Force $dir | Out-Null
$archive = Join-Path $dir 'pcre.tar.bz2'
Invoke-WebRequest $source.url -OutFile $archive
if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $source.sha256) {
  throw 'PCRE source checksum mismatch'
}
& "$env:SystemRoot/System32/tar.exe" -xf $archive -C $dir
if ($LASTEXITCODE -ne 0) { throw 'PCRE source extraction failed' }
$root = Join-Path $dir 'pcre-8.45'
Copy-Item "$root/config.h.generic" "$root/config.h" -Force
Copy-Item "$root/pcre.h.generic" "$root/pcre.h" -Force
Copy-Item "$root/pcre_chartables.c.dist" "$root/pcre_chartables.c" -Force
$names = @('byte_order','chartables','compile','config','dfa_exec','exec','fullinfo',
  'get','globals','jit_compile','maketables','newline','ord2utf8','refcount',
  'string_utils','study','tables','ucd','valid_utf8','version','xclass')
$files = @($names | ForEach-Object { Join-Path $root "pcre_$_.c" })
& $env:RELEASE_CC -shared -O2 -DHAVE_CONFIG_H -DPCRE_BUILD -DSUPPORT_PCRE8 `
  -DSUPPORT_UTF -DSUPPORT_UCP -DHAVE_MEMMOVE -DHAVE_STDLIB_H -DHAVE_STRING_H `
  "-I$root" @files -o "$Stage/bin/pcre64.dll"
if ($LASTEXITCODE -ne 0) { throw 'PCRE target DLL compilation failed' }
New-Item -ItemType Directory -Force "$Stage/share/licenses/pcre" | Out-Null
Copy-Item "$root/LICENCE" "$Stage/share/licenses/pcre/"
