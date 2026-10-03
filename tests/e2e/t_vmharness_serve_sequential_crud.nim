# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_vmharness_serve_sequential_crud — back-to-back CRUD requests over
## ``vm-harness serve`` never trip over the previous request's teardown
## (gosti#69).
##
## The production symptom: a client that issues CRUD requests one after
## another (agent-harbor's gosti binding) intermittently got
## ``worker stream error: Bad file descriptor``. Two defects combined:
##
##   1. the exec handler closed the worker's merged stdout/stderr fd twice
##      (``tests/unit/t_serve_worker_fd_hygiene.nim`` pins that, without
##      timing); and
##   2. it wrote the terminal ``exit`` event BEFORE that cleanup ran, so a
##      client that acts on ``exit`` sent its next request while the previous
##      handler was still closing fds, and the next request's freshly opened
##      fds were the ones the stale close hit.
##
## This file pins (2) deterministically and then hammers the whole path:
##
##   * "exit is written only after cleanup": the daemon runs with an
##     injected 1.5 s pause at the START of worker cleanup (the
##     ``workerCleanupHook`` test seam, nil in production). A client that
##     stops at the ``exit`` event must therefore see it no sooner than 1.5 s
##     after it sent the request. The old handler emitted ``exit`` first and
##     the client saw it in milliseconds.
##   * "sequential hammer": 200 back-to-back CRUD round-trips against the
##     file-backed mock backend on a daemon with three handler threads, each
##     request sent the instant the previous ``exit`` arrived (the client
##     drops the connection right there, exactly like a binding that returns
##     on ``exit``). Not one may carry an ``error`` event or a non-zero exit.
##
## Mock policy (design doc §9.1): the ONLY mock is the deterministic
## ``--backend mock`` CRUD backend, used because the property under test is
## the daemon's fd handling and response ordering, not any hypervisor; a real
## backend would add minutes per request and host prerequisites while
## exercising none of the code at fault. The daemon, its worker processes
## (this binary re-execed as the real CLI), the TCP transport, the HTTP
## chunked framing and bearer auth are all real.
##
## Topology (same self-exec scheme as ``t_crud_serve_parity``):
##   * ``<binary> __vmh_cli <argv…>`` is the real CLI (the daemon's worker);
##   * ``<binary> __serve <host> <port> <tokenFile> <portFile> <threads>
##     <cleanupDelayMs>`` runs the daemon.

import std/[json, net, os, osproc, strutils, tempfiles, times, unittest]
import vm_harness
import vm_harness/cli

var cleanupDelayMs: int

proc delayCleanup(stage: WorkerCleanupStage) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    if stage == wcsBegin and cleanupDelayMs > 0:
      sleep(cleanupDelayMs)

when isMainModule:
  let params = commandLineParams()
  if params.len >= 1 and params[0] == "__vmh_cli":
    quit(runCli(params[1 .. ^1]))
  elif params.len >= 7 and params[0] == "__serve":
    cleanupDelayMs = parseInt(params[6])
    if cleanupDelayMs > 0:
      workerCleanupHook = delayCleanup
    let cfg = ServeConfig(
      listenHost: params[1],
      listenPort: parseInt(params[2]),
      token: readFile(params[3]).strip(),
      workerExe: getAppFilename(),
      workerArgPrefix: @["__vmh_cli"],
      portFile: params[4],
      serveThreads: parseInt(params[5]),
      quiet: true)
    runServe(cfg)
    quit(0)

proc waitForPort(portFile: string, timeoutSec = 10.0): int =
  let deadline = epochTime() + timeoutSec
  while epochTime() < deadline:
    if fileExists(portFile):
      let raw = readFile(portFile).strip()
      if raw.len > 0:
        try: return parseInt(raw)
        except ValueError: discard
    sleep(50)
  raise newException(IOError, "daemon did not report a port within timeout")

type Reply = object
  code: int           ## exit code from the ``exit`` event; -1 if none
  errors: seq[string] ## every ``error`` event
  lines: seq[string]  ## every ``log`` line
  elapsed: float      ## seconds from request sent to ``exit`` received

