# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Real disk-image operations used by golden-guest and layer-GC fixtures.
## POSIX provisioning uses Nix; Windows CI provides the MSYS2 UCRT64 tool
## and selects path provisioning, retaining the actual executable identity.
import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `qemu-img`:
  provisioning:
    nixPackage "nixpkgs#qemu", executablePath = "bin/qemu-img",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
