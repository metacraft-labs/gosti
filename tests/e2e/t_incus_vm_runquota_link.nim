# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## t_incus_vm_runquota_link — an Incus VM is a sub-machine of the host's
## RunQuota daemon: the host holds the VM's memory for its whole life and
## counts its vCPUs at the full shape, until a RunQuota daemon in the guest
## links to the host's over virtio-vsock; then it counts them at what the
## guest's own leases hold, so the vCPUs an idle VM leaves unused go to the
## host's builds, and come back when the guest gets busy.
##
## Against a REAL Incus VM (KVM), a REAL ``runquotad`` on the host and a REAL
## one in the guest, linked over REAL vsock. No mocks:
##
## * the "host daemon" is a private ``runquotad`` this test starts on a
##   socket in a fresh ``0700`` directory it owns, with a budget of 4 CPUs
##   and 3 GiB, listening for guest links on a vsock port of its own
##   (``--vm-link-vsock-port``); the host's own daemon is never touched.
## * the VM (2 vCPUs, 1 GiB, ``images:alpine/3.21`` copied locally as
##   ``rqvm-<pid>-alpine``) is created by gosti's Incus provider with
##   ``registerWithHostRunQuota``, which runs ``runquota vm hold`` before the
##   first start and reports the VM's QEMU process and vsock CID after it.
## * the RunQuota binaries and the ``/nix/store`` paths they load are copied
##   into the guest, where the guest daemon (budget: the VM's shape) is
##   started with ``--link-host vsock:<port>``.
##
## Host jobs count themselves in and out of a ``flock(1)`` ledger while their
## leased command runs, so the ledger's maximum is the exact peak of
## concurrently running host leases.
##
## The cases, in order (each builds on the VM the one before left):
##
## 1. unlinked: before the guest daemon starts, the VM counts at its full
##    shape -- four width-1 host jobs peak at exactly 2 (budget 4 minus 2
##    vCPUs) -- and ``runquota status`` says why (link ``unlinked``, a
##    capability line).
## 2. idle linked VM: once the guest daemon links, four width-1 host jobs
##    peak at exactly 4: the host's builds run on the VM's idle vCPUs. Then
##    a host job holds 2 CPUs and the guest takes a 2-CPU lease of its own:
##    the host's very next admission decision counts the guest (a host job
##    that fitted a moment earlier now waits), the running host job is not
##    revoked, and the waiting job is granted once the guest's lease ends.
## 3. memory: while the VM runs, linked and idle, a host lease of 2.5 GiB
##    (more than the 3 GiB budget minus the VM's 1 GiB) is never granted,
##    and 2 GiB is. The guest reboots, which Incus does by starting a new
##    QEMU process: 2.5 GiB is refused throughout, also between the old
##    process's exit and the new one's report, and the same registration
##    watches the new process. With the holder
##    process killed the reservation still holds (the VM process is the
##    lease's watched child); once the VM is deleted, 2.5 GiB is granted and
##    no lease is left.
##
## Falsifying mutations (each applied and seen to fail): counting the VM at
## its full shape always fails case 2's peak (2, not 4); charging an
## unlinked VM nothing fails case 1's peak (4, not 2); a registration that
## does not reserve the VM's memory fails case 3; a holder that does not
## follow a restart in place fails case 3's reboot.
##
## Prerequisites, each a printed SKIP when absent (a skip is not a pass): a
## Linux host with ``/dev/kvm`` and ``/dev/vhost-vsock``; Incus reachable;
## ``GOSTI_RUNQUOTA_BIN_DIR`` naming a directory with ``runquota`` and
## ``runquotad`` built for this host. The image ``GOSTI_RUNQUOTA_VM_IMAGE``
## (default ``images:alpine/3.21``, a VM image with the Incus agent) is
## copied locally; a copy that fails is a FAILURE, not a skip. Every Incus
## object is named ``rqvm-<pid>-…`` and deleted on every way out -- a failed
## case, a failed setup, SIGTERM or SIGINT -- including an image whose copy
## the test stopped and the daemon finished later; every process the test
## starts is recorded and only those are stopped.
##
## Run: GOSTI_RUNQUOTA_BIN_DIR=<runquota>/build/bin \
##        nim r --hints:off tests/e2e/t_incus_vm_runquota_link.nim

