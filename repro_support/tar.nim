# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Real archive operations used by the Lima upload/download fixtures.
import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package tar:
  provisioning:
    nixPackage "nixpkgs#gnutar", executablePath = "bin/tar",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
