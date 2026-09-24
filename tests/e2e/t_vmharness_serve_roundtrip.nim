## t_vmharness_serve_roundtrip — RA1 gate.
##
## A REMOTE ``vm-harness`` client drives a full provision → run(exec probe)
## → destroy cycle against a ``vm-harness serve`` daemon over the
## authenticated HTTP/JSON endpoint, and:
##
##   (a) the run leaves NO residue and is byte-equivalent to the local
##       ``vm-harness run`` path (the envelope the daemon writes is compared,
##       normalized for timings, against a locally-produced one for the
##       identical argv);
##   (b) an unauthenticated / wrong-credential client is REJECTED (HTTP 401,
##       surfaced as ``ServeAuthError``) before any work runs.
##
## Mock policy (design doc §9.1): the ONLY mock is ``NoopBackend`` — the
## sanctioned test fixture — used so the roundtrip is hermetic (no real
## hypervisor). The daemon, the client, the TCP transport, the HTTP framing,
## and the bearer-token auth are all REAL. The incus-backed variant that
## exercises a real backend over the same endpoint lives behind
## ``just test-host`` (``t_vmharness_serve_roundtrip_incus``).
##
## Test topology (no threads): the compiled test binary re-execs ITSELF in
## two auxiliary roles so a genuine cross-process remote roundtrip runs with
## no external binary dependency:
##   * ``<binary> __serve <host> <port> <tokenFile> <portFile>`` runs the
##     daemon (worker = this same binary in ``__vmh_cli`` mode);
##   * ``<binary> __vmh_cli <argv...>`` runs the real vm-harness CLI.

import std/[json, os, osproc, strutils, tempfiles, times, unittest]
import vm_harness
import vm_harness/cli   # runCli — the local dispatch the daemon worker re-runs

# ---------------------------------------------------------------------------
# Auxiliary self-exec roles. Checked BEFORE the unittest runner so a re-exec
# never re-enters the suite.

when isMainModule:
  let params = commandLineParams()
  if params.len >= 1 and params[0] == "__vmh_cli":
    quit(runCli(params[1 .. ^1]))
  elif params.len >= 5 and params[0] == "__serve":
    let cfg = ServeConfig(
      listenHost: params[1],
      listenPort: parseInt(params[2]),
      token: readFile(params[3]).strip(),
      workerExe: getAppFilename(),
      workerArgPrefix: @["__vmh_cli"],
      portFile: params[4],
      quiet: false)
    runServe(cfg)
    quit(0)

proc normalizeEnvelope(s: string): string =
  ## Strip the non-deterministic parts of an output-envelope file (per-step
  ## ``elapsed_ms`` values and ISO-8601 log timestamps) so two runs of the
  ## identical argv can be compared for byte-equivalence.
  for line in s.splitLines():
    var l = line
    let ei = l.find("elapsed_ms:")
    if ei >= 0:
      l = l[0 ..< ei] & "elapsed_ms: N"
    if l.len >= 20 and l[4] == '-' and l[7] == '-' and l[10] == 'T' and
       l[19] == 'Z':
      let sp = l.find(' ')
      if sp > 0:
        l = "TS" & l[sp .. ^1]
    result.add(l & "\n")

proc waitForPort(portFile: string, timeoutSec = 10.0): int =
  ## Poll the daemon's port-file until it reports its bound port.
  let deadline = epochTime() + timeoutSec
  while epochTime() < deadline:
    if fileExists(portFile):
      let raw = readFile(portFile).strip()
      if raw.len > 0:
        try: return parseInt(raw)
        except ValueError: discard
    sleep(50)
  raise newException(IOError, "daemon did not report a port within timeout")

