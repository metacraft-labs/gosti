# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_incus_runquota_host_budget — builds in an Incus container lease from the
## HOST's RunQuota daemon, so a container build and a host build that
## together ask for more than the host budget never run beyond it.
##
## Against REAL Incus and a REAL ``runquotad``, no mocks:
##
## * the "host daemon" is a private ``runquotad`` this test starts on a
##   socket in a fresh ``0700`` directory it owns (``RUNQUOTA_ENDPOINT_SCOPE=
##   private``), with a budget of 2 CPUs; the host's own daemon and its
##   rendezvous are never touched. The test points gosti at it the way any
##   RunQuota client is pointed at a daemon: ``RUNQUOTA_SOCKET`` in this
##   process's environment.
## * the container is created through gosti's Incus provider
##   (``provisionEphemeralClone`` with ``shareHostRunQuota``), which adds the
##   ``runquota`` proxy device that forwards the guest's standard rendezvous
##   (``/run/runquota/runquotad.sock``) to that socket. Besides the device,
##   the container gets read-only mounts of the RunQuota binaries and the
##   ``/nix/store`` paths they load, and one read-write mount of the test's
##   ledger directory. Nothing else of the host is shared.
## * four jobs of width 1 -- two on the host, two in the container, all
##   started together -- each run under ``runquota run --width 1`` and count
##   themselves in and out of a ledger under ``flock(1)``, which both sides
##   see through the shared mount. A job counts itself only while its
##   command runs, which is inside its lease, so the ledger's maximum is the
##   exact peak of concurrently running leased commands: no sampling, and no
##   slack. Together the jobs ask for 4 CPUs; the budget is 2, so the peak
##   must be exactly 2 (at most 2: the budget; at least 2: the jobs really
##   overlapped, so a run that serialised everything cannot pass).
##
## It also checks that the container's builds are attributed to the
## container's OWNER: while the jobs run, the daemon reports one session
## group, the session name this process carries in ``RUNQUOTA_SESSION``
## (gosti propagates it into the container), owned by this test's uid and
## holding more sessions than the host side opened.
##
## It then removes the device while a container job holds the whole budget,
## ending the forwarder mid-lease, and checks the daemon releases that lease
## (a host job gets the budget, and no lease is left) instead of holding it.
##
## Falsifying mutation: the container's builds lease from a
## daemon private to the container instead -- both daemons then admit 2, and
## the peak reaches 4.
##
## Prerequisites, each a printed SKIP when absent (a skip is not a pass):
## a Linux host; Incus reachable (``GOSTI_INCUS_CMD`` as for the other incus
## gates); ``GOSTI_RUNQUOTA_BIN_DIR`` naming a directory with ``runquota`` and
## ``runquotad`` built for this host; the image ``GOSTI_RUNQUOTA_INCUS_IMAGE``
## (default ``images:alpine/3.21``, ~3 MiB; it needs ``sh``, ``sleep`` and
## ``flock``, which busybox provides). Every Incus object is named
## ``rqtest-<pid>-…`` and deleted in a ``defer``; every process the test
## starts is recorded and only those are stopped.
##
## Run: GOSTI_RUNQUOTA_BIN_DIR=<runquota>/build/bin \
##        nim r --hints:off tests/e2e/t_incus_runquota_host_budget.nim

import std/[json, os, osproc, posix, sets, streams, strtabs, strutils, tables,
            tempfiles, times, unittest]
import gosti

when not defined(linux):
  echo "[skip] t_incus_runquota_host_budget: Linux host required"
  quit(0)

const
  BudgetCpus = 2
  JobsPerSide = 2
  JobSeconds = 3
  GuestBinDir = "/opt/rqtest/bin"
  GuestLedgerDir = "/rqtest/ledger"

let binDir = getEnv("GOSTI_RUNQUOTA_BIN_DIR")
let image = block:
  let e = getEnv("GOSTI_RUNQUOTA_INCUS_IMAGE")
  if e.len > 0: e else: "images:alpine/3.21"

proc skip(reason: string) =
  echo "[skip] t_incus_runquota_host_budget: " & reason
  quit(0)

if binDir.len == 0 or not fileExists(binDir / "runquota") or
    not fileExists(binDir / "runquotad"):
  skip("GOSTI_RUNQUOTA_BIN_DIR must name a directory holding runquota and " &
    "runquotad")

let incus = newIncusBackend(baseImage = image)
if not incus.probeAvailability():
  skip("Incus is not reachable")

# ---------------------------------------------------------------------------
# Processes this test starts: recorded at spawn, and only these are stopped.

var started: seq[Process] = @[]