import std/[json, os, osproc, posix, random, streams, strtabs,
            strutils, tables,
            tempfiles, times, unittest]
import gosti

when not defined(linux):
  echo "[skip] t_incus_vm_runquota_link: Linux host required"
  quit(0)

const
  BudgetCpus = 4
  BudgetMemory = 3'i64 * 1024 * 1024 * 1024
  VmCpus = 2
  VmMemoryMB = 1024
  JobSeconds = 4
  GuestBinDir = "/opt/rqvm/bin"
  GuestRunDir = "/run/rqvm"

let binDir = getEnv("GOSTI_RUNQUOTA_BIN_DIR")
let sourceImage = block:
  let e = getEnv("GOSTI_RUNQUOTA_VM_IMAGE")
  if e.len > 0: e else: "images:alpine/3.21"

proc skip(reason: string) =
  echo "[skip] t_incus_vm_runquota_link: " & reason
  quit(0)

if binDir.len == 0 or not fileExists(binDir / "runquota") or
    not fileExists(binDir / "runquotad"):
  skip("GOSTI_RUNQUOTA_BIN_DIR must name a directory holding runquota and " &
    "runquotad")
if access("/dev/kvm", F_OK) != 0 or access("/dev/vhost-vsock", F_OK) != 0:
  skip("/dev/kvm and /dev/vhost-vsock are required")

let incus = newIncusBackend()
if not incus.probeAvailability():
  skip("Incus is not reachable")

# ---------------------------------------------------------------------------
# Processes this test starts: recorded at spawn, and only these are stopped.

var started: seq[Process] = @[]

proc spawn(exe: string; args: seq[string]; env: StringTableRef = nil): Process =
  result = startProcess(exe, args = args, env = env,
                        options = {poStdErrToStdOut, poUsePath})
  result.inputStream.close()
  started.add(result)

proc exitedWithin(p: Process; millis: int): bool =
  let deadline = epochTime() + float(millis) / 1000.0
  while p.running():
    if epochTime() >= deadline:
      return false
    sleep(50)
  true

proc stopStarted() =
  for p in started:
    if p.running():
      p.terminate()
      if not p.exitedWithin(5000):
        p.kill()
        discard p.exitedWithin(5000)
    p.close()
  started.setLen(0)

proc finish(p: Process): tuple[code: int, output: string] =
  let output = p.outputStream.readAll()
  (p.waitForExit(), output)

proc uniqueName(tag: string): string =
  "rqvm-" & $getCurrentProcessId() & "-" & tag

proc run(cmd: seq[string]; timeoutSec = 120): tuple[code: int, output: string] =
  let p = startProcess(cmd[0], args = cmd[1 .. ^1],
    options = {poUsePath, poStdErrToStdOut})
  p.inputStream.close()
  started.add(p)
  if not p.exitedWithin(timeoutSec * 1000):
    return (-1, "timed out: " & cmd.join(" "))
  p.finish()

proc guest(name: string; script: string; timeoutSec = 120): tuple[code: int, output: string] =
  run(@["incus", "exec", name, "--", "sh", "-c", script], timeoutSec)

# ---------------------------------------------------------------------------
# The binaries' runtime closure, copied into the guest at the same paths.

proc storeRoots(binary: string): seq[string] =
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
# The ledger: a host job counts itself in and out under flock(1).

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

proc resetLedger(dir: string) =
  writeFile(dir / "ledger", "0 0 0\n")
  writeFile(dir / "events", "")

proc readLedger(dir: string): tuple[current, peak, total: int] =
  let fields = readFile(dir / "ledger").splitWhitespace()
  doAssert fields.len == 3, "ledger is not three numbers: " & $fields
  (parseInt(fields[0]), parseInt(fields[1]), parseInt(fields[2]))

proc waitForSocket(path: string; daemon: Process): bool =
  let deadline = epochTime() + 20.0
  while epochTime() < deadline:
    var info: Stat
    if lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode):
      return true
    if not daemon.running(): return false
    sleep(50)
  false

