# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_gosti_command_names — the installed command layout after the
## vm-harness -> gosti rename (docs/design.md §6.0).
##
## Builds the REAL CLI, installs it with the SAME script the flake's
## installPhase and `just build` use (scripts/install-binaries.sh), and pins:
##   1. `bin/gosti` is the executable; `bin/vm-harness` is a symlink to it.
##   2. Both names print the same help, which names `gosti`.
##   3. A serve daemon started under the COMPATIBILITY name — exactly how the
##      deployed `vm-harness serve` units start it — accepts an authenticated
##      exec and runs its worker (the daemon re-execs its resolved self), with
##      the result a client driving it by the new name expects.
##
## MOCK JUSTIFICATION (workspace test policy): none needed beyond the
## design-sanctioned `noop` backend for the forwarded crud verb; the compiler,
## install script, filesystem, daemon, TCP transport and client are all real.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import vm_harness

let repoRoot = currentSourcePath().parentDir.parentDir.parentDir

proc waitForPort(portFile: string): int =
  for _ in 0 ..< 200:
    if fileExists(portFile):
      let raw = readFile(portFile).strip()
      if raw.len > 0: return parseInt(raw)
    sleep(50)
  raise newException(IOError, "daemon did not report a port")

suite "t_gosti_command_names":
  let work = createTempDir("gosti-names-", "")
  let built = work / "cli.out"
  let bin = work / "bin"
  let (buildOut, buildCode) = execCmdEx(
    "nim c --hints:off --path:" & quoteShell(repoRoot / "src") &
    " --nimcache:" & quoteShell(work / "nimcache") &
    " -o:" & quoteShell(built) & " " &
    quoteShell(repoRoot / "src" / "vm_harness" / "cli.nim"))
  if buildCode != 0: echo buildOut
  let (instOut, instCode) = execCmdEx("bash " &
    quoteShell(repoRoot / "scripts" / "install-binaries.sh") & " " &
    quoteShell(built) & " " & quoteShell(bin))
  if instCode != 0: echo instOut

  test "gosti is the binary, vm-harness a symlink to it":
    check buildCode == 0
    check instCode == 0
    check fileExists(bin / "gosti")
    check not symlinkExists(bin / "gosti")
    check symlinkExists(bin / "vm-harness")
    check expandSymlink(bin / "vm-harness") == "gosti"   # relative
    check sameFile(bin / "vm-harness", bin / "gosti")

  test "both names print the same help, naming gosti":
    let (g, gc) = execCmdEx(quoteShell(bin / "gosti") & " --help")
    let (v, vc) = execCmdEx(quoteShell(bin / "vm-harness") & " --help")
    check gc == 0
    check vc == 0
    check g == v
    check g.startsWith("gosti <subcommand>")

  test "a daemon started as vm-harness serves execs":
    let tokenFile = work / "token"
    let portFile = work / "port"
    let token = "gosti-names-bearer-51d2"
    writeFile(tokenFile, token)
    let daemon = startProcess(bin / "vm-harness",
      args = @["serve", "--listen", "127.0.0.1:0", "--auth-token-file",
               tokenFile, "--port-file", portFile, "--quiet"],
      options = {poParentStreams})
    try:
      let cl = newServeClient("127.0.0.1:" & $waitForPort(portFile), token)
      var lines: seq[string]
      let code = cl.execStream(@["crud", "list_vms", "--backend", "noop",
                                 "--state-dir", work / "crud"],
        proc(ev: ExecEvent) =
          if ev.kind == ekLog: lines.add(ev.line))
      check code == 0
      check lines.len == 1
      if lines.len == 1:
        check parseJson(lines[0])["ok"].getBool
      cl.shutdown()
      check daemon.waitForExit() == 0
    finally:
      if daemon.running: daemon.terminate()
      daemon.close()

  removeDir(work)
