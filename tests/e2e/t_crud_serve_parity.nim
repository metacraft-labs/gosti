# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_crud_serve_parity — the generic-CRUD ``--json`` contract is identical
## over the local CLI and over ``vm-harness serve``'s ``POST /v1/exec``.
##
## ``docs/design.md`` §8.1 promises that a consumer can drive the CRUD verbs
## either by spawning ``vm-harness crud <verb> …`` locally or by forwarding
## the SAME argv to a serve daemon, and gets the same envelope and the same
## exit code either way. ``t_crud_facade`` pins the envelope in-process; this
## gate pins the two process boundaries a real consumer crosses:
##
##   * LOCAL  — the CLI run as a child process: stdout is exactly ONE line,
##              the JSON envelope; stderr is empty; the exit code is the
##              frozen per-kind code (0 / 2 bad-args / 3 not-found / …).
##   * REMOTE — the identical argv sent over an authenticated ``/v1/exec``:
##              the stream carries exactly one ``log`` event whose line is
##              byte-identical to the local stdout line, and the terminal
##              ``exit`` event carries the same code.
##
## Every case is a single invocation, because the CRUD registry is
## process-local (see ``crud.nim``): each verb is checked on its own.
##
## Mock policy (design doc §9.1): the ONLY mock is ``NoopBackend`` — the
## sanctioned fixture — so the gate is hermetic. The CLI, the daemon, the
## TCP transport, HTTP framing and bearer auth are all real. Same self-exec
## topology as ``t_vmharness_serve_roundtrip``: the test binary re-execs
## itself as the CLI (``__vmh_cli``) and as the daemon (``__serve``).

import std/[json, os, osproc, streams, strutils, tempfiles, times, unittest]
import vm_harness
import vm_harness/cli

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

type LocalRun = object
  stdout, stderr: string
  code: int

proc runLocal(argv: seq[string]): LocalRun =
  ## The CLI as a separate process, stdout and stderr kept apart — exactly
  ## what a subprocess binding sees.
  let p = startProcess(getAppFilename(), args = @["__vmh_cli"] & argv,
                       options = {})
  p.inputStream.close()
  result.stdout = p.outputStream.readAll()
  result.stderr = p.errorStream.readAll()
  result.code = p.waitForExit()
  p.close()