var hostEnv: StringTableRef

proc status(): JsonNode =
  try:
    parseJson(execProcess(binDir / "runquota", args = ["status", "--json"],
      env = hostEnv, options = {}))
  except CatchableError:
    newJNull()

proc vmEntry(name: string): JsonNode =
  let s = status()
  if s.kind == JObject and s.hasKey("virtual_machines"):
    for vm in s["virtual_machines"]:
      if vm["name"].getStr == name:
        return vm
  newJNull()

proc hostJobs(ledger: string; count: int; tag: string): seq[(string, Process)] =
  for i in 1 .. count:
    let t = tag & "-" & $i
    result.add((t, spawn(binDir / "runquota", @["run", "--verbose",
      "--width", "1", "--", "/bin/sh", ledger / "job.sh", ledger, t,
      $JobSeconds], hostEnv)))

proc checkJobs(jobs: seq[(string, Process)]) =
  for (tag, p) in jobs:
    let (code, output) = p.finish()
    checkpoint(tag & " exit " & $code & ":\n" & output)
    check code == 0
    check "lease " in output
    check "no daemon reached" notin output

proc fitsNow(cpuMilli: int; memoryBytes: int64): tuple[granted: bool, output: string] =
  ## Whether a host lease of this size is granted NOW: ``runquota acquire``
  ## asks once and is refused ("does not fit") rather than queued when it
  ## does not fit, so each call is one admission decision of the host daemon.
  let p = spawn(binDir / "runquota", @["acquire", "--cpu", $cpuMilli,
    "--mem", $memoryBytes, "--", "/bin/sh", "-c", "true"], hostEnv)
  if not p.exitedWithin(15_000):
    return (false, "no answer within 15 s")
  let (code, output) = p.finish()
  (code == 0, output)

proc fitsWithin(cpuMilli: int; memoryBytes: int64;
                seconds: int): tuple[granted: bool, output: string] =
  let deadline = epochTime() + float(seconds)
  while true:
    result = fitsNow(cpuMilli, memoryBytes)
    if result.granted or epochTime() >= deadline:
      return
    sleep(250)

# ---------------------------------------------------------------------------
# The world the three cases share: one host daemon, one VM. Set up once, in
# order, and torn down once at the end -- also when the setup fails or skips
# -- so a failed case still deletes the VM and the image and stops every
# process (a failed `check` or `require` ends only its case).

var
  root, socket, ledger, image, name, guestEnv: string
  vsockPort: int
  vm: VmHandle
  guestLinked = false
  tornDown = false
  imageCopyIncomplete = false


proc tearDown() =
  if tornDown: return
  tornDown = true
  if name.len > 0:
    if incus.containerExists(name):
      discard incus.deleteContainer(name)
    discard reapVmHolder(name)
  stopStarted()
  if image.len > 0:
    # A copy this test stopped (timed out, or the test was signalled) can
    # still finish inside the Incus daemon and add the image afterwards, so
    # then wait for it to appear before deleting it.
    let deadline = epochTime() + (if imageCopyIncomplete: 600.0 else: 0.0)
    while run(@["incus", "image", "delete", image]).code != 0 and
        epochTime() < deadline:
      sleep(2000)
    stopStarted()
  if root.len > 0:
    removeDir(root)
  delEnv("RUNQUOTA_SOCKET")
  delEnv("RUNQUOTA_ENDPOINT_SCOPE")
  delEnv("RUNQUOTA_SESSION")

