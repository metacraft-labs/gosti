# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_gosti_serve_exec_policy — the ``gosti serve`` bearer token runs only what
## its clients send (SEC-1 G13), end to end through ``POST /v1/exec``.
##
## A real daemon, the real CLI as its worker, real TCP + HTTP + bearer auth.
## The worker role records every argv it is started with, so "refused before
## any worker is spawned" is observed, not assumed:
##
##   * allowed provider and crud argvs still run and stream an ``exit``;
##   * a disallowed subcommand, each bypass spelling, ``--mount /:/host:rw,
##     shift`` and a caller ``--user-data /etc/shadow`` are answered ``403``
##     with a reason, and the worker log does not grow;
##   * wire ``userData`` still arrives, staged by the daemon at a path it
##     chose, ahead of the guest argv's ``--``;
##   * with the operator's allowlists set (``ServeConfig.allowImageRoots`` /
##     ``allowIncusProfiles``, i.e. ``serve --allow-image-root`` /
##     ``--allow-incus-profile``), a golden image outside the roots, a
##     device, a link out of a root and a profile off the list are ``403``
##     with no worker (with the Windows branch's own reasons where the
##     policy refuses there for a different cause: any link, and POSIX-only
##     paths that do not exist); an image under the root and a listed
##     profile run;
##   * ``gosti --remote`` surfaces the refusal as a failing exit.
##
## The pure policy, including the parser-agreement property, is
## ``tests/unit/t_serve_exec_policy.nim``. Hermetic (noop / mock backends;
## every state directory is under the test's temp dir).

import std/[json, net, os, osproc, strutils, tempfiles, times, unittest]
import gosti
import gosti/cli
import ../disk_image_fixtures

const SpawnLogEnv = "GOSTI_TEST_SPAWN_LOG"

when isMainModule:
  let params = commandLineParams()
  if params.len >= 1 and params[0] == "__gosti_cli":
    # Record the spawn BEFORE doing anything else, so a worker that was
    # started at all is visible even if it then fails.
    let log = getEnv(SpawnLogEnv)
    if log.len > 0:
      let f = open(log, fmAppend)
      f.writeLine($(%params[1 .. ^1]))
      f.close()
    quit(runCli(params[1 .. ^1]))
  elif params.len >= 6 and params[0] == "__serve":
    runServe(ServeConfig(
      listenHost: params[1],
      listenPort: parseInt(params[2]),
      token: readFile(params[3]).strip(),
      workerExe: getAppFilename(),
      workerArgPrefix: @["__gosti_cli"],
      portFile: params[4],
      quiet: true,
      # The operator's allowlists, as `gosti serve --allow-image-root
      # <params[5]> --allow-incus-profile default --allow-incus-profile
      # ci-store` sets them.
      allowImageRoots: @[params[5]],
      allowIncusProfiles: @["default", "ci-store"]))
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
  status: int
  body: string          ## non-200 response body
  lines: seq[string]    ## ``log`` lines
  errors: seq[string]   ## ``error`` events
  code: int             ## ``exit`` code; -1 when none

proc post(port: int, token: string, argv: seq[string],
          userData = ""): Reply =
  ## A raw ``POST /v1/exec``, so the HTTP status itself is asserted.
  result.code = -1
  var sock = newSocket()
  defer: sock.close()
  sock.connect("127.0.0.1", Port(port))
  let body = $toJson(ExecRequest(v: ProtocolVersion, argv: argv,
                                 userData: userData))
  sock.sendRequest("POST", PathExec, "127.0.0.1:" & $port,
                   @[("Authorization", AuthScheme & token),
                     ("Content-Type", "application/json")], body)
  let head = sock.readResponseHead()
  result.status = head.status
  if head.status != 200:
    result.body = sock.readBodyByLength(head.headers)
    return
  for chunk in sock.readChunks():
    for raw in chunk.splitLines():
      let line = raw.strip()
      if line.len == 0: continue
      let ev = parseEvent(line)
      case ev.kind
      of ekLog: result.lines.add(ev.line)
      of ekError: result.errors.add(ev.message)
      of ekExit: result.code = ev.code

