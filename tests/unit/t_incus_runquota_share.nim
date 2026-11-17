# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## The Incus provider's host-RunQuota capability (``shareHostRunQuota``):
## the proxy device it adds, the credentials it gives the forwarder, the
## session group it hands the guest, and the order of the create.
##
## Mock justification: a native copy of this test stands in for the Incus
## executable and records its exact argv, so the device configuration and
## the order of every call can be asserted without an Incus daemon. The
## backend, the environment, the filesystem and the subprocess boundary are
## real. The same capability against real Incus and a real ``runquotad`` is
## ``tests/e2e/t_incus_runquota_host_budget.nim``.

import std/[json, os, posix, strutils, tempfiles, unittest]
import gosti
import gosti/cli

const IncusFixtureName = "incus-fixture"

if getAppFilename().extractFilename == IncusFixtureName:
  let cfg = parseFile(getAppFilename() & ".json")
  let command = commandLineParams().join(" ")
  let log = open(cfg["log"].getStr(), fmAppend)
  log.writeLine(command)
  log.close()
  if cfg["fail"].getStr().len > 0 and command.startsWith(cfg["fail"].getStr()):
    quit(17)
  if command.startsWith("info "):
    quit(1)
  quit(0)

proc writeIncusShim(path, logPath: string; failPrefix = "") =
  copyFileWithPermissions(getAppFilename(), path)
  writeFile(path & ".json", $(%*{"log": logPath, "fail": failPrefix}))

proc lineIndex(lines: seq[string], wanted: string): int =
  for i, line in lines:
    if line == wanted:
      return i
  -1

template withEnv(key, value: string; body: untyped) =
  let hadIt = existsEnv(key)
  let previous = getEnv(key)
  if value.len > 0: putEnv(key, value) else: delEnv(key)
  try:
    body
  finally:
    if hadIt: putEnv(key, previous) else: delEnv(key)

proc newShimBackend(work: string; failPrefix = ""): (IncusBackend, string) =
  let logPath = work / "argv.log"
  let shim = work / IncusFixtureName
  writeIncusShim(shim, logPath, failPrefix)
  (newIncusBackend(incusCmd = @[shim], baseImage = "runner-base"), logPath)

proc expectedProxy(container, endpoint: string): string =
  let creds = hostRunQuotaCredentials(endpoint)
  "config device add " & container & " runquota proxy connect=unix:" &
    endpoint & " listen=unix:/run/runquota/runquotad.sock bind=container " &
    "uid=0 gid=0 mode=0600 security.uid=" & $creds.uid & " security.gid=" &
    $creds.gid

