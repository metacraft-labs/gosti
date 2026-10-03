# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Native command stand-ins for tests of external CLI boundaries. A private
## copy of the importing test executable reads its own sidecar before that
## test's suite starts. This replaces shell-script stand-ins on Windows while
## retaining real argv, process creation, exit status and filesystem effects.
## Each importing test documents why its external command is substituted.

import std/[json, os, osproc, strutils]

const FixtureSuffix = ".vmh-command.json"

proc fixtureExit(code: cint) {.importc: "exit", header: "<stdlib.h>", noreturn.}
  ## Nim's quit clamps POSIX statuses to signed int8; SSH needs exit 255.

proc commandFixture*(path: string, config: JsonNode): string =
  result = path & (when defined(windows): ".exe" else: "")
  # A previous invocation can leave this image mapped by Windows translation
  # services. Reconfiguring an identical command only changes its sidecar;
  # rewriting the executable is unnecessary and can fail with sharing violation.
  # Compare bytes so an old or unrelated fixture is still replaced normally.
  if not sameFileContent(getAppFilename(), result):
    copyFileWithPermissions(getAppFilename(), result)
  writeFile(result & FixtureSuffix, $config)

let fixtureConfigPath = getAppFilename() & FixtureSuffix
if fileExists(fixtureConfigPath):
  let cfg = parseFile(fixtureConfigPath)
  let args = commandLineParams()
  if cfg.hasKey("forwardSkip"):
    let first = cfg["forwardSkip"].getInt()
    doAssert args.len > first, "missing executable in forwarding fixture"
    let child = startProcess(args[first], args = args[first + 1 .. ^1],
      options = {poParentStreams})
    let code = child.waitForExit()
    child.close()
    fixtureExit(cint(code))
  if cfg.hasKey("log"):
    let log = open(cfg["log"].getStr(), fmAppend)
    log.writeLine(args.join(" "))
    log.close()
  if cfg.hasKey("sleepMs"):
    sleep(cfg["sleepMs"].getInt())
  if cfg.hasKey("failFirstArg") and args.len > 0 and
      args[0] == cfg["failFirstArg"].getStr():
    fixtureExit(cint(cfg["failureCode"].getInt()))
  if cfg.hasKey("attempts"):
    let path = cfg["attempts"].getStr()
    let count = (if fileExists(path): parseInt(readFile(path)) else: 0) + 1
    writeFile(path, $count)
    if count < cfg["successAfter"].getInt():
      if cfg.hasKey("failureOutput"):
        stderr.writeLine(cfg["failureOutput"].getStr())
      fixtureExit(cint(cfg["failureCode"].getInt()))
  if cfg.hasKey("output"):
    stdout.write(cfg["output"].getStr())
  if cfg.hasKey("errorOutput"):
    stderr.write(cfg["errorOutput"].getStr())
  fixtureExit(cint(cfg{"exitCode"}.getInt(0)))
