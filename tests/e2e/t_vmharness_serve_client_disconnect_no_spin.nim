# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_vmharness_serve_client_disconnect_no_spin — a client that disconnects
## mid-stream must cost the daemon NOTHING: no CPU spin, no stalled worker, no
## zombie. docs/serve.md "Client disconnects: finish the worker, never spin".
##
## WHY THIS IS PINNED. The deployed daemon on high-mem-server burned ~10.5
## cores after GARM's provider processes were cancelled: seven handler threads
## at ~91% each, 225,086 failed `sendto` -> EPIPE calls in 5 s, and 16
## `<defunct>` workers. std/net's `send(Socket, string)` swallows EPIPE inside
## its own write-until-done loop without advancing, so each handler writing to
## a vanished client spun forever, never read its worker's pipe again (the
## worker then blocked on a full pipe), and never reached its `waitpid`.
##
## What is asserted, each independently falsifiable:
##   1. IDLE: over a fixed window after several clients abandon a chatty exec,
##      the daemon's CPU time stays under a small budget (a single spinning
##      handler burns ~the whole window).
##   2. COMPLETION: every abandoned worker finishes — it emits more output than
##      a pipe buffer holds, so a handler that stops draining blocks it.
##   3. REAPED: after abandoned AND completed execs, the daemon has zero child
##      processes of any state (so zero zombies), and still serves requests.
## Negative control: pointing `http.sendAll`'s callers back at std/net's
## `send(Socket, string)` makes 1 and 2 fail (and 3's child count).
##
## (1) and (3) read /proc and are Linux-only; elsewhere they are skipped with a
## printed reason and (2) still runs.
##
## MOCK JUSTIFICATION (workspace test policy). No hypervisor is exercised: the
## daemon's worker is this test binary re-execed in a `__work` role that
## streams output at a fixed rate. What is under test is ONLY serve's
## disconnect handling; the daemon, TCP transport, HTTP chunked framing,
## bearer auth and the real Nim serve client are all real. A real backend
## verb cannot be used because the observables — daemon CPU while a worker is
## still running, and whether that worker gets to finish — must not depend on
## an incus/libvirt host being present.

import std/[os, osproc, strutils, tempfiles, unittest]
import vm_harness

const
  ChattySeconds = 3
    ## How long each abandoned worker streams. Long enough that the CPU window
    ## below sits entirely inside it.
  LinesPerTick = 10
  TickMs = 40
    ## 10 lines / 40 ms of ~200 bytes = ~50 KB/s, ~150 KB total: well past a
    ## 64 KiB pipe buffer, yet trivially cheap for a draining handler.
  CpuWindowMs = 1500
  CpuBudgetSec = 0.3
    ## A single spinning handler burns ~1.5 s in the window; three burn ~4.5 s.
  Abandoned = 3

when isMainModule:
  let params = commandLineParams()
  if params.len >= 2 and params[0] == "__work":
    case params[1]
    of "chatty":
      # __work chatty <markerFile>: stream at a fixed rate, then mark.
      let filler = repeat('x', 190)
      for tick in 0 ..< (ChattySeconds * 1000 div TickMs):
        for i in 0 ..< LinesPerTick:
          stdout.writeLine("line " & $tick & "." & $i & " " & filler)
        stdout.flushFile()
        sleep(TickMs)
      writeFile(params[2], "finished")
      quit(0)
    of "quick":
      echo "quick done"
      quit(0)
    else:
      quit(2)
  elif params.len >= 6 and params[0] == "__serve":
    runServe(ServeConfig(
      listenHost: params[1], listenPort: parseInt(params[2]),
      token: readFile(params[3]).strip(), workerExe: getAppFilename(),
      workerArgPrefix: @["__work"], portFile: params[4],
      serveThreads: parseInt(params[5]), quiet: true))
    quit(0)
  elif params.len >= 4 and params[0] == "__abandon":
    # __abandon <addr> <tokenFile> <markerFile>: start a chatty exec, then
    # vanish on the first streamed line — exactly what a SIGKILLed provider
    # process produces.
    let cl = newServeClient(params[1], readFile(params[2]).strip())
    discard cl.execStream(@["chatty", params[3]],
                          proc(ev: ExecEvent) = quit(0))
    quit(0)