proc spawn(exe: string; args: seq[string]; env: StringTableRef = nil): Process =
  result = startProcess(exe, args = args, env = env,
                        options = {poStdErrToStdOut})
  result.inputStream.close()
  started.add(result)

proc stopStarted() =
  for p in started:
    if p.running():
      p.terminate()
      discard p.waitForExit(5000)
      if p.running():
        p.kill()
        discard p.waitForExit(5000)
    p.close()
  started.setLen(0)

proc finish(p: Process): tuple[code: int, output: string] =
  let output = p.outputStream.readAll()
  (p.waitForExit(), output)

# ---------------------------------------------------------------------------
# The binaries' runtime closure, mounted read-only at the same paths.

proc storeRoots(binary: string): seq[string] =
  ## The ``/nix/store/<hash>-<name>`` directories ``binary`` loads from (its
  ## interpreter and libraries), from ``ldd`` with no preload in force.
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k != "LD_PRELOAD": env[k] = v
  let p = startProcess("ldd", args = @[binary], env = env,
                       options = {poUsePath, poStdErrToStdOut})
  let (code, output) = p.finish()
  p.close()
  doAssert code == 0, "ldd " & binary & " failed: " & output
  for token in output.splitWhitespace():
    if token.startsWith("/nix/store/"):
      let boundary = token.find('/', "/nix/store/".len)
      let root = if boundary < 0: token else: token[0 ..< boundary]
      if root notin result: result.add(root)

# ---------------------------------------------------------------------------
# The ledger: a job counts itself in and out under flock(1).

const JobScript = """#!/bin/sh
set -eu
d=$1
tag=$2
bump() {
  exec 9>>"$d/lock"
  flock -x 9
  read -r cur peak total < "$d/ledger"
  cur=$((cur + $1))
  if [ "$1" -gt 0 ]; then total=$((total + 1)); fi
  if [ "$cur" -gt "$peak" ]; then peak=$cur; fi
  printf '%s %s %s\n' "$cur" "$peak" "$total" > "$d/ledger"
  printf '%s %s %s\n' "$tag" "$1" "$cur" >> "$d/events"
  flock -u 9
  exec 9>&-
}
bump 1
sleep "$3"
bump -1
"""

proc readLedger(dir: string): tuple[current, peak, total: int] =
  let fields = readFile(dir / "ledger").splitWhitespace()
  doAssert fields.len == 3, "ledger is not three numbers: " & $fields
  (parseInt(fields[0]), parseInt(fields[1]), parseInt(fields[2]))

proc makeShared(path: string; mode: int) =
  ## Guest root is an unmapped host uid, so the ledger it writes to must be
  ## writable by others. Only the test's own scratch files get these modes.
  doAssert chmod(path.cstring, Mode(mode)) == 0, "chmod " & path

# ---------------------------------------------------------------------------

proc uniqueName(tag: string): string =
  "rqtest-" & $getCurrentProcessId() & "-" & tag

proc waitForSocket(path: string; daemon: Process): bool =
  let deadline = epochTime() + 20.0
  while epochTime() < deadline:
    var info: Stat
    if lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode):
      return true
    if not daemon.running(): return false
    sleep(50)
  false