suite "t_vmharness_serve_roundtrip":
  # Shared daemon fixture for the whole suite.
  let work = createTempDir("vmh-serve-", "")
  let tokenFile = work / "token"
  let portFile = work / "port"
  let incusLog = work / "incus.log"
  let fakeIncus = work / "incus"
  let token = "unit-test-bearer-3f9a2c"
  writeFile(tokenFile, token)
  writeFile(fakeIncus,
    "#!/bin/sh\n" &
    "printf '%s\\n' \"$*\" >> '" & incusLog & "'\n" &
    "case \"$*\" in\n" &
    "  'info remote-capability') exit 1 ;;\n" &
    "  'list remote-capability --format csv -c s') printf 'RUNNING\\n' ;;\n" &
    "  'exec remote-capability -- stat -c %a /dev/kvm') " &
      "printf '666\\n' ;;\n" &
    "esac\n")
  setFilePermissions(fakeIncus, {fpUserRead, fpUserWrite, fpUserExec})

  let priorIncusCmd = getEnv("VMH_INCUS_CMD")
  putEnv("VMH_INCUS_CMD", fakeIncus)
  var daemon: Process
  try:
    daemon = startProcess(
      getAppFilename(),
      args = @["__serve", "127.0.0.1", "0", tokenFile, portFile],
      options = {poParentStreams})
  finally:
    if priorIncusCmd.len > 0:
      putEnv("VMH_INCUS_CMD", priorIncusCmd)
    else:
      delEnv("VMH_INCUS_CMD")
  var port = 0
  try:
    port = waitForPort(portFile)
  except CatchableError:
    daemon.terminate()
    raise

  let addr0 = "127.0.0.1:" & $port
  let client = newServeClient(addr0, token)

  test "unauthenticated / wrong-credential client is rejected (401)":
    let bad = newServeClient(addr0, "wrong-token")
    expect ServeAuthError:
      discard bad.info()
    expect ServeAuthError:
      discard bad.execStream(@["probe"], proc(ev: ExecEvent) = discard)
    # An empty token is likewise rejected.
    let empty = newServeClient(addr0, "")
    expect ServeAuthError:
      discard empty.info()

    writeFile(incusLog, "")
    expect ServeAuthError:
      discard bad.execStream(@[
        "run", "--ephemeral", "--backend", "incus",
        "--baseline", "remote-capability", "--incus-nested-kvm",
      ], proc(ev: ExecEvent) = discard)
    check readFile(incusLog).len == 0

  test "authenticated info advertises the noop backend (capability seed)":
    let ni = client.info()
    check ni["protocol"].getStr == ProtocolVersion
    check ni["service"].getStr == ServiceName
    var sawNoop = false
    for b in ni["backends"]:
      if b["id"].getStr == "noop":
        sawNoop = true
        check b["available"].getBool
    check sawNoop

  test "remote provision -> run(exec probe) -> destroy, no residue, " &
       "byte-equivalent to local":
    let remoteOut = work / "remote-out"
    let localOut = work / "local-out"
    let runArgv = @["run", "--backend", "noop", "--baseline", "rt",
                    "--output-dir", remoteOut, "--", "/bin/echo", "hello"]

    # 1. provision over RPC.
    var provLog: seq[string]
    let provCode = client.execStream(
      @["provision", "--backend", "noop", "--baseline", "rt"],
      proc(ev: ExecEvent) =
        if ev.kind == ekLog: provLog.add(ev.line))
    check provCode == 0

    # 2. run (revert -> exec probe -> cleanup/destroy) over RPC, streaming.
    var runLog: seq[string]
    let runCode = client.execStream(runArgv, proc(ev: ExecEvent) =
      if ev.kind == ekLog: runLog.add(ev.line))
    check runCode == 0
    # The stream actually carried live log lines from the daemon worker.
    check runLog.len > 0

    # 3. The daemon wrote a complete envelope (shared FS on loopback).
    check fileExists(remoteOut / "DONE")
    check readFile(remoteOut / "DONE").strip == "PASS"
    let remoteResult = readFile(remoteOut / "RESULT.txt")
    check "verdict: PASS" in remoteResult
    # "destroy / no residue" evidence: the per-gate cleanup step ran ok.
    check "step: cleanup  status: ok" in remoteResult

    # 4. Byte-equivalence: run the identical argv LOCALLY and compare the
    #    envelope (normalized for timings). Same binary, same backend code.
    var localArgv = runArgv
    localArgv[localArgv.find(remoteOut)] = localOut
    check runCli(localArgv) == 0

    check normalizeEnvelope(readFile(remoteOut / "RESULT.txt")) ==
          normalizeEnvelope(readFile(localOut / "RESULT.txt"))
    check readFile(remoteOut / "DONE") == readFile(localOut / "DONE")
    # The per-command artifact (02-echo-run.txt) is identical too.
    proc runArtifact(dir: string): string =
      for kind, path in walkDir(dir):
        if kind == pcFile and "02-echo" in extractFilename(path):
          return readFile(path)
      ""
    let remoteArt = runArtifact(remoteOut)
    let localArt = runArtifact(localOut)
    check remoteArt.len > 0
    check normalizeEnvelope(remoteArt) == normalizeEnvelope(localArt)

  test "authenticated remote Incus capability argv reaches fixed local policy":
    # The incus backend's lifecycle methods (startAndAwaitReady / execInGuest /
    # stopAndCleanup) exist only on Linux hosts and raise
    # BackendUnavailableError elsewhere, so the full `run --ephemeral` argv
    # can only be exercised on Linux. The 401 case above still proves, on
    # every host, that an unauthenticated incus argv never reaches the shim.
    when not defined(linux):
      skip()
    else:
      writeFile(incusLog, "")
      var logs: seq[string]
      let code = client.execStream(@[
        "run", "--ephemeral", "--backend", "incus",
        "--baseline", "remote-capability", "--base-image", "runner-base",
        "--incus-security-nesting", "--incus-nested-kvm", "--", "true",
      ], proc(ev: ExecEvent) =
        if ev.kind == ekLog: logs.add(ev.line))
      check code == 0
      check logs.len > 0
      check readFile(incusLog).strip().splitLines() == @[
        "info remote-capability",
        "init runner-base remote-capability",
        "config set remote-capability security.nesting true",
        "config set remote-capability security.syscalls.intercept.mknod true",
        "config set remote-capability security.syscalls.intercept.setxattr true",
        "config device add remote-capability kvm unix-char source=/dev/kvm " &
          "path=/dev/kvm mode=0666",
        "start remote-capability",
        "exec remote-capability -- true",
        "exec remote-capability -- chmod 0666 /dev/kvm",
        "exec remote-capability -- stat -c %a /dev/kvm",
        "exec remote-capability -- sh -c exec 3<>/dev/kvm",
        "list remote-capability --format csv -c s",
        "exec remote-capability -- true",
        "exec remote-capability -- true",
        "delete --force remote-capability",
      ]

  test "graceful shutdown stops the daemon":
    client.shutdown()
    check daemon.waitForExit(timeout = 5000) == 0

  # Fixture teardown: make sure the daemon is gone and the temp dir removed.
  if daemon.running:
    daemon.terminate()
    discard daemon.waitForExit(timeout = 3000)
  daemon.close()
  removeDir(work)
