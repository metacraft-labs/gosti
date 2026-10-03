# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Real software TPM for the Linux guest integration test.
import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package swtpm:
  provisioning:
    nixPackage "nixpkgs#swtpm", executablePath = "bin/swtpm",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