proc setUpHostAndVm() =
  root = createTempDir("rqvm-", "", "/tmp")
  doAssert chmod(root.cstring, Mode(0o700)) == 0
  socket = root / "d.sock"
  ledger = root / "ledger"
  createDir(ledger)
  writeFile(ledger / "lock", "")
  writeFile(ledger / "job.sh", JobScript)
  doAssert chmod((ledger / "job.sh").cstring, Mode(0o755)) == 0
  resetLedger(ledger)

  randomize()
  vsockPort = 40000 + rand(19999)
  var daemonEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): daemonEnv[k] = v
  for k in ["RUNQUOTA_SOCKET", "RUNQUOTA_ENDPOINT_OWNER_UID",
            "RUNQUOTA_ENDPOINT_GROUP", "RUNQUOTA_SESSION",
            "RUNQUOTA_EXIT_WITH_PARENT", "LISTEN_PID", "LISTEN_FDS"]:
    daemonEnv.del(k)
  daemonEnv["RUNQUOTA_ENDPOINT_SCOPE"] = "private"
  let daemon = spawn(binDir / "runquotad", @["--socket", socket,
    "--host-config", root / "host.toml",
    "--host-identity-file", root / "host-id",
    "--estimate-db", root / "est.sqlite",
    "--no-write-stats",
    "--ambient-sample-interval-millis", "0",
    "--memory-pressure-source", "unavailable",
    "--cpu-pressure-file", root / "cpu-pressure",
    "--cpu-milli", $(BudgetCpus * 1000),
    "--memory-bytes", $BudgetMemory,
    "--vm-link-vsock-port", $vsockPort], daemonEnv)
  doAssert waitForSocket(socket, daemon), "the host runquotad did not start"

  hostEnv = newStringTable(modeCaseSensitive)
  for k, v in daemonEnv: hostEnv[k] = v
  hostEnv["RUNQUOTA_SOCKET"] = socket
  putEnv("RUNQUOTA_SOCKET", socket)
  putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
  putEnv("RUNQUOTA_SESSION", uniqueName("session"))
  let link = status(){"vm_link"}
  doAssert link{"listening"}.getBool(false),
    "the host runquotad is not listening for VM links: " & $link

  # The image, copied under a name this test owns.
  # Recorded BEFORE the copy, so every path out of the test deletes it.
  image = uniqueName("alpine")
  imageCopyIncomplete = true
  let copied = run(@["incus", "image", "copy", sourceImage, "local:",
    "--vm", "--alias", image], timeoutSec = 1800)
  # A failed copy is a failure of this run, not a skip.
  doAssert copied.code == 0, "the image " & sourceImage &
    " could not be copied: " & copied.output
  imageCopyIncomplete = false

  # The VM, registered before it boots.
  name = uniqueName("vm")
  var config = incusEphemeralLimits(VmCpus, VmMemoryMB)
  # The community images are not signed for Secure Boot.
  config["security.secureboot"] = "false"
  vm = incus.provisionEphemeralClone(EphemeralIncusSpec(
    name: name, baseImage: image, ephemeral: false,
    ownerToken: uniqueName("owner"), virtualMachine: true,
    registerWithHostRunQuota: true,
    runquotaCommand: @[binDir / "runquota"], config: config))
  doAssert vm.extra["runquotaLease"].len > 0
  var ready = false
  let readyDeadline = epochTime() + 180.0
  while epochTime() < readyDeadline and not ready:
    ready = run(@["incus", "exec", name, "--", "true"], 20).code == 0
    if not ready: sleep(1000)
  doAssert ready, "the VM's agent never answered"

