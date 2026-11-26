# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_pool_class_queue_wait — a pool that holds a job of a reserved class
## waiting 90 s shows it in ``runquota pressure --json`` as a ``class-queue``
## wait of that class.
##
## A host may reserve capacity for a class of work, and whether the
## reservation is large enough is judged by how long the class's jobs wait
## for a slot. gosti's pools hold their jobs from ``submit`` until
## ``acquireFor`` gives them a slot, and with ``PoolConfig.runquotaClass``
## report each wait to the host's RunQuota daemon, which publishes it per
## class beside build-wait pressure.
##
## No mocks on the RunQuota side: the "host daemon" is a private
## ``runquotad`` this test starts on a socket in a fresh ``0700`` directory
## it owns, with a host file that reserves capacity for class ``ci``; the
## pool's reporting session is the real ``runquota`` client
## (``runquota pressure report``), and the figures are read back through the
## real ``runquota pressure --json``. The reporting session connects on the
## class's own socket (``class-ci.sock``, which the private daemon creates
## owner-only beside its endpoint), because a class is claimed only there.
## The pool's VMs come from gosti's mock
## backend: what is under test is the pool's queue and its report, not a
## hypervisor, and a booted VM would add minutes and nothing to it.
##
## The wait is REAL (90 s of wall time, as the requirement states it): the
## daemon trusts no client-sent wait longer than the reporting session has
## existed, so a wait cannot be injected without a session that old.
##
## Falsifying mutations, each observed to fail this test: the pool not
## reporting (``endWait`` skipping ``reportWait``); the daemon not counting
## a report in its session's class (``classFiguresFor`` returning nil).
##
## Prerequisite, a printed SKIP when absent (a skip is not a pass):
## ``GOSTI_RUNQUOTA_BIN_DIR`` naming a directory with ``runquota`` and
## ``runquotad`` built for this host. Only processes this test starts are
## stopped.
##
## Run: GOSTI_RUNQUOTA_BIN_DIR=<runquota>/build/bin \
##        nim r --hints:off tests/e2e/t_pool_class_queue_wait.nim

import std/[json, os, osproc, posix, streams, strtabs, strutils, tempfiles,
            unittest]
import gosti

const
  WaitSeconds = 90
  Class = "ci"

let binDir = getEnv("GOSTI_RUNQUOTA_BIN_DIR")

proc skip(reason: string) =
  echo "[skip] t_pool_class_queue_wait: " & reason
  quit(0)

when not defined(posix):
  skip("a POSIX host is required (private RunQuota endpoint)")

if binDir.len == 0 or not fileExists(binDir / "runquota") or
    not fileExists(binDir / "runquotad"):
  skip("GOSTI_RUNQUOTA_BIN_DIR must name a directory holding runquota and " &
    "runquotad")

var daemon: Process

proc stopDaemon() =
  if not daemon.isNil:
    if daemon.running():
      daemon.terminate()
      discard daemon.waitForExit(10_000)
    if daemon.running():
      daemon.kill()
      discard daemon.waitForExit(10_000)
    daemon.close()
    daemon = nil

let root = createTempDir("rqvm-pool-", "")
setFilePermissions(root, {fpUserRead, fpUserWrite, fpUserExec})
let socket = root / "rq.sock"

proc isSocket(path: string): bool =
  var info: Stat
  lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

proc cleanup() {.noconv.} =
  stopDaemon()
  removeDir(root)

setControlCHook(cleanup)

proc clientEnv(): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): result[k] = v
  for k in ["RUNQUOTA_SOCKET", "RUNQUOTA_ENDPOINT_OWNER_UID",
            "RUNQUOTA_ENDPOINT_GROUP", "RUNQUOTA_SESSION", "RUNQUOTA_CLASS",
            "RUNQUOTA_EXIT_WITH_PARENT", "LISTEN_PID", "LISTEN_FDS"]:
    result.del(k)
  result["RUNQUOTA_ENDPOINT_SCOPE"] = "private"
  result["RUNQUOTA_SOCKET"] = socket

