# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Unit tests for CLI probe backend filtering.

import std/unittest
import gosti/cli
import gosti/types

suite "cli probe backend selection":
  test "probe without --backend keeps the all-registered behavior":
    let opts = parseCliOpts(@["probe"])
    check probeBackendIds(opts).len > 1

  test "probe --backend narrows to exactly that backend":
    let opts = parseCliOpts(@["probe", "--backend", "tart-macos"])
    check probeBackendIds(opts) == @[biTartMacos]