suite "incus container builds lease from the host daemon":
  test "a container build counts against the host budget":
    # Short root: sun_path is 108 bytes.
    let root = createTempDir("rqhost-", "", "/tmp")
    defer: removeDir(root)
    doAssert chmod(root.cstring, Mode(0o700)) == 0
    let socket = root / "d.sock"
    let ledger = createTempDir("rqhost-ledger-", "", "/tmp")
    defer: removeDir(ledger)
    makeShared(ledger, 0o777)
    writeFile(ledger / "ledger", "0 0 0\n")
    writeFile(ledger / "lock", "")
    writeFile(ledger / "events", "")
    writeFile(ledger / "job.sh", JobScript)
    makeShared(ledger / "ledger", 0o666)
    makeShared(ledger / "lock", 0o666)
    makeShared(ledger / "events", 0o666)
    makeShared(ledger / "job.sh", 0o755)

    let group = uniqueName("session")
    var daemonEnv = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): daemonEnv[k] = v
    for k in ["RUNQUOTA_SOCKET", "RUNQUOTA_ENDPOINT_OWNER_UID",
              "RUNQUOTA_ENDPOINT_GROUP", "RUNQUOTA_SESSION",
              "RUNQUOTA_EXIT_WITH_PARENT", "LISTEN_PID", "LISTEN_FDS"]:
      daemonEnv.del(k)
    daemonEnv["RUNQUOTA_ENDPOINT_SCOPE"] = "private"
    defer: stopStarted()
    # Every file the daemon would otherwise reach for on the host is kept in
    # the test's own directory, and capture and ambient sampling are off:
    # the budget is the only input admission reads here.
    let daemon = spawn(binDir / "runquotad", @["--socket", socket,
      "--host-config", root / "host.toml",
      "--host-identity-file", root / "host-id",
      "--estimate-db", root / "est.sqlite",
      "--no-write-stats",
      "--ambient-sample-interval-millis", "0",
      "--memory-pressure-source", "unavailable",
      "--cpu-pressure-file", root / "cpu-pressure",
      "--cpu-milli", $(BudgetCpus * 1000), "--memory-bytes",
      $(16'i64 * 1024 * 1024 * 1024)], daemonEnv)
    require waitForSocket(socket, daemon)

    # Point gosti (and the host jobs) at the private daemon, and give this
    # process the session the container must join.
    var hostEnv = newStringTable(modeCaseSensitive)
    for k, v in daemonEnv: hostEnv[k] = v
    hostEnv["RUNQUOTA_SOCKET"] = socket
    hostEnv["RUNQUOTA_SESSION"] = group
    putEnv("RUNQUOTA_SOCKET", socket)
    putEnv("RUNQUOTA_SESSION", group)
    defer:
      delEnv("RUNQUOTA_SOCKET")
      delEnv("RUNQUOTA_SESSION")

    var mounts = @[
      IncusDiskMount(hostPath: binDir, guestPath: GuestBinDir, readOnly: true),
      IncusDiskMount(hostPath: ledger, guestPath: GuestLedgerDir)]
    var roots: seq[string] = @[]
    for exe in ["runquota", "runquotad"]:
      for r in storeRoots(binDir / exe):
        if r notin roots: roots.add(r)
    for r in roots:
      mounts.add(IncusDiskMount(hostPath: r, guestPath: r, readOnly: true))

    let name = uniqueName("share")
    let owner = uniqueName("owner")
    defer:
      if incus.containerExists(name):
        discard incus.deleteContainer(name)
    var vm: VmHandle
    try:
      vm = incus.provisionEphemeralClone(EphemeralIncusSpec(
        name: name, ephemeral: false, ownerToken: owner, mounts: mounts,
        shareHostRunQuota: true))
    except GostiError as e:
      if "Failed getting remote image info" in e.msg or
          "unable to resolve" in e.msg.toLowerAscii():
        skip("the image " & image & " cannot be resolved: " & e.msg)
      raise

    # The proxy device is the one gosti added, with the owner's credentials.
    let device = incus.runIncus(@["config", "device", "get", name,
      IncusRunQuotaDevice, "security.uid"], timeoutSec = 30)
    check device.exitCode == 0
    check device.stdout.strip() == $geteuid()
    let sessionKey = incus.runIncus(@["config", "get", name,
      IncusRunQuotaSessionKey], timeoutSec = 30)
    check sessionKey.stdout.strip() == group

    # ---- the jobs: all four started together ---------------------------
    var jobs: seq[(string, Process)] = @[]
    for i in 1 .. JobsPerSide:
      let tag = "host-" & $i
      jobs.add((tag, spawn(binDir / "runquota", @["run", "--verbose",
        "--width", "1", "--", "/bin/sh", ledger / "job.sh", ledger, tag,
        $JobSeconds], hostEnv)))
    for i in 1 .. JobsPerSide:
      let tag = "container-" & $i
      var argv = incus.incusCmd[1 .. ^1]
      argv.add(@["exec", name, "--", GuestBinDir / "runquota", "run",
        "--verbose", "--width", "1", "--", "/bin/sh",
        GuestLedgerDir / "job.sh", GuestLedgerDir, tag, $JobSeconds])
      jobs.add((tag, startProcess(incus.incusCmd[0], args = argv,
        options = {poUsePath, poStdErrToStdOut})))
      started.add(jobs[^1][1])

    # ---- while they run: who does the daemon say they belong to ---------
    var statusEnv = newStringTable(modeCaseSensitive)
    for k, v in hostEnv: statusEnv[k] = v
    statusEnv.del("RUNQUOTA_SESSION")
    var maxGroupSessions = 0
    var owners = initHashSet[int]()
    var foreignLeases = 0
    let watchUntil = epochTime() + float(JobSeconds * 2 + 10)
    while epochTime() < watchUntil:
      var allDone = true
      for (_, p) in jobs:
        if p.running(): allDone = false
      if allDone: break
      let s = execProcess(binDir / "runquota", args = ["status", "--json"],
                          env = statusEnv, options = {})
      try:
        for g in parseJson(s)["session_groups"]:
          owners.incl(g["owner_uid"].getInt)
          if g["name"].getStr == group:
            maxGroupSessions = max(maxGroupSessions, g["sessions"].getInt)
      except CatchableError:
        discard
      let l = execProcess(binDir / "runquota", args = ["leases", "--json"],
                          env = statusEnv, options = {})
      try:
        var n = 0
        for lease in parseJson(l)["leases"]:
          if lease{"foreign_pid_namespace"}.getBool(false): inc n
        foreignLeases = max(foreignLeases, n)
      except CatchableError:
        discard
      sleep(200)

    var outputs = initTable[string, string]()
    for (tag, p) in jobs:
      let (code, output) = p.finish()
      outputs[tag] = output
      checkpoint(tag & " exit " & $code & ":\n" & output)
      check code == 0
      # Leased, never the "no daemon reached ... running unchanged" path.
      check "lease " in output
      check "no daemon reached" notin output

    let counted = readLedger(ledger)
    checkpoint("ledger: current=" & $counted.current & " peak=" &
      $counted.peak & " total=" & $counted.total & "\nevents:\n" &
      readFile(ledger / "events"))
    check counted.total == 2 * JobsPerSide
    check counted.current == 0
    check counted.peak <= BudgetCpus
    check counted.peak == BudgetCpus
    # Attribution: one group, the session's, owned by this uid, joined by
    # more sessions than the host side opened (so the container's joined it).
    checkpoint("owners seen: " & $owners & ", sessions in " & group & ": " &
      $maxGroupSessions & ", foreign-namespace leases: " & $foreignLeases)
    echo "  measured: peak=" & $counted.peak & " of budget " & $BudgetCpus &
      ", jobs=" & $counted.total & ", group " & group & " sessions<=" &
      $maxGroupSessions & ", owners=" & $owners &
      ", foreign-namespace leases<=" & $foreignLeases
    echo "  events: " & readFile(ledger / "events").strip().replace("\n", "; ")
    check owners == toHashSet([int(getuid())])
    check maxGroupSessions > JobsPerSide
    check foreignLeases >= 1

    # ---- the forwarder dies mid-lease -----------------------------------
    # A container job holds the whole budget; then the device is removed,
    # which ends its forwarder (the connection's peer, watched in the
    # foreign-namespace child's place). The lease must be released -- the
    # budget is free for a host job and no lease is left behind -- rather
    # than held for the daemon's lifetime.
    var holdArgv = incus.incusCmd[1 .. ^1]
    holdArgv.add(@["exec", name, "--", GuestBinDir / "runquota", "run",
      "--verbose", "--width", $BudgetCpus, "--", "/bin/sh", "-c", "sleep 25"])
    let holder = startProcess(incus.incusCmd[0], args = holdArgv,
                              options = {poUsePath, poStdErrToStdOut})
    started.add(holder)
    var held = false
    let holdDeadline = epochTime() + 20.0
    while epochTime() < holdDeadline and not held:
      let l = execProcess(binDir / "runquota", args = ["leases", "--json"],
                          env = statusEnv, options = {})
      try:
        for lease in parseJson(l)["leases"]:
          if lease["state"].getStr == "running" and
              lease{"foreign_pid_namespace"}.getBool(false):
            held = true
      except CatchableError:
        discard
      if not held: sleep(200)
    # `check`, not `require`: `require` ends the test without running the
    # `defer`s that delete the container and stop the daemon.
    check held
    if held:
      let removed = incus.runIncus(@["config", "device", "remove", name,
        IncusRunQuotaDevice], timeoutSec = 60)
      check removed.exitCode == 0
      let after = startProcess(binDir / "runquota", args = @["run",
        "--verbose", "--width", $BudgetCpus, "--", "/bin/true"],
        env = hostEnv, options = {poStdErrToStdOut})
      started.add(after)
      # On POSIX `waitForExit` kills a process still running at its bound, so
      # a host job still waiting for the budget after 20 s reads as 137.
      let afterCode = after.waitForExit(20_000)
      let afterText = after.outputStream.readAll()
      checkpoint("host job after the forwarder died: exit " & $afterCode &
        "\n" & afterText)
      check afterCode == 0
      check "lease " in afterText
      var leftover = -1
      try:
        leftover = parseJson(execProcess(binDir / "runquota",
          args = ["leases", "--json"], env = statusEnv,
          options = {}))["leases"].len
      except CatchableError:
        discard
      check leftover == 0
      echo "  forwarder removed mid-lease: host job exit=" & $afterCode &
        ", leases left=" & $leftover & ", container job still running=" &
        $holder.running()

    incus.stopAndCleanup(vm, deleteVm = true)
    check not incus.containerExists(name)
