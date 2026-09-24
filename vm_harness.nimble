# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
# Package
version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Cross-platform VM lifecycle orchestration (Tart, UTM, Hyper-V, WSL, libvirt, Lima)"
license       = "Apache-2.0"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["vm_harness/cli"]
binDir        = "build/bin"
namedBin["vm_harness/cli"] = "vm-harness"

# Dependencies
requires "nim >= 2.0.0"