suite "t_crud_serve_parity":
  let work = createTempDir("vmh-crud-serve-", "")
  let tokenFile = work / "token"
  let portFile = work / "port"
  let token = "crud-parity-bearer-7c1e"
  writeFile(tokenFile, token)
  let daemon = startProcess(
    getAppFilename(),
    args = @["__serve", "127.0.0.1", "0", tokenFile, portFile],
    options = {poParentStreams})
  let port = waitForPort(portFile)
  let client = newServeClient("127.0.0.1:" & $port, token)

  var caseNo = 0

  proc withState(argv: seq[string], dir: string): seq[string] =
    ## Splice ``--state-dir`` in before ``--`` (after it is the guest argv).
    let dd = argv.find("--")
    if dd < 0: argv & @["--state-dir", dir]
    else: argv[0 ..< dd] & @["--state-dir", dir] & argv[dd .. ^1]

  proc checkParity(argv: seq[string], wantCode: int,
                   sharedDir = ""): JsonNode =
    ## Run ``crud <argv>`` both ways, assert the contract, return the
    ## parsed envelope for per-verb shape checks. Each path gets its own
    ## fresh crud store (design doc §8.6) so a mutating verb starts from the
    ## same empty state on both sides — unless ``sharedDir`` is given, in
    ## which case both paths address the same store (a read-only verb then
    ## proves the two paths SEE the same VMs).
    inc caseNo
    let localDir = if sharedDir.len > 0: sharedDir
                   else: work / ("local-" & $caseNo)
    let remoteDir = if sharedDir.len > 0: sharedDir
                    else: work / ("remote-" & $caseNo)
    let local = runLocal(@["crud"] & withState(argv, localDir))
    check local.code == wantCode
    check local.stderr == ""
    let lines = local.stdout.strip(leading = false).splitLines()
    check lines.len == 1

    var remoteLines: seq[string]
    var sawError = false
    let remoteCode = client.execStream(@["crud"] & withState(argv, remoteDir),
      proc(ev: ExecEvent) =
        case ev.kind
        of ekLog: remoteLines.add(ev.line)
        of ekError: sawError = true
        of ekExit: discard)
    check not sawError
    check remoteCode == wantCode
    check remoteLines == lines

    result = parseJson(lines[0])
    check result["ok"].getBool == (wantCode == 0)
    if wantCode != 0:
      check result["error"]["code"].getInt == wantCode

  test "list_vms: ok, empty registry":
    let env = checkParity(@["list_vms", "--backend", "noop"], 0)
    check env["verb"].getStr == "list_vms"
    check env["data"]["vms"].len == 0

  test "create_vm: ok, VmInfo running with an ssh endpoint":
    let env = checkParity(@["create_vm", "vm1", "--backend", "noop"], 0)
    let vm = env["data"]["vm"]
    check vm["name"].getStr == "vm1"
    check vm["backend"].getStr == "noop"
    check vm["state"].getStr == "running"
    check vm["ssh"].kind == JObject
    for key in ["host", "port", "user", "auth"]:
      check vm["ssh"].hasKey(key)

  test "get_vm of an unknown vm: not-found (3)":
    let env = checkParity(@["get_vm", "nope", "--backend", "noop"], 3)
    check env["error"]["kind"].getStr == "not-found"

  test "exec on an unknown vm: not-found (3)":
    let env = checkParity(
      @["exec", "nope", "--backend", "noop", "--", "echo", "hi"], 3)
    check env["verb"].getStr == "exec"

  test "unknown verb: bad-args (2)":
    let env = checkParity(@["frob", "--backend", "noop"], 2)
    check env["error"]["kind"].getStr == "bad-args"

  test "unknown backend: bad-args (2)":
    let env = checkParity(@["list_vms", "--backend", "no-such-backend"], 2)
    check env["error"]["kind"].getStr == "bad-args"

  test "missing verb: bad-args (2)":
    discard checkParity(@[], 2)

  test "multi-invocation: local and serve calls share one crud store":
    # §8.6: a VM created by one call is visible to later calls, whichever
    # path each call takes. Both paths resolve the same --state-dir here
    # (loopback: the daemon host is this host).
    let shared = work / "shared"
    proc remote(argv: seq[string]): (int, JsonNode) =
      var lines: seq[string]
      let code = client.execStream(@["crud"] & withState(argv, shared),
        proc(ev: ExecEvent) =
          if ev.kind == ekLog: lines.add(ev.line))
      (code, parseJson(lines[^1]))
    proc local(argv: seq[string]): (int, JsonNode) =
      let r = runLocal(@["crud"] & withState(argv, shared))
      (r.code, parseJson(r.stdout.strip()))

    # created locally …
    check local(@["create_vm", "m1", "--backend", "mock"])[0] == 0
    # … seen identically by both paths (byte-identical envelope + code)
    let got = checkParity(@["get_vm", "m1", "--backend", "mock"], 0,
                          sharedDir = shared)
    check got["data"]["vm"]["state"].getStr == "running"
    # … driven over serve
    let (ec, ex) = remote(@["exec", "m1", "--backend", "mock", "--",
                            "echo", "hi"])
    check ec == 0
    check ex["data"]["stdout"].getStr == "mock-exec: echo hi\n"
    check remote(@["stop_vm", "m1", "--backend", "mock"])[0] == 0
    # … and the stop is visible locally
    let (gc, g) = local(@["get_vm", "m1", "--backend", "mock"])
    check gc == 0
    check g["data"]["vm"]["state"].getStr == "stopped"
    # created over serve, deleted locally, gone for serve
    check remote(@["create_vm", "m2", "--backend", "mock"])[0] == 0
    check local(@["list_vms", "--backend", "mock"])[1]["data"]["vms"].len == 2
    check local(@["delete_vm", "m2", "--backend", "mock"])[0] == 0
    check remote(@["get_vm", "m2", "--backend", "mock"])[0] == 3

  client.shutdown()
  discard daemon.waitForExit(timeout = 5000)
  if daemon.running:
    daemon.terminate()
  daemon.close()
  removeDir(work)
