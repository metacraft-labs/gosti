# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_gosti_serve_exit_despite_held_output — a worker that exits while a
## background descendant still holds its stdout must still end its
## ``/v1/exec`` stream with ``exit`` promptly. docs/contributors/serve.md
## "`/v1/exec` event stream".
##
## WHY THIS IS PINNED. ``run --ephemeral --keep`` on Tart left ``tart run``
## running with the worker's stdout pipe as its own stdout. ``handleExec`` read
## that pipe until EOF before reporting ``exit``, and EOF never came while the
## guest ran: every remote Tart create hung until GARM's 20-minute provider
## deadline destroyed the guest. The Tart backend no longer leaks its stdio; this
## gate holds the daemon's own defence in depth.
##
## What is asserted, each independently falsifiable:
##   1. PROMPT EXIT: the exec delivers the worker's output and ``exit 0``
##      within a few seconds, while the descendant is provably still alive
##      and still holding the pipe (a daemon that waits for EOF waits 600 s;
##      the client is bounded at ``ClientBudgetMs`` and the test fails).
##   2. NO SIGPIPE / EPIPE: the descendant writes to the pipe AFTER ``exit``
##      was delivered, survives, and the write succeeds. A daemon that closed
##      its read end when it gave up waiting kills it on that write (SIGPIPE)
##      or, since the daemon ignores SIGPIPE and descendants inherit that,
##      fails the write with EPIPE.
##   3. REAPED, AND THE PIPE IS RELEASED: the daemon has no child processes
##      left, holds the pipe open while the descendant lives, and closes it
##      once the descendant is killed (the daemon's pipe-descriptor count drops
##      by exactly one).
## (3) reads /proc and is Linux-only; elsewhere it is skipped with a printed
## reason and (1) and (2) still run.
##
## MOCK JUSTIFICATION (workspace test policy). No hypervisor is exercised: the
## daemon's worker is this test binary re-execed in a ``__work`` role whose
## ``leak`` verb starts a background shell that inherits its stdout, exactly
## the shape ``tart run`` had. What is under test is ONLY serve's exec stream
## termination; the daemon, TCP transport, HTTP chunked framing, bearer auth
## and the real Nim serve client are all real. A real Tart guest needs a macOS
## host and would make the observable depend on one.

import std/[os, osproc, strutils, tempfiles, unittest]
import gosti
when defined(posix):
  import std/posix

const
  LateWriteSec = 4
    ## When the descendant writes to the held pipe. Later than the daemon's
    ## post-exit drain (``ExitedWorkerDrainMs``, 2 s) so the write lands after
    ## the handler has given up on EOF.
  ClientBudgetMs = 15_000
    ## Upper bound for the whole exec as seen by the client. Generous against
    ## the 2 s drain on a loaded host, tiny against the 600 s a daemon that
    ## waits for EOF would take.

proc fixtureWorkerPolicy(argv: seq[string]): string {.nimcall, gcsafe.} =
  ## The daemon's worker here is this test's self-exec fixture, not the gosti
  ## CLI, so the production argv policy (``gostiExecPolicy``) does not describe
  ## it. Admit exactly the fixture's own verbs.
  if argv.len > 0 and argv[0] in ["leak", "quick"]: ""
  else: "not a fixture verb"

when isMainModule:
  let params = commandLineParams()
  if params.len >= 2 and params[0] == "__work":
    case params[1]
    of "leak":
      # __work leak <pidFile>: leave a background shell holding our stdout,
      # print, exit 0. The shell writes once more after LateWriteSec and then
      # becomes a long sleep under the same pid.
      # The late write records whether it succeeded: the daemon ignores
      # SIGPIPE and descendants inherit that, so a closed read end shows up as
      # a failed write (EPIPE) rather than as a death; with SIGPIPE at its
      # default it is a death, which the liveness check catches.
      let pidFile = params[2]
      let script = "(sleep " & $LateWriteSec & "; if echo late; then : > " &
                   quoteShell(pidFile & ".late-ok") & "; else : > " &
                   quoteShell(pidFile & ".late-failed") &
                   "; fi; exec sleep 600) & echo $! > " & quoteShell(pidFile) &
                   "; echo started"
      quit(execShellCmd(script))
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
      execPolicy: fixtureWorkerPolicy,
      serveThreads: parseInt(params[5]), quiet: true))
    quit(0)
  elif params.len >= 5 and params[0] == "__client":
    # __client <addr> <tokenFile> <pidFile> <resultFile>: one leak exec,
    # recorded as "<code>\n<lines…>". A separate process so the test can bound
    # how long it waits for the stream to end.
    let cl = newServeClient(params[1], readFile(params[2]).strip())
    var lines: seq[string]
    let code = cl.execStream(@["leak", params[3]], proc(ev: ExecEvent) =
      if ev.kind == ekLog: lines.add(ev.line))
    writeFile(params[4], $code & "\n" & lines.join("\n"))
    quit(0)