proc linkGuest() =
  ## Copy the RunQuota binaries into the guest, start its daemon with
  ## ``--link-host``, and wait until the host shows the link.
  if guestLinked: return
  var entry: JsonNode
  var roots: seq[string] = @[]
  for exe in ["runquota", "runquotad"]:
    for r in storeRoots(binDir / exe):
      if r notin roots: roots.add(r)
  let tarball = root / "rq.tar"
  var tarArgs = @["tar", "-cf", tarball, "--transform",
    "s|^" & binDir.strip(chars = {'/'}) & "|" &
    GuestBinDir.strip(chars = {'/'}) & "|", "-C", "/",
    (binDir / "runquota").strip(leading = true, chars = {'/'}),
    (binDir / "runquotad").strip(leading = true, chars = {'/'})]
  for r in roots: tarArgs.add(r.strip(leading = true, chars = {'/'}))
  let packed = run(tarArgs)
  doAssert packed.code == 0, packed.output
  let pushed = run(@["incus", "file", "push", tarball, name & "/tmp/rq.tar"],
    300)
  doAssert pushed.code == 0, pushed.output
  let unpacked = guest(name, "tar -C / -xf /tmp/rq.tar && rm /tmp/rq.tar" &
    " && mkdir -p " & GuestRunDir & " && chmod 0700 " & GuestRunDir)
  doAssert unpacked.code == 0, unpacked.output
  guestEnv = "RUNQUOTA_ENDPOINT_SCOPE=private RUNQUOTA_SOCKET=" &
    GuestRunDir & "/d.sock"
  let guestDaemon = guest(name, guestEnv & " nohup " & GuestBinDir &
    "/runquotad --socket " & GuestRunDir & "/d.sock --host-config " &
    GuestRunDir & "/host.toml --host-identity-file " & GuestRunDir &
    "/host-id --estimate-db " & GuestRunDir & "/est.sqlite " &
    "--no-write-stats --ambient-sample-interval-millis 0 " &
    "--memory-pressure-source unavailable --link-host vsock:" &
    $vsockPort & " --link-name " & name & " > " & GuestRunDir &
    "/daemon.log 2>&1 < /dev/null &")
  doAssert guestDaemon.code == 0, guestDaemon.output
  var linked = false
  let linkDeadline = epochTime() + 60.0
  while epochTime() < linkDeadline and not linked:
    entry = vmEntry(name)
    linked = entry{"link"}.getStr == "linked"
    if not linked: sleep(200)
  doAssert linked, "the guest daemon never linked: " & $entry &
    "\nguest daemon log:\n" &
    guest(name, "cat " & GuestRunDir & "/daemon.log").output
  guestLinked = true

# A signalled run (SIGTERM from a runner's timeout, Ctrl-C) still deletes
# the VM and the image and stops the processes it started.
proc onSignal(sig: cint) {.noconv.} =
  tearDown()
  quit(128 + int(sig))
signal(SIGTERM, onSignal)
signal(SIGINT, onSignal)

try:
  setUpHostAndVm()
except CatchableError, AssertionDefect:
  tearDown()
  raise

