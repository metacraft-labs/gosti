# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_vmharness_serve_teardown_survives_disconnect — a teardown the client
## abandons must still FINISH.
##
## WHY THIS IS PINNED. Central GARM cancels provider processes routinely — its
## retry pass runs every delete of a pool in one errgroup, so the first failing
## delete cancels all its siblings. In the 24h to 2026-09-23 ~31k provider
## deletes ended `signal: killed` and ~23k `context canceled`. The question
## that decides the root cause of the STOPPED-container leak on
## gpu-server-001/002 is whether killing the PROVIDER also aborts the remote
## `ephemeral-destroy`. It must not, and it does not: `handleExec` writes
## through a `ClientStream` that marks the client gone on the first failed
## write and then DRAINS the worker to completion without writing again.
## (The leak was the teardown itself reporting success for a container it had
## not removed — gated in tests/unit/t_ephemeral_inventory.)
##
## History: this property originally held only by accident — std/net's
## `Socket.send` swallowed EPIPE by spinning on the dead socket forever, which
## "survived" the disconnect at the cost of a pinned core per connection and a
## worker stalled on a full pipe (see t_vmharness_serve_client_disconnect_no_spin,
## which gates the no-spin half). This gate keeps the survival half: a change
## that let a dead-client write raise out of the stream loop would route the
## handler into its `finally`, which SIGKILLs a still-running worker — i.e.
## every cancelled GARM delete would abort mid-`incus delete`.
##
## MOCK JUSTIFICATION (workspace test policy). No hypervisor is exercised: the
## daemon's worker is this test binary re-execed in a `__work` role that
## streams a heartbeat, sleeps, then writes a completion marker. What is under
## test is ONLY serve's disconnect handling; the daemon, TCP transport, HTTP
## chunked framing, bearer auth and the real Nim serve client are all real. A
## real teardown cannot be used because the observable — "did the worker get
## to finish" — must not depend on an incus/libvirt host being present.

import std/[os, osproc, strutils, tempfiles, unittest]
import vm_harness

when isMainModule:
  let params = commandLineParams()
  if params.len >= 4 and params[0] == "__work":
    # __work <verb> <markerFile> <seconds>: heartbeat every 100ms, then mark.
    let deadline = parseInt(params[3]) * 10
    for i in 0 ..< deadline:
      stdout.writeLine("tick " & $i)
      stdout.flushFile()
      sleep(100)
    writeFile(params[2], "finished")
    quit(0)
  elif params.len >= 6 and params[0] == "__serve":
    runServe(ServeConfig(
      listenHost: params[1], listenPort: parseInt(params[2]),
      token: readFile(params[3]).strip(), workerExe: getAppFilename(),
      workerArgPrefix: @["__work"], portFile: params[4],
      serveThreads: parseInt(params[5]), quiet: true))
    quit(0)
  elif params.len >= 5 and params[0] == "__abandon":
    # __abandon <addr> <tokenFile> <verb> <markerFile>: start the exec, then
    # vanish on the first streamed line — an abrupt disconnect, exactly what a
    # SIGKILLed provider process produces.
    let cl = newServeClient(params[1], readFile(params[2]).strip())
    discard cl.execStream(@[params[3], params[4], "3"],
                          proc(ev: ExecEvent) = quit(0))
    quit(0)

proc waitForPort(portFile: string): int =
  for _ in 0 ..< 200:
    if fileExists(portFile):
      let raw = readFile(portFile).strip()
      if raw.len > 0: return parseInt(raw)
    sleep(50)
  raise newException(IOError, "daemon did not report a port")

suite "t_vmharness_serve_teardown_survives_disconnect":
  let work = createTempDir("vmh-teardown-dc-", "")
  let tokenFile = work / "token"
  let portFile = work / "port"
  writeFile(tokenFile, "teardown-dc-bearer-91ac")
  let daemon = startProcess(getAppFilename(),
    args = @["__serve", "127.0.0.1", "0", tokenFile, portFile, "4"],
    options = {poParentStreams})
  let address = "127.0.0.1:" & $waitForPort(portFile)

  proc abandon(verb, marker: string) =
    let c = startProcess(getAppFilename(),
      args = @["__abandon", address, tokenFile, verb, marker],
      options = {poParentStreams})
    discard c.waitForExit()
    c.close()

  test "an abandoned ephemeral-destroy runs to completion":
    let marker = work / "destroy.done"
    abandon("ephemeral-destroy", marker)
    # Worker needs ~3s; give it ample margin.
    for _ in 0 ..< 100:
      if fileExists(marker): break
      sleep(100)
    check fileExists(marker)

  daemon.terminate()
  discard daemon.waitForExit()
  daemon.close()
  removeDir(work)