proc waitForPort(portFile: string): int =
  for _ in 0 ..< 200:
    if fileExists(portFile):
      let raw = readFile(portFile).strip()
      if raw.len > 0: return parseInt(raw)
    sleep(50)
  raise newException(IOError, "daemon did not report a port")

proc readPid(path: string): int =
  for _ in 0 ..< 100:
    if fileExists(path):
      let raw = readFile(path).strip()
      if raw.len > 0: return parseInt(raw)
    sleep(50)
  0

when defined(posix):
  proc alive(pid: int): bool =
    pid > 0 and posix.kill(Pid(pid), 0) == 0

when defined(linux):
  proc statFields(pid: string): seq[string] =
    try:
      let raw = readFile("/proc" / pid / "stat")
      raw[raw.rfind(')') + 2 .. ^1].splitWhitespace()
    except CatchableError:
      @[]

  proc childCount(pid: int): int =
    for kind, path in walkDir("/proc"):
      let name = path.extractFilename
      if kind != pcDir or not name.allCharsInSet(Digits): continue
      let f = statFields(name)
      if f.len > 1 and f[1] == $pid: inc result

  proc pipeCount(pid: int): int =
    for kind, path in walkDir("/proc" / $pid / "fd"):
      try:
        if expandSymlink(path).startsWith("pipe:"): inc result
      except CatchableError:
        discard

when defined(posix):
  suite "t_gosti_serve_exit_despite_held_output":
    let work = createTempDir("gosti-held-output-", "")
    let tokenFile = work / "token"
    let portFile = work / "port"
    let token = "held-output-bearer-7c2a"
    writeFile(tokenFile, token)
    let daemon = startProcess(getAppFilename(),
      args = @["__serve", "127.0.0.1", "0", tokenFile, portFile, "2"],
      options = {poParentStreams})
    let address = "127.0.0.1:" & $waitForPort(portFile)
    let pidFile = work / "descendant.pid"
    var descendant = 0
    var baselinePipes = -1

    test "exit arrives promptly while a descendant holds the worker's stdout":
      let cl = newServeClient(address, token)
      check cl.execStream(@["quick"], proc(ev: ExecEvent) = discard) == 0
      when defined(linux):
        baselinePipes = pipeCount(daemon.processID)
      let resultFile = work / "result"
      let client = startProcess(getAppFilename(),
        args = @["__client", address, tokenFile, pidFile, resultFile],
        options = {poParentStreams})
      var waited = 0
      while client.peekExitCode() == -1 and waited < ClientBudgetMs:
        sleep(50)
        waited += 50
      let finished = client.peekExitCode() != -1
      if not finished:
        client.kill()
      discard client.waitForExit()
      client.close()
      descendant = readPid(pidFile)
      echo "  exec ended after ~", waited, " ms (budget ", ClientBudgetMs,
           " ms); descendant pid ", descendant
      check finished
      check fileExists(resultFile)
      if fileExists(resultFile):
        let parts = readFile(resultFile).splitLines()
        check parts[0] == "0"
        check "started" in parts
      # Positive control: the writer that held the pipe is still running, so
      # the stream ended without EOF.
      check alive(descendant)

    test "the descendant survives writing after exit (no SIGPIPE)":
      # The descendant writes "late" LateWriteSec after it started; give it
      # that long plus a margin, then it must still be alive.
      for _ in 0 ..< (LateWriteSec + 4) * 10:
        if fileExists(pidFile & ".late-ok") or
            fileExists(pidFile & ".late-failed"):
          break
        sleep(100)
      check alive(descendant)
      check fileExists(pidFile & ".late-ok")
      check not fileExists(pidFile & ".late-failed")

    test "worker reaped, and the held pipe closed once the descendant ends":
      when defined(linux):
        check childCount(daemon.processID) == 0
        # The held read end is still open: closing it while the descendant
        # lives is exactly what must not happen. (The daemon also gains the
        # drainer's own control pipe, a pair, on first use.)
        let held = pipeCount(daemon.processID)
        check held > baselinePipes
        if alive(descendant):
          discard posix.kill(Pid(descendant), SIGKILL)
        var pipes = held
        for _ in 0 ..< 60:
          if pipes < held: break
          sleep(50)
          pipes = pipeCount(daemon.processID)
        echo "  daemon pipe descriptors: baseline ", baselinePipes,
             ", while held ", held, ", after the descendant ended ", pipes
        check pipes == held - 1
        # And the daemon still serves.
        let cl = newServeClient(address, token)
        check cl.execStream(@["quick"], proc(ev: ExecEvent) = discard) == 0
      else:
        echo "  SKIP child/pipe census: needs /proc (Linux only)"

    if alive(descendant):
      discard posix.kill(Pid(descendant), SIGKILL)
    daemon.terminate()
    discard daemon.waitForExit()
    daemon.close()
    removeDir(work)
else:
  echo "SKIP t_gosti_serve_exit_despite_held_output: the bounded post-exit ",
       "drain is POSIX-only; the Windows daemon reads to EOF"
