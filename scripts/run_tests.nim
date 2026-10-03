# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Native runner. Discovery and validation are shared with repro.nim.
import std/[os, osproc, strutils]
import test_catalog

const root = currentSourcePath().parentDir.parentDir
if paramCount() != 1 or paramStr(1) notin ["test", "host"]:
  quit("usage: run_tests <test|host>", 2)
setCurrentDir(root)
let specs = loadTestCatalog(root).selectedTests(paramStr(1))
for spec in specs:
  let args = @["r", "--hints:off", "--threads:on", spec.source]
  echo "\n==> nim ", args.join(" ")
  let child = startProcess(findExe("nim"), args = args, options = {poParentStreams})
  let code = child.waitForExit()
  child.close()
  if code != 0:
    quit(code)