suite "pool class-queue waits":
  setup:
    writeFile(root / "host.toml", "schema = \"runquota.host-config.v1\"\n" &
      "[reservation." & Class & "]\ncpu-milli = 1000\n")
    daemon = startProcess(binDir / "runquotad", args = @["--socket", socket,
      "--host-config", root / "host.toml",
      "--host-identity-file", root / "host-id",
      "--estimate-db", root / "est.sqlite",
      "--no-write-stats",
      "--ambient-sample-interval-millis", "0",
      "--memory-pressure-source", "unavailable",
      "--cpu-pressure-file", root / "cpu-pressure",
      "--cpu-milli", "2000", "--memory-bytes", $(2'i64 * 1024 * 1024 * 1024)],
      env = clientEnv(), options = {poStdErrToStdOut})
    var waited = 0
    while not isSocket(socket) and daemon.running() and waited < 30_000:
      sleep(50)
      waited += 50
    if not isSocket(socket):
      let said =
        if daemon.running(): "still running"
        else: daemon.outputStream.readAll()
      doAssert false, "the private runquotad did not start: " & said
    # The pool's reporting session reaches this daemon, as every RunQuota
    # client finds its daemon.
    putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
    putEnv("RUNQUOTA_SOCKET", socket)
    delEnv("RUNQUOTA_SESSION")
    delEnv("RUNQUOTA_CLASS")

  teardown:
    stopDaemon()

  test "the reporter claims its class on the class's own socket":
    # The private daemon gives the declared class an owner-only socket
    # beside its endpoint, and the reporting session is served there. A
    # class the host does not declare has no socket: the reporter is
    # refused, with the client's reason, and the pool would serve its jobs
    # unreported. Mutation: a reporter that reached the shared socket with
    # the class would be refused there too, naming the class socket.
    check isSocket(root / ("class-" & Class & ".sock"))
    let reporter = startClassQueueReporter(@[binDir / "runquota"], Class)
    check not reporter.isNil and not reporter.lost
    reporter.close()
    var refusal = ""
    try:
      discard startClassQueueReporter(@[binDir / "runquota"], "undeclared")
    except ClassQueueError as e:
      refusal = e.msg
    checkpoint refusal
    check "declares no class undeclared" in refusal

  test "a job of a reserved class waiting 90 s is a class-queue wait":
    let backend = newMockBackend()
    backend.provisionBaseline(BaselineSpec(name: "golden"))
    var p = newPool(PoolConfig(backend: backend, baseline: "golden",
      algorithm: paRecycleFromPool, size: 1, runquotaClass: Class,
      runquotaCmd: @[binDir / "runquota"]))
    p.construct()
    defer: p.teardown()
    check not p.reporter.isNil and not p.reporter.lost
    # The only member is busy with another job; the next job waits for it.
    let busy = p.acquire()
    let job = p.submit("job-1")
    check p.waiting.len == 1
    sleep(WaitSeconds * 1000)
    check p.oldestWaitMillis() >= WaitSeconds * 1000
    check "waiting=1" in p.describe()
    p.release(busy)
    let lease = p.acquireFor(job)
    check not lease.isNil
    check p.waiting.len == 0
    check job.waitedMillis >= WaitSeconds * 1000
    check job.reported
    let (output, code) = execCmdEx(quoteShellCommand(
      @[binDir / "runquota", "pressure", "--json"]))
    check code == 0
    let answer = parseJson(output.strip().splitLines()[^1])
    var found = false
    for class in answer["classes"]:
      if class["name"].getStr() != Class:
        continue
      found = true
      check class["configured"].getBool()
      let waits = class["waits"]["class-queue"]
      check waits["count"].getInt() == 1
      check waits["sum_millis"].getBiggestInt() >= WaitSeconds * 1000
      check waits["sum_millis"].getBiggestInt() < (WaitSeconds + 30) * 1000
      # In the 120 s bucket and not in the 60 s one.
      for bucket in waits["buckets"]:
        let le = bucket["le_seconds"]
        if le.kind == JInt and le.getInt() == 60:
          check bucket["count"].getInt() == 0
        if le.kind == JInt and le.getInt() == 120:
          check bucket["count"].getInt() == 1
      # Nothing was reported as another kind.
      check class["waits"]["queue"]["count"].getInt() == 0
    check found
    if not found:
      echo output
    p.release(lease)

cleanup()