proc spawned(log: string): seq[seq[string]] =
  if not fileExists(log): return
  for line in readFile(log).splitLines():
    if line.len > 0:
      var argv: seq[string]
      for a in parseJson(line): argv.add(a.getStr)
      result.add(argv)

suite "t_gosti_serve_exec_policy":
  let work = createTempDir("gosti-serve-policy-", "")
  let tokenFile = work / "token"
  let portFile = work / "port"
  let spawnLog = work / "spawned.jsonl"
  let token = "serve-policy-bearer-3e9a"
  writeFile(tokenFile, token)
  # The daemon's workers inherit these: every store lives under ``work``.
  putEnv(SpawnLogEnv, spawnLog)
  putEnv("GOSTI_CRUD_STATE_DIR", work / "crud")
  putEnv("GOSTI_EPHEMERAL_STATE_DIR", work / "ephemeral")
  # The image root, a golden in it, and goldens the caller may NOT name.
  let imgRoot = work / "images"
  let elsewhere = work / "elsewhere"
  createDir(imgRoot)
  createDir(elsewhere)
  let golden = imgRoot / "golden.qcow2"
  writeQcow2(golden)
  let otherGolden = elsewhere / "other-lane.qcow2"
  writeQcow2(otherGolden)
  # Under the root, format-valid, but its backing file is the token: QEMU
  # would serve the token's bytes as the guest's disk.
  let backedByToken = imgRoot / "backed-by-token.qcow2"
  writeQcow2(backedByToken, backing = tokenFile, backingFmt = "raw")
  let linkOut = imgRoot / "escape.qcow2"
  createSymlink(otherGolden, linkOut)
  let daemon = startProcess(getAppFilename(),
    args = @["__serve", "127.0.0.1", "0", tokenFile, portFile, imgRoot],
    options = {poParentStreams})
  let port = waitForPort(portFile)

  proc checkRefused(argv: seq[string], fragment: string): bool =
    ## 403 with the policy's reason, and NO worker process started.
    let before = spawned(spawnLog).len
    let r = post(port, token, argv)
    result = true
    if r.status != 403:
      echo "  ", argv, ": status ", r.status, " (want 403)"
      result = false
    elif "exec refused by serve policy" notin r.body or fragment notin r.body:
      echo "  ", argv, ": body ", r.body, " lacks '", fragment, "'"
      result = false
    if r.code != -1:
      echo "  ", argv, ": an exit event was streamed"
      result = false
    let after = spawned(spawnLog).len
    if after != before:
      echo "  ", argv, ": a worker was spawned (", before, " -> ", after, ")"
      result = false

  test "allowed provider argvs still run through the handler":
    let before = spawned(spawnLog).len
    let prov = post(port, token, @["provision", "--backend", "noop",
                                   "--baseline", "garm-p1", "--log-format",
                                   "json"])
    check prov.status == 200
    check prov.errors.len == 0
    check prov.code == 0
    let destroy = post(port, token, @["ephemeral-destroy", "--backend", "noop",
                                      "--baseline", "garm-p1",
                                      "--log-format", "json"])
    check destroy.status == 200
    check destroy.code == 0
    let runs = spawned(spawnLog)
    check runs.len == before + 2
    if runs.len == before + 2:
      check runs[before][0] == "provision"
      check runs[before + 1][0] == "ephemeral-destroy"

  test "an allowed crud verb still runs and returns its envelope":
    let r = post(port, token, @["crud", "list_vms", "--backend", "mock"])
    check r.status == 200
    check r.code == 0
    check r.lines.len == 1
    if r.lines.len == 1:
      check parseJson(r.lines[0])["ok"].getBool

  test "a disallowed subcommand is refused and spawns no worker":
    check checkRefused(@["serve", "--listen", "0.0.0.0:0"], "subcommand 'serve'")
    check checkRefused(@["probe"], "subcommand 'probe'")
    check checkRefused(@["prune", "--backend", "noop", "--force"],
                       "subcommand 'prune'")
    check checkRefused(@["run", "--backend", "noop", "--baseline", "rt",
      "--output-dir", work / "outdir", "--", "/bin/echo", "hi"],
      "'--output-dir' is not allowed")
    check not dirExists(work / "outdir")

  test "bypass spellings are refused and spawn no worker":
    # Global options before the subcommand.
    check checkRefused(@["--backend", "noop", "provision"], "subcommand")
    # ``--`` tricks: as the subcommand, and hiding a crud verb.
    check checkRefused(@["--", "provision", "--backend", "noop"], "subcommand")
    check checkRefused(@["crud", "--backend", "mock", "--", "copy_to_vm",
      "vm1", "/etc/shadow", "/x"], "crud verb 'copy_to_vm'")
    # ``=``-joined option.
    check checkRefused(@["crud", "create_vm", "x", "--backend", "incus",
      "--mount=/:/host:rw,shift"], "is not allowed")
    # Duplicated subcommand.
    check checkRefused(@["crud", "crud", "create_vm", "x"], "crud verb 'crud'")
    check checkRefused(@["provision", "provision", "--backend", "noop"],
                       "no positional")
    # Repeated flag smuggling a second backend.
    check checkRefused(@["provision", "--backend", "noop", "--backend",
                         "libvirt"], "limited to --backend noop")
    # Case / whitespace variants.
    check checkRefused(@["RUN", "--ephemeral"], "subcommand 'RUN'")
    check checkRefused(@[" crud", "list_vms"], "subcommand ' crud'")
    # The worker would lift --remote out of ANY position and read the token
    # file it names; refused even after ``--``.
    check checkRefused(@["ephemeral-list", "--backend", "noop", "--",
      "--remote", "127.0.0.1:1", "--auth-token-file", "/etc/shadow"],
      "client-only")
    # A path-shaped instance name (libvirt builds <pool>/<name>.overlay.qcow2
    # from it), the wsl backend (not an isolation boundary from its host),
    # an implicit auto backend, a '--' hidden as a value, and a NUL byte.
    check checkRefused(@["ephemeral-destroy", "--backend", "libvirt",
      "--baseline", "../../etc/x"], "not a plain name")
    check checkRefused(@["crud", "create_vm", "w1", "--backend", "wsl"],
                       "'wsl' is not allowed")
    check checkRefused(@["crud", "list_vms", "--guest", "linux"],
                       "--backend is required")
    check checkRefused(@["run", "--ephemeral", "--backend", "incus",
      "--baseline", "j", "--source-image", "--", "--", "true"],
      "may not take '--'")
    check checkRefused(@["ephemeral-list", "--backend", "noop\0x"], "NUL")

  test "--mount /:/host:rw,shift is refused via serve":
    check checkRefused(@["crud", "create_vm", "rootgrab", "--backend",
      "incus", "--source-image", "deb12", "--mount", "/:/host:rw,shift"],
      "'--mount' is not allowed")

  test "a caller --user-data host path is refused and never read":
    check checkRefused(@["crud", "create_vm", "leak", "--backend", "libvirt",
      "--user-data", "/etc/shadow"], "'--user-data' is not allowed")
    check checkRefused(@["run", "--ephemeral", "--backend", "incus",
      "--baseline", "leak", "--user-data", "/etc/shadow", "--keep"],
      "'--user-data' is not allowed")

  test "wire userData is staged by the daemon, ahead of the guest argv":
    let before = spawned(spawnLog).len
    let r = post(port, token, @["crud", "exec", "nope", "--backend", "mock",
                                "--", "echo", "hi"], userData = "#cloud-config\n")
    check r.status == 200
    check r.code == 3                   # not-found: the VM does not exist
    let runs = spawned(spawnLog)
    check runs.len == before + 1
    if runs.len == before + 1:
      let argv = runs[^1]
      let ud = argv.find("--user-data")
      let dd = argv.find("--")
      check ud > 0
      check dd > ud
      if ud > 0:
        let staged = argv[ud + 1]
        check staged.startsWith(getTempDir() / "gosti-serve" / "userdata")
        check not fileExists(staged)    # removed once the worker exited
      check argv[dd + 1 .. ^1] == @["echo", "hi"]

  test "a golden image outside the image roots is refused, no worker":
    # Each input is refused on every host; the REASON is per platform where
    # ``hostPathReason``'s Windows branch differs: it refuses any link on the
    # way instead of resolving it, and ``/dev/zero`` and ``/proc`` do not
    # exist there, so those POSIX-only paths do not resolve at all.
    const
      winMissing = "does not resolve to an existing file"
      linkReason = when defined(windows): "passes through a link"
                   else: "outside the image roots"
      deviceReason = when defined(windows): winMissing
                     else: "not a regular file"
      procReason = when defined(windows): winMissing
                   else: "resolves through /proc"
    check checkRefused(@["run", "--ephemeral", "--backend", "libvirt",
      "--baseline", "garm-img1", "--base-image", otherGolden, "--source-image",
      otherGolden, "--keep", "--log-format", "json"],
      "outside the image roots")
    check checkRefused(@["run", "--ephemeral", "--backend", "libvirt",
      "--baseline", "garm-img1", "--source-image", linkOut, "--keep"],
      linkReason)
    check checkRefused(@["run", "--ephemeral", "--backend", "libvirt",
      "--baseline", "garm-img1", "--source-image",
      imgRoot & "/../elsewhere/other-lane.qcow2", "--keep"],
      "has a '..' component")
    check checkRefused(@["crud", "create_vm", "img1", "--backend", "mock",
      "--source-image", "/dev/zero"], deviceReason)
    check checkRefused(@["crud", "create_vm", "img1", "--backend", "mock",
      "--source-image", tokenFile], "outside the image roots")
    check checkRefused(@["run", "--ephemeral", "--backend", "incus",
      "--baseline", "garm-img1", "--base-image", "/etc/shadow", "--keep"],
      "is not an image name")
    check checkRefused(@["run", "--ephemeral", "--backend", "libvirt",
      "--baseline", "garm-img1", "--source-image", backedByToken, "--keep"],
      "'raw' backing file")
    check checkRefused(@["run", "--ephemeral", "--backend", "libvirt",
      "--baseline", "garm-img1", "--source-image", "/proc/self/root" & golden,
      "--keep"], procReason)

  test "an Incus profile off the allowlist is refused, no worker":
    check checkRefused(@["run", "--ephemeral", "--backend", "incus",
      "--baseline", "garm-prof1", "--base-image", "runner-base",
      "--incus-profile", "default", "--incus-profile", "privileged",
      "--keep", "--log-format", "json"], "'privileged' is not allowed")

  test "an image under the root and a listed profile are admitted":
    let before = spawned(spawnLog).len
    let create = post(port, token, @["crud", "create_vm", "img-ok",
      "--backend", "mock", "--source-image", golden])
    check create.status == 200
    check create.code == 0
    check create.lines.len == 1
    if create.lines.len == 1:
      check parseJson(create.lines[0])["ok"].getBool
    let del = post(port, token, @["crud", "delete_vm", "img-ok", "--backend",
                                  "mock", "--force"])
    check del.status == 200
    check del.code == 0
    # A listed profile passes the policy and reaches the worker, which then
    # refuses it itself (Incus options need --backend incus), so the test
    # touches no Incus daemon and creates nothing.
    let prof = post(port, token, @["run", "--ephemeral", "--backend", "noop",
      "--incus-profile", "default", "--incus-profile", "ci-store", "--keep",
      "--log-format", "json"])
    check prof.status == 200
    check prof.code != 0
    let runs = spawned(spawnLog)
    check runs.len == before + 3
    if runs.len == before + 3:
      check golden in runs[before]
      check "ci-store" in runs[before + 2]

  test "gosti --remote reports the refusal as a failing exit":
    check runCli(@["--remote", "127.0.0.1:" & $port, "--auth-token-file",
                   tokenFile, "probe"]) != 0

  test "graceful shutdown stops the daemon":
    newServeClient("127.0.0.1:" & $port, token).shutdown()
    check daemon.waitForExit(timeout = 5000) == 0

  if daemon.running:
    daemon.terminate()
    discard daemon.waitForExit(timeout = 3000)
  daemon.close()
  removeDir(work)