suite "an Incus VM linked to the host RunQuota daemon":
  test "an unlinked VM counts at its full shape, and status says so":
    var entry = vmEntry(name)
    checkpoint("unlinked: " & $entry)
    check entry{"link"}.getStr == "unlinked"
    check entry{"counted_at"}.getStr == "full-shape"
    check entry{"charged_cpu_milli"}.getInt == VmCpus * 1000
    check entry{"lease_state"}.getStr == "running"
    check entry{"capability"}.getStr.len > 0
    let text = execProcess(binDir / "runquota", args = ["status"],
      env = hostEnv, options = {})
    check ("virtual_machine " & name) in text
    check "capability=" in text
    resetLedger(ledger)
    checkJobs(hostJobs(ledger, BudgetCpus, "unlinked"))
    let unlinked = readLedger(ledger)
    echo "  unlinked: host peak=" & $unlinked.peak & " of budget " &
      $BudgetCpus & " with a " & $VmCpus & "-vCPU VM, jobs=" & $unlinked.total
    check unlinked.total == BudgetCpus
    check unlinked.peak == BudgetCpus - VmCpus

  test "an idle linked VM's vCPUs run host builds; a busy guest takes them back at the next decision":
    linkGuest()
    var entry = vmEntry(name)
    checkpoint("linked: " & $entry)
    check entry{"link"}.getStr == "linked"
    check entry{"counted_at"}.getStr == "guest-use"
    check entry{"charged_cpu_milli"}.getInt == 0
    check entry{"capability"}.kind == JNull
    check entry{"guest"}{"budget_cpu_milli"}.getInt == VmCpus * 1000
    let guestStatus = guest(name, guestEnv & " " & GuestBinDir &
      "/runquota status --json")
    check "\"host_link\":{\"state\":\"linked\"" in guestStatus.output
    resetLedger(ledger)
    checkJobs(hostJobs(ledger, BudgetCpus, "idle"))
    let idle = readLedger(ledger)
    echo "  idle linked VM: host peak=" & $idle.peak & " of budget " &
      $BudgetCpus & ", jobs=" & $idle.total
    check idle.total == BudgetCpus
    check idle.peak == BudgetCpus

    # A host job holds 2 CPUs: all but the VM's, which the idle guest lends.
    let holder = spawn(binDir / "runquota", @["run", "--verbose", "--width",
      "2:2", "--", "/bin/sh", "-c", "sleep 25"], hostEnv)
    var holding = false
    let holdDeadline = epochTime() + 10.0
    while epochTime() < holdDeadline and not holding:
      # The VM's lease and the host job's.
      holding = execProcess(binDir / "runquota", args = ["leases", "--json"],
          env = hostEnv, options = {}).count("\"state\":\"running\"") >= 2
      if not holding: sleep(100)
    require holding
    # Another 2 CPUs fit now: the guest idles.
    let before = fitsNow(2000, 1048576)
    checkpoint("2 CPUs with the guest idle: " & before.output)
    check before.granted
    # The guest takes a 2-CPU lease of its own.
    let guestJob = startProcess("incus", args = @["exec", name, "--", "sh",
      "-c", guestEnv & " " & GuestBinDir & "/runquota run --width 2:2 " &
      "-- sh -c 'echo guest-granted; sleep 12'"],
      options = {poUsePath, poStdErrToStdOut})
    started.add(guestJob)
    var guestGranted = false
    let guestDeadline = epochTime() + 30.0
    var line = ""
    while epochTime() < guestDeadline and not guestGranted:
      if guestJob.outputStream.readLine(line):
        guestGranted = "guest-granted" in line
      else:
        break
    require guestGranted
    let grantedAt = epochTime()
    # The host's next decision counts the guest: the same 2 CPUs that fitted
    # a moment ago do not, and the running host job keeps its lease.
    entry = vmEntry(name)
    let observedAfter = epochTime() - grantedAt
    checkpoint("busy guest: " & $entry)
    check entry{"charged_cpu_milli"}.getInt == VmCpus * 1000
    check entry{"guest"}{"granted_cpu_milli"}.getInt == VmCpus * 1000
    let during = fitsNow(2000, 1048576)
    checkpoint("2 CPUs with the guest busy: " & during.output)
    check not during.granted
    check holder.running()
    let leasesNow = execProcess(binDir / "runquota", args = ["leases",
      "--json"], env = hostEnv, options = {})
    checkpoint("leases while the guest is busy: " & leasesNow)
    check leasesNow.count("\"state\":\"running\"") >= 2
    # A host job that waits for 2 CPUs is granted once the guest's lease
    # ends, and not before.
    let waiter = spawn(binDir / "runquota", @["run", "--verbose", "--width",
      "2:2", "--", "/bin/sh", "-c", "true"], hostEnv)
    let waitedWhileBusy = not waiter.exitedWithin(3000)
    check waitedWhileBusy
    let (guestCode, guestOut) = guestJob.finish()
    checkpoint("guest job exit " & $guestCode & ": " & guestOut)
    check guestCode == 0
    let returnedAt = epochTime()
    check waiter.exitedWithin(15_000)
    let returnSeconds = epochTime() - returnedAt
    let (waiterCode, waiterOut) = waiter.finish()
    checkpoint("waiting host job: " & waiterOut)
    check waiterCode == 0
    check "lease " in waiterOut
    echo "  busy guest: charge " & $entry{"charged_cpu_milli"}.getInt &
      "m read " & $int(observedAfter * 1000.0) &
      " ms after the guest's grant; 2 more host CPUs fitted before (" &
      $before.granted & "), not during (" & $(not during.granted) &
      "); a waiting 2-CPU host job was granted " &
      formatFloat(returnSeconds, ffDecimal, 1) &
      " s after the guest's lease ended; the running host job kept its lease"
    # The host job that held 2 CPUs ends by itself.
    check holder.exitedWithin(30_000)
    let (holderCode, holderOut) = holder.finish()
    checkpoint("host holder: " & holderOut)
    check holderCode == 0

  test "a VM's memory is never granted to host leases while it runs":
    linkGuest()
    var entry: JsonNode
    let budgetLeft = BudgetMemory - int64(VmMemoryMB) * 1024 * 1024
    let tooBig = budgetLeft + 512'i64 * 1024 * 1024
    entry = vmEntry(name)
    check entry{"link"}.getStr == "linked"
    check entry{"charged_cpu_milli"}.getInt == 0
    let bigWhileRunning = fitsNow(1000, tooBig)
    checkpoint("2.5 GiB while the VM runs: " & bigWhileRunning.output)
    check not bigWhileRunning.granted
    let fits = fitsNow(1000, budgetLeft)
    checkpoint("2 GiB while the VM runs: " & fits.output)
    check fits.granted
    # The guest reboots: Incus stops the VM and starts it again in a NEW
    # QEMU process. The holder follows it (its restart probe), so the
    # reservation is never dropped -- not while the old process is gone and
    # the new one not yet up, and not after.
    let before = vmEntry(name)
    let oldPid = before{"process_id"}.getInt
    let leaseBefore = before{"lease_id"}.getInt
    require oldPid > 0
    discard run(@["incus", "exec", name, "--", "reboot"], 30)
    var newPid = 0
    var samples = 0
    var samplesWhileDown = 0
    var grantedDuringReboot = 0
    let rebootDeadline = epochTime() + 120.0
    while epochTime() < rebootDeadline:
      let oldGone = not dirExists("/proc/" & $oldPid)
      let probe = fitsNow(1000, tooBig)
      inc samples
      if probe.granted:
        inc grantedDuringReboot
        checkpoint("2.5 GiB granted during the reboot: " & probe.output)
      let now = vmEntry(name)
      if oldGone and now{"process_id"}.getInt == oldPid:
        inc samplesWhileDown
      if now{"process_id"}.getInt notin [0, oldPid]:
        newPid = now{"process_id"}.getInt
        break
      sleep(200)
    let after = vmEntry(name)
    checkpoint("after the reboot: " & $after)
    check newPid > 0
    check dirExists("/proc/" & $newPid)
    check not dirExists("/proc/" & $oldPid)
    check grantedDuringReboot == 0
    check samplesWhileDown > 0
    check after{"lease_id"}.getInt == leaseBefore
    check after{"lease_state"}.getStr == "running"
    check after{"restarts"}.getInt == 1
    let bigAfterReboot = fitsNow(1000, tooBig)
    checkpoint("2.5 GiB after the reboot: " & bigAfterReboot.output)
    check not bigAfterReboot.granted
    echo "  reboot: QEMU " & $oldPid & " -> " & $newPid & ", 2.5 GiB asked " &
      $samples & " times during it (" & $samplesWhileDown &
      " after the old QEMU exited and before the new one was reported), " &
      "granted " & $grantedDuringReboot &
      " times; same lease, restarts=" & $after{"restarts"}.getInt
    # The holder dies: the VM process is the lease's watched child, so the
    # reservation holds while the VM runs.
    let holderPid = vmHolderPid(name)
    require holderPid > 0
    doAssert kill(Pid(holderPid), SIGTERM) == 0
    sleep(500)
    let lostLeases = execProcess(binDir / "runquota", args = ["leases",
      "--json"], env = hostEnv, options = {})
    checkpoint("leases after the holder died: " & lostLeases)
    check "\"state\":\"supervisor_lost\"" in lostLeases
    let bigHolderLost = fitsNow(1000, tooBig)
    check not bigHolderLost.granted
    # The VM goes: its memory comes back, and nothing is left.
    incus.stopAndCleanup(vm, deleteVm = true)
    check not incus.containerExists(name)
    let bigAfter = fitsWithin(1000, tooBig, 20)
    checkpoint("2.5 GiB after the VM was deleted: " & bigAfter.output)
    check bigAfter.granted
    var leftover = -1
    try:
      leftover = parseJson(execProcess(binDir / "runquota",
        args = ["leases", "--json"], env = hostEnv, options = {}))["leases"].len
    except CatchableError:
      discard
    check leftover == 0
    check vmEntry(name).kind == JNull
    echo "  memory: 2.5 GiB refused while the VM ran (linked: " &
      $(not bigWhileRunning.granted) & ", holder lost: " &
      $(not bigHolderLost.granted) & "), 2 GiB granted; after the VM was " &
      "deleted 2.5 GiB granted=" & $bigAfter.granted & ", leases left=" &
      $leftover

tearDown()