proc execUntilExit(port: int, token: string, argv: seq[string]): Reply =
  ## A client that RETURNS ON ``exit`` and drops the connection, without
  ## waiting for the chunked terminator — what a binding that acts on the
  ## terminal event does, and the client the old ordering raced.
  result.code = -1
  var sock = newSocket()
  try:
    sock.connect("127.0.0.1", Port(port))
    let body = $toJson(ExecRequest(v: ProtocolVersion, argv: argv))
    let t0 = epochTime()
    sock.sendRequest("POST", PathExec, "127.0.0.1:" & $port,
                     @[("Authorization", AuthScheme & token),
                       ("Content-Type", "application/json")], body)
    let head = sock.readResponseHead()
    doAssert head.status == 200, "exec status " & $head.status
    block stream:
      for chunk in sock.readChunks():
        for raw in chunk.splitLines():
          let line = raw.strip()
          if line.len == 0: continue
          let ev = parseEvent(line)
          case ev.kind
          of ekLog: result.lines.add(ev.line)
          of ekError: result.errors.add(ev.message)
          of ekExit:
            result.code = ev.code
            result.elapsed = epochTime() - t0
            break stream
  finally:
    sock.close()

proc startDaemon(work, tokenFile: string, threads, delayMs: int):
    tuple[p: Process, port: int] =
  let portFile = work / ("port-" & $delayMs)
  let p = startProcess(
    getAppFilename(),
    args = @["__serve", "127.0.0.1", "0", tokenFile, portFile, $threads,
             $delayMs],
    options = {poParentStreams})
  try:
    (p, waitForPort(portFile))
  except CatchableError:
    p.terminate()
    raise

proc stopDaemon(d: tuple[p: Process, port: int], token: string) =
  try: newServeClient("127.0.0.1:" & $d.port, token).shutdown()
  except CatchableError: discard
  if d.p.waitForExit(timeout = 8000) != 0 or d.p.running:
    d.p.terminate()
    discard d.p.waitForExit(timeout = 3000)
  d.p.close()

suite "t_vmharness_serve_sequential_crud":
  let work = createTempDir("vmh-seq-crud-", "")
  let tokenFile = work / "token"
  let token = "seq-crud-bearer-5d02"
  writeFile(tokenFile, token)

  test "the exit event is written only after the worker is cleaned up":
    const delayMs = 1500
    let d = startDaemon(work, tokenFile, threads = 2, delayMs = delayMs)
    try:
      let r = execUntilExit(d.port, token,
        @["crud", "list_vms", "--backend", "mock",
          "--state-dir", work / "order-state"])
      check r.errors.len == 0
      check r.code == 0
      check r.lines.len == 1
      # The exit event cannot have left the daemon before the cleanup pause
      # did. 0.1 s of slack for timer granularity; the old order arrives
      # after the worker's own runtime alone (tens of milliseconds).
      check r.elapsed >= (delayMs - 100) / 1000
    finally:
      stopDaemon(d, token)

  test "200 back-to-back CRUD requests: no worker stream error":
    let d = startDaemon(work, tokenFile, threads = 3, delayMs = 0)
    try:
      let state = work / "hammer-state"
      let base = @["--backend", "mock", "--state-dir", state]
      let created = execUntilExit(d.port, token,
        @["crud", "create_vm", "vm1"] & base)
      check created.errors.len == 0
      check created.code == 0
      var failures: seq[string]
      for i in 0 ..< 200:
        let argv =
          if i mod 2 == 0: @["crud", "get_vm", "vm1"] & base
          else: @["crud", "snapshot", "vm1", "s" & $i] & base
        let r = execUntilExit(d.port, token, argv)
        if r.errors.len > 0 or r.code != 0 or r.lines.len != 1 or
            not parseJson(r.lines[0])["ok"].getBool:
          failures.add("#" & $i & " " & argv[1] & ": exit " & $r.code &
                       " errors " & $r.errors & " lines " & $r.lines)
      if failures.len > 0:
        echo "first failures:\n  ", failures[0 ..< min(5, failures.len)].join("\n  ")
      check failures.len == 0
    finally:
      stopDaemon(d, token)

  removeDir(work)