suite "host RunQuota in an Incus container: device and credentials":
  test "the proxy device listens in the guest and connects as the given ids":
    check runquotaProxyDeviceArgs("c1", "/run/runquota/runquotad.sock",
                                  1000, 953) == @[
      "config", "device", "add", "c1", "runquota", "proxy",
      "connect=unix:/run/runquota/runquotad.sock",
      "listen=unix:/run/runquota/runquotad.sock",
      "bind=container", "uid=0", "gid=0", "mode=0600",
      "security.uid=1000", "security.gid=953"]

  test "the forwarder's gid is the rendezvous group only when the caller holds it":
    # A provisioned host: the directory's group is `runquota`, the caller a
    # member -> that group, since the forwarder holds no supplementary groups.
    check runquotaProxyGid(953, 1000, [1000'i64, 953, 998]) == 953
    # The caller's own primary group owns it.
    check runquotaProxyGid(1000, 1000, [998'i64]) == 1000
    # Not a member: never a group the caller does not hold.
    check runquotaProxyGid(953, 1000, [1000'i64, 998]) == 1000
    # The directory could not be inspected.
    check runquotaProxyGid(-1, 1000, [953'i64]) == 1000

  test "the forwarder runs as this process, never a caller-chosen uid":
    let creds = hostRunQuotaCredentials("/nonexistent-dir/runquotad.sock")
    check creds.uid == int64(geteuid())
    check creds.gid == int64(getegid())

  test "the host endpoint is RUNQUOTA_SOCKET, else the provisioned path":
    withEnv("RUNQUOTA_SOCKET", ""):
      check hostRunQuotaEndpoint() == "/run/runquota/runquotad.sock"
    withEnv("RUNQUOTA_SOCKET", "/tmp/x/d.sock"):
      check hostRunQuotaEndpoint() == "/tmp/x/d.sock"

  test "a session group follows RunQuota's naming rule":
    check runquotaSessionProblem("") == ""
    check runquotaSessionProblem("ci-job-42") == ""
    check runquotaSessionProblem('a'.repeat(128)) == ""
    check runquotaSessionProblem('a'.repeat(129)).len > 0
    check runquotaSessionProblem("bad\nname").len > 0
    check runquotaSessionProblem("bad\x7fname").len > 0

  test "the group is the spec's, else the creating process's session":
    withEnv("RUNQUOTA_SESSION", "agent-7"):
      check effectiveRunQuotaSession(EphemeralIncusSpec(
        shareHostRunQuota: true)) == "agent-7"
      check effectiveRunQuotaSession(EphemeralIncusSpec(
        shareHostRunQuota: true, runquotaSession: "job-9")) == "job-9"
    withEnv("RUNQUOTA_SESSION", ""):
      check effectiveRunQuotaSession(EphemeralIncusSpec(
        shareHostRunQuota: true)) == ""

suite "host RunQuota in an Incus container: the create":
  test "session before first start, device after it, then the socket is proved":
    let work = createTempDir("gosti-incus-rq", "")
    defer: removeDir(work)
    let (b, logPath) = newShimBackend(work)
    withEnv("RUNQUOTA_SOCKET", "/tmp/rq-host/d.sock"):
      withEnv("RUNQUOTA_SESSION", "agent-session-1"):
        discard b.provisionEphemeralClone(EphemeralIncusSpec(
          name: "rq", shareHostRunQuota: true))
    let lines = readFile(logPath).strip().splitLines()
    let initPos = lines.lineIndex("init runner-base rq")
    let envPos = lines.lineIndex(
      "config set rq environment.RUNQUOTA_SESSION agent-session-1")
    let startPos = lines.lineIndex("start rq")
    let readyPos = lines.lineIndex("exec rq -- true")
    let dirPos = lines.lineIndex("exec rq -- sh -c mkdir -p \"$1\" && " &
      "chown 0:0 \"$1\" && chmod 0700 \"$1\" gosti-runquota-dir /run/runquota")
    let devicePos = lines.lineIndex(expectedProxy("rq", "/tmp/rq-host/d.sock"))
    let probePos = lines.lineIndex(
      "exec rq -- test -S /run/runquota/runquotad.sock")
    checkpoint(lines.join("\n"))
    check initPos >= 0
    check initPos < envPos
    check envPos < startPos
    check startPos < readyPos
    check readyPos < dirPos
    check dirPos < devicePos
    check devicePos < probePos
    check lines.join("\n").find("launch runner-base rq") < 0

  test "an explicit group wins over the creating process's":
    let work = createTempDir("gosti-incus-rq-group", "")
    defer: removeDir(work)
    let (b, logPath) = newShimBackend(work)
    withEnv("RUNQUOTA_SOCKET", ""):
      withEnv("RUNQUOTA_SESSION", "agent-session-1"):
        discard b.provisionEphemeralClone(EphemeralIncusSpec(
          name: "rqg", shareHostRunQuota: true, runquotaSession: "ci-job-42"))
    let joined = readFile(logPath)
    check "config set rqg environment.RUNQUOTA_SESSION ci-job-42" in joined
    check "agent-session-1" notin joined
    check expectedProxy("rqg", "/run/runquota/runquotad.sock") in joined

  test "no session anywhere sets no group key":
    let work = createTempDir("gosti-incus-rq-nogroup", "")
    defer: removeDir(work)
    let (b, logPath) = newShimBackend(work)
    withEnv("RUNQUOTA_SESSION", ""):
      discard b.provisionEphemeralClone(EphemeralIncusSpec(
        name: "rqn", shareHostRunQuota: true))
    let joined = readFile(logPath)
    check "RUNQUOTA_SESSION" notin joined
    check "config device add rqn runquota proxy" in joined

  test "the default create never adds the device":
    let work = createTempDir("gosti-incus-rq-off", "")
    defer: removeDir(work)
    let (b, logPath) = newShimBackend(work)
    withEnv("RUNQUOTA_SESSION", "agent-session-1"):
      discard b.provisionEphemeralClone(EphemeralIncusSpec(name: "plain"))
    check readFile(logPath).strip().splitLines() == @[
      "info plain", "launch runner-base plain"]

  test "a session without the capability is refused before anything is made":
    let work = createTempDir("gosti-incus-rq-bad", "")
    defer: removeDir(work)
    let (b, logPath) = newShimBackend(work)
    expect InvalidSpecError:
      discard b.provisionEphemeralClone(EphemeralIncusSpec(
        name: "rqb", runquotaSession: "job"))
    check readFile(logPath).strip().splitLines() == @["info rqb"]

  test "an unusable group or endpoint is refused before anything is made":
    let work = createTempDir("gosti-incus-rq-bad2", "")
    defer: removeDir(work)
    let (b, logPath) = newShimBackend(work)
    withEnv("RUNQUOTA_SESSION", "bad\x01group"):
      expect InvalidSpecError:
        discard b.provisionEphemeralClone(EphemeralIncusSpec(
          name: "rqc", shareHostRunQuota: true))
    withEnv("RUNQUOTA_SOCKET", "relative/d.sock"):
      expect InvalidSpecError:
        discard b.provisionEphemeralClone(EphemeralIncusSpec(
          name: "rqd", shareHostRunQuota: true))
    check readFile(logPath).strip().splitLines() == @["info rqc", "info rqd"]

  test "a device that cannot be added removes the container":
    let work = createTempDir("gosti-incus-rq-fail", "")
    defer: removeDir(work)
    let (b, logPath) = newShimBackend(work,
      failPrefix = "config device add rqf runquota proxy")
    expect GostiError:
      discard b.provisionEphemeralClone(EphemeralIncusSpec(
        name: "rqf", shareHostRunQuota: true))
    let lines = readFile(logPath).strip().splitLines()
    check lines[^1] == "delete --force rqf"
    check lines.join("\n").find("test -S") < 0

suite "host RunQuota in an Incus container: the CLI":
  test "the flags reach the spec only for run --ephemeral --backend incus":
    let opts = parseCliOpts(@["run", "--ephemeral", "--backend", "incus",
      "--baseline", "c", "--incus-share-host-runquota",
      "--incus-runquota-session", "job-1"])
    check opts.incusShareHostRunQuota
    check opts.incusRunQuotaSession == "job-1"
    expect ValueError:
      discard parseCliOpts(@["run", "--ephemeral", "--backend", "noop",
        "--baseline", "c", "--incus-share-host-runquota"])
    expect ValueError:
      discard parseCliOpts(@["run", "--ephemeral", "--backend", "incus",
        "--baseline", "c", "--incus-runquota-session", "job-1"])
    expect ValueError:
      discard parseCliOpts(@["run", "--ephemeral", "--backend", "incus",
        "--baseline", "c", "--incus-share-host-runquota",
        "--incus-runquota-session", "bad\x01"])