proc waitForPort(portFile: string): int =
  for _ in 0 ..< 200:
    if fileExists(portFile):
      let raw = readFile(portFile).strip()
      if raw.len > 0: return parseInt(raw)
    sleep(50)
  raise newException(IOError, "daemon did not report a port")

when defined(linux):
  proc statFields(pid: string): seq[string] =
    ## /proc/<pid>/stat split AFTER the parenthesised comm (which may contain
    ## spaces): result[0] is the state, result[1] the ppid, result[11]/[12]
    ## utime/stime in clock ticks.
    try:
      let raw = readFile("/proc" / pid / "stat")
      raw[raw.rfind(')') + 2 .. ^1].splitWhitespace()
    except CatchableError:
      @[]

  proc cpuSeconds(pid: int): float =
    let f = statFields($pid)
    (parseInt(f[11]) + parseInt(f[12])).float / 100.0   # USER_HZ is 100

  proc children(pid: int): seq[tuple[pid, state: string]] =
    for kind, path in walkDir("/proc"):
      let name = path.extractFilename
      if kind != pcDir or not name.allCharsInSet(Digits): continue
      let f = statFields(name)
      if f.len > 1 and f[1] == $pid:
        result.add((pid: name, state: f[0]))

suite "t_vmharness_serve_client_disconnect_no_spin":
  let work = createTempDir("vmh-dc-nospin-", "")
  let tokenFile = work / "token"
  let portFile = work / "port"
  let token = "dc-nospin-bearer-4e1f"
  writeFile(tokenFile, token)
  let daemon = startProcess(getAppFilename(),
    args = @["__serve", "127.0.0.1", "0", tokenFile, portFile, "4"],
    options = {poParentStreams})
  let address = "127.0.0.1:" & $waitForPort(portFile)
  var markers: seq[string]

  test "abandoned chatty execs leave the daemon idle":
    var clients: seq[Process]
    for i in 0 ..< Abandoned:
      let m = work / ("chatty-" & $i & ".done")
      markers.add(m)
      clients.add(startProcess(getAppFilename(),
        args = @["__abandon", address, tokenFile, m],
        options = {poParentStreams}))
    for c in clients.mitems:
      check c.waitForExit() == 0
      c.close()
    when defined(linux):
      # Let the handlers hit the dead sockets, then measure a window that
      # still lies inside the workers' ChattySeconds run.
      sleep(300)
      let before = cpuSeconds(daemon.processID)
      sleep(CpuWindowMs)
      let used = cpuSeconds(daemon.processID) - before
      echo "  daemon CPU over ", CpuWindowMs, " ms with ", Abandoned,
           " abandoned streams: ", used, " s (budget ", CpuBudgetSec, " s)"
      check used < CpuBudgetSec
    else:
      echo "  SKIP cpu window: needs /proc (Linux only)"

  test "every abandoned worker runs to completion":
    for _ in 0 ..< 150:
      var all = true
      for m in markers:
        if not fileExists(m): all = false
      if all: break
      sleep(100)
    for m in markers:
      check fileExists(m)

  test "no zombies, no leftover children, still serving":
    let cl = newServeClient(address, token)
    for _ in 0 ..< 3:
      var lines: seq[string]
      let code = cl.execStream(@["quick"], proc(ev: ExecEvent) =
        if ev.kind == ekLog: lines.add(ev.line))
      check code == 0
      check "quick done" in lines
    when defined(linux):
      # Handlers reap before closing their connection, but the abandoned
      # ones may still be finishing their exit bookkeeping; allow a moment.
      var kids = children(daemon.processID)
      for _ in 0 ..< 50:
        if kids.len == 0: break
        sleep(100)
        kids = children(daemon.processID)
      var zombies = 0
      for k in kids:
        if k.state == "Z": inc zombies
      echo "  daemon children after ", Abandoned, " abandoned + 3 completed ",
           "execs: ", kids.len, " (zombies: ", zombies, ")"
      check zombies == 0
      check kids.len == 0
    else:
      echo "  SKIP zombie census: needs /proc (Linux only)"

  daemon.terminate()
  discard daemon.waitForExit()
  daemon.close()
  removeDir(work)
