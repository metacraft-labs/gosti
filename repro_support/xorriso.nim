# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Real config-drive ISO construction, also provided by the native shell.
import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package xorriso:
  provisioning:
    nixPackage "nixpkgs#xorriso", executablePath = "bin/xorriso",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
