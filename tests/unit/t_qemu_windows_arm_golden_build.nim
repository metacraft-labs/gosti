# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Runner-Fleet-M3-ARM-Wave MA3 gate: ``t_qemu_windows_arm_golden_build``
## — UNIT TIER, POSIX hosts. Needs no hypervisor, guest Windows or ISO.
## Portable contracts are in t_qemu_windows_arm_golden_contracts.
##
## The host tier of the same gate (a real install -> sysprep -> golden run,
## and two clones with DISTINCT machine SIDs) lives in
## ``tests/e2e/t_qemu_windows_arm_golden_build_host.nim`` and is wired into
## ``scripts/run-host-tests.sh``. It SKIPS with an explicit message naming
## what it needs. This file must not be read as covering it.
##
## WHY THIS GATE EXISTS. The Windows-ARM golden the ``eph-win-arm64`` lane ran
## on was promoted by hand, existed in no build graph, had no backup and no
## manifest. It was lost between 2026-07-20 and 2026-08-24, taking the lane
## down with it, and nothing in this repository could rebuild it. The recipe
## is now the artifact, so the build path is the ONLY path — which makes the
## assertions below the difference between a lane that can be restored on
## demand and one that cannot.
##
## WHAT IS ASSERTED HERE, and why each is a regression of a real hazard:
##
##  1. The install boot attaches the Windows ISO over xHCI and the answer-file
##     ISO on ``ich9-ahci`` (each is pinned to the controller it HAS to be on —
##     see ``buildQemuWindowsArmInstallArgs``), orders the install media ahead
##     of the still-empty target disk, and omits ``-no-reboot``.
##  2. A build into a directory already holding a golden is REFUSED — qcow2
##     does not verify a backing file, so rebuilding in place corrupts every
##     live overlay with no error anywhere.
##  3. An overlay records the RESOLVED backing path, never the pointer
##     symlink, or the promotion flip corrupts the instances the versioned
##     scheme exists to protect.
##  4. The sentinel the harness polls for, and the sysprep answer file it
##     names, are the ones the CHECKED-IN recipe actually writes and stages.
##     Both are cross-repo-file assertions, so drift on either side fails.
##  5. Power-off is observed on the MONITOR socket, never over SSH — SSH dies
##     with the guest that ``sysprep /shutdown`` just powered off.
##  6. Every wait is bounded by the deadline it was given, and every failure
##     leaves the build directory, the guest serial log and QEMU's own log
##     behind, and SAYS WHERE THEY ARE. A Windows install that goes wrong has
##     no console and no SSH; those two files are the entire diagnostic
##     surface.
##  7. The finished golden carries a manifest identifying what it was built
##     from, and boots with NO reference to the install media.
##
## The suites "QemuWindowsArmBackend golden build" and "Golden build space
## precondition" were MOVED here intact from
## ``tests/unit/t_qemu_windows_arm_backend.nim`` so that a grep for the gate
## name lands on every assertion it owns. No test was dropped and no
## assertion weakened in the move.
##
## MOCKING NOTE (workspace policy: every mock must be justified). The three
## fakes this file drives — a fake QEMU that is this binary re-executed, a fake
## ``swtpm`` and a fake ``sshpass`` — were EXTRACTED VERBATIM into
## ``tests/unit/qwa_fake_qemu.nim`` when MA8's gate needed the same harness.
## Nothing about them changed in the move. That file carries the full mocking
## justification and explains why it is ``include``d rather than imported (the
## fake QEMU is this binary re-executed, so its entry point has to be compiled
## INTO each gate that uses it).
include qwa_fake_qemu

import std/monotimes

proc cleanupOwnedFakeChild(pid: int) =
  ## This single-threaded fixture has no other waiter. An unreaped direct
  ## child holds PID authority; ECHILD never authorizes a foreign signal.
  if pid <= 0:
    raise newException(IOError, "fake QEMU cleanup: positive direct-child PID required")
  when defined(posix):
    proc pollUntil(deadline: MonoTime): bool =
      while getMonoTime() < deadline:
        var status: cint
        let waited = posix.waitpid(Pid(pid), status, WNOHANG)
        if waited == Pid(pid): return true
        if waited < Pid(0):
          if osLastError() == OSErrorCode(EINTR): continue
          raise newException(IOError, "fake QEMU cleanup: direct-child authority lost")
        sleep(10)
      return false
    proc signalOwned(sig: cint): bool =
      var status: cint
      let authorityDeadline = getMonoTime() + initDuration(milliseconds = 2000)
      while true:
        if getMonoTime() >= authorityDeadline:
          raise newException(IOError, "fake QEMU cleanup: interrupted authority check exhausted")
        let owned = posix.waitpid(Pid(pid), status, WNOHANG)
        if owned == Pid(pid): return true
        if owned < Pid(0):
          if osLastError() == OSErrorCode(EINTR): continue
          raise newException(IOError, "fake QEMU cleanup: direct-child authority lost")
        break
      if posix.kill(Pid(pid), sig) != 0:
        if osLastError() != OSErrorCode(ESRCH): raiseOSError(osLastError())
        # It may have exited between waitpid and kill; only waitpid can
        # resolve that race. No signal-0 or unrelated-PID fallback.
      return false
    if signalOwned(SIGTERM): return
    if pollUntil(getMonoTime() + initDuration(milliseconds = 2000)): return
    if signalOwned(SIGKILL): return
    if not pollUntil(getMonoTime() + initDuration(milliseconds = 2000)):
      raise newException(IOError, "fake QEMU cleanup: owned child not reaped; retain fixture root")
  else:
    raise newException(IOError, "fake QEMU cleanup requires the original POSIX fixture scope")


# `sequtils` is used by the assertions in this file, not by the shared
# harness, so it is imported here rather than there.
import std/sequtils


# ---------------------------------------------------------------------------
# Moved intact from tests/unit/t_qemu_windows_arm_backend.nim.
# ---------------------------------------------------------------------------

suite "QemuWindowsArmBackend golden build":
  ## The golden install boot and the guards that keep a rebuild from
  ## corrupting the instances running on top of the golden it replaces.

  test "an overlay records the resolved golden, not the pointer":
    when defined(posix):
      let tmp = createTempDir("vmh-qemu-win-arm-symlink-", "")
      defer: removeDir(tmp)
      let versioned = tmp / "win-arm-runner-0003"
      createDir(versioned)
      writeFile(versioned / "windows.qcow2", "golden")
      let pointer = tmp / "win-arm-runner"
      createSymlink(versioned, pointer)

      let log = tmp / "qemu-img.log"
      let fakeQemuImg = tmp / "qemu-img"
      writeFile(fakeQemuImg, "#!/bin/sh\nprintf '%s\\n' \"$@\" >> '" & log &
                             "'\nexit 0\n")
      setFilePermissions(fakeQemuImg, {fpUserRead, fpUserWrite, fpUserExec})

      createEphemeralOverlay(pointer, tmp / "instance", fakeQemuImg)

      let recorded = readFile(log)
      # Recording the pointer would mean the next build's flip repoints a
      # live instance's backing store at a different disk.
      check versioned / "windows.qcow2" in recorded
      check (pointer / "windows.qcow2") notin recorded
    else:
      skip()

suite "Golden build: power-off is read off the monitor, not off SSH":

  test "a live guest answering the monitor is not reported as powered off":
    let tmp = createTempDir("vmh-qwa-poweroff-live-", "")
    var cleanupComplete = false
    defer:
      if cleanupComplete: removeDir(tmp)
    let b = goldenBackend(tmp)
    createDir(tmp / "vm")
    writeFile(tmp / "vm" / "windows.qcow2", "")
    putEnv(FakeQemuEnv, "1")
    defer: delEnv(FakeQemuEnv)
    let started = b.startQemuWithAllocatedPort(tmp / "vm", 1, 64)
    defer:
      cleanupOwnedFakeChild(started.pid)
      cleanupComplete = true
    let monitorPath = qwaMonitorSocketPath(tmp / "vm")
    let waitUntil = epochTime() + 10.0
    while epochTime() < waitUntil and not socketExists(monitorPath):
      sleep(50)
    if fileExists(tmp / "vm" / "fake-qemu-error"):
      echo readFile(tmp / "vm" / "fake-qemu-error")
    check socketExists(monitorPath)

    # The guest says "running"; the process is alive. Not powered off.
    check not guestPoweredOff(monitorPath, started.pid)
    # Now it says "paused (shutdown)" — while the QEMU process is STILL
    # ALIVE. The monitor has to be what decides, or this reads as running.
    writeFile(tmp / "vm" / ".fake-poweroff", "")
    check guestPoweredOff(monitorPath, started.pid)
    # And it was the MONITOR that said so: the QEMU process is still running
    # at this instant, so the "socket gone plus process gone" fallback arm
    # cannot be what answered. Without this the assertion above would also be
    # satisfied by QEMU having simply died.
    check not qemuProcessGone(started.pid)
    check waitForGuestPowerOff(monitorPath, started.pid,
                               epochTime() + 5.0, pollMs = 100)
    check not qemuProcessGone(started.pid)

  test "a QEMU that exited with no monitor counts as powered off":
    # QEMU's default action on a guest power-off is to exit, taking the
    # socket with it, so the absence of both is the same event.
    let done = startProcess("/bin/sh", args = @["-c", "exit 0"],
                            options = {poUsePath})
    discard done.waitForExit()
    let gonePid = done.processID
    done.close()
    check guestPoweredOff("/nonexistent-vmh-monitor.sock", gonePid)

    let alive = startProcess("/bin/sh", args = @["-c", "sleep 30"],
                             options = {poUsePath})
    defer:
      try: alive.terminate()
      except CatchableError: discard
      alive.close()
    check not guestPoweredOff("/nonexistent-vmh-monitor.sock",
                              alive.processID)

  test "the power-off wait is bounded by the deadline it was given":
    let alive = startProcess("/bin/sh", args = @["-c", "sleep 30"],
                             options = {poUsePath})
    defer:
      try: alive.terminate()
      except CatchableError: discard
      alive.close()
    let start = epochTime()
    # A poll interval far LONGER than the deadline: the wait must be bounded
    # by the deadline it was given, not by the deadline rounded up to the
    # next poll. On a 90-minute build budget that difference is what decides
    # whether an operator gets an answer or watches a hung process.
    check not waitForGuestPowerOff("/nonexistent-vmh-monitor.sock",
                                   alive.processID,
                                   epochTime() + 1.0, pollMs = 30_000)
    let elapsed = epochTime() - start
    check elapsed >= 0.9
    check elapsed < 6.0

suite "Golden build: the install wait":

  test "the sentinel wait needs the marker, not merely a zero exit":
    let tmp = createTempDir("vmh-qwa-sentinel-", "")
    defer: removeDir(tmp)
    let silent = tmp / "sshpass-silent"
    writeExecutable(silent, "#!/bin/sh\nexit 0\n")
    let b = newQemuWindowsArmBackend(sshpassCmd = silent,
                                     stateDir = tmp / "state")
    # An SSH transport that succeeds without running anything must not read
    # as a finished install.
    check not b.installSentinelPresent(2244)

  test "the sentinel wait returns as soon as the install declares itself":
    let tmp = createTempDir("vmh-qwa-sentinel-ok-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    defer: delEnv(FakeSshDirEnv)
    check not b.installSentinelPresent(2245)
    writeFile(tmp / "ssh" / "sentinel", "")
    check b.installSentinelPresent(2245)
    check b.waitForInstallSentinel(2245, epochTime() + 5.0, pollMs = 100)

  test "the sentinel wait is bounded even when the poll exceeds its deadline":
    let tmp = createTempDir("vmh-qwa-sentinel-deadline-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    putEnv(FakeSshLogEnv, tmp / "ssh.log")
    defer:
      delEnv(FakeSshDirEnv)
      delEnv(FakeSshLogEnv)
    let start = epochTime()
    # Again with a poll interval longer than the deadline: an install wait
    # that overshoots by a poll is an install wait whose bound is a fiction.
    check not b.waitForInstallSentinel(2246, epochTime() + 1.0,
                                       pollMs = 30_000)
    let elapsed = epochTime() - start
    check elapsed >= 0.9
    check elapsed < 15.0
    let probes = readFile(tmp / "ssh.log").strip().splitLines()
    # A slow first process launch can use the entire deadline.
    check probes.len >= 1
    for p in probes:
      check QwaInstallSentinelPath in p

  test "the sentinel wait probes again until the install declares itself":
    let tmp = createTempDir("vmh-qwa-sentinel-repeat-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    let state = tmp / "first-probe"
    let log = tmp / "probes.log"
    # A real shell transport with controlled readiness: only its second
    # invocation reports the marker. This tests polling without a startup
    # speed assumption; the production probe still checks exit and output.
    writeFile(b.sshpassCmd, "#!/bin/sh\n" &
      "printf '%s\\n' \"$*\" >> " & quoteShell(log) & "\n" &
      "if [ -f " & quoteShell(state) & " ]; then\n" &
      "  printf '%s\\n' " & quoteShell(QwaInstallDoneMarker) & "\n" &
      "  exit 0\nfi\n: > " & quoteShell(state) & "\nexit 1\n")
    check b.waitForInstallSentinel(2247, epochTime() + 10.0, pollMs = 10)
    let probes = readFile(log).strip().splitLines()
    check probes.len == 2
    for probe in probes:
      check QwaInstallSentinelPath in probe

suite "Golden build: the freeze watchdog":
  ## MA4's fourth and fifth host runs: the guest stopped dead in the firmware
  ## on a boot after Windows Setup's first reboot — serial log frozen for 23
  ## minutes, target qcow2 for 30 — and the build spent its whole 90-minute
  ## deadline waiting for a sentinel from a guest that was no longer
  ## executing. Nothing in the harness could tell that from a slow install,
  ## because it was not looking.

  test "a frozen guest is power-cycled, and the install then finishes":
    let tmp = createTempDir("vmh-qwa-watchdog-recover-", "")
    defer: removeDir(tmp)
    let serial = tmp / "serial.log"
    let disk = tmp / "windows.qcow2"
    writeFile(serial, "frozen in the firmware\n")
    writeFile(disk, "")
    var cycles = 0
    var sentinel = false
    let watched = waitForInstallSentinelWatched(
      serial, disk, epochTime() + 30.0,
      sentinelPresent = (proc (): bool = sentinel),
      # The recovery is what makes the install finish: nothing else in this
      # test ever sets the sentinel.
      powerCycle = (proc () =
        inc cycles
        sentinel = true),
      freezeSec = 1, maxPowerCycles = 2, pollMs = 100)
    check watched.ok
    check watched.powerCycles == 1
    check cycles == 1

  test "the allowance runs out, and the build is failed rather than faked":
    let tmp = createTempDir("vmh-qwa-watchdog-exhaust-", "")
    defer: removeDir(tmp)
    let serial = tmp / "serial.log"
    let disk = tmp / "windows.qcow2"
    writeFile(serial, "")
    writeFile(disk, "")
    var cycles = 0
    let start = epochTime()
    let watched = waitForInstallSentinelWatched(
      serial, disk, epochTime() + 30.0,
      sentinelPresent = (proc (): bool = false),
      powerCycle = (proc () = inc cycles),
      freezeSec = 1, maxPowerCycles = 2, pollMs = 100)
    # Two cycles spent, then a refusal — NOT an eleventh attempt, and not a
    # success. A half-installed disk must never be reported as a golden.
    check not watched.ok
    check watched.powerCycles == 2
    check cycles == 2
    # And it gave up on the allowance rather than sitting out the deadline.
    check epochTime() - start < 25.0

  test "a guest that keeps moving is never power-cycled":
    let tmp = createTempDir("vmh-qwa-watchdog-quiet-", "")
    defer: removeDir(tmp)
    let serial = tmp / "serial.log"
    let disk = tmp / "windows.qcow2"
    writeFile(serial, "")
    writeFile(disk, "")
    var cycles = 0
    var probes = 0
    let watched = waitForInstallSentinelWatched(
      serial, disk, epochTime() + 30.0,
      sentinelPresent = (proc (): bool =
        inc probes
        # Writing to the disk on every probe is a guest that is installing.
        writeFile(disk, repeat('x', probes))
        probes >= 5),
      powerCycle = (proc () = inc cycles),
      freezeSec = 1, maxPowerCycles = 2, pollMs = 100)
    check watched.ok
    check watched.powerCycles == 0
    check cycles == 0

  test "the watchdog cannot outlive the build deadline":
    let tmp = createTempDir("vmh-qwa-watchdog-deadline-", "")
    defer: removeDir(tmp)
    let serial = tmp / "serial.log"
    let disk = tmp / "windows.qcow2"
    writeFile(serial, "")
    writeFile(disk, "")
    let start = epochTime()
    # A poll interval far longer than the deadline, and a freeze bound that
    # never fires: the bound that has to hold is the deadline.
    let watched = waitForInstallSentinelWatched(
      serial, disk, epochTime() + 1.0,
      sentinelPresent = (proc (): bool = false),
      powerCycle = (proc () = discard),
      freezeSec = 0, maxPowerCycles = 2, pollMs = 30_000)
    check not watched.ok
    check watched.powerCycles == 0
    let elapsed = epochTime() - start
    check elapsed >= 0.9
    check elapsed < 15.0

suite "Golden build: sysprep has to still be there a moment later":
  ## MA4's second host run: the launch reported success, sysprep logged four
  ## lines, reached "Beginning action execution from Cleanup.xml" and died
  ## one second in, killed with the SSH session's job object. The build then
  ## waited 20 minutes for a power-off from a process that no longer existed,
  ## with a perfectly installed guest sitting at its desktop.

  test "a live sysprep is seen, and the wait returns at once":
    let tmp = createTempDir("vmh-qwa-sysprep-live-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    createDir(tmp / "ssh")
    writeFile(tmp / "ssh" / "sysprep-running", "")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    defer: delEnv(FakeSshDirEnv)
    var alive = startProcess("/bin/sh", args = @["-c", "sleep 30"],
                             options = {poUsePath})
    defer:
      alive.terminate()
      discard alive.waitForExit()
      alive.close()
    check b.sysprepRunning(2250)
    let start = epochTime()
    check b.sysprepTookHold(2250, "/nonexistent-vmh-monitor.sock",
                            alive.processID, epochTime() + 60.0,
                            windowSec = 60, pollMs = 5_000)
    check epochTime() - start < 10.0

  test "a guest that already powered off counts as having taken hold":
    # A generalize normally runs for minutes, but the build must not fail
    # because sysprep beat the first poll to the finish line.
    let tmp = createTempDir("vmh-qwa-sysprep-off-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    createDir(tmp / "ssh")            # deliberately NOT reporting running
    putEnv(FakeSshDirEnv, tmp / "ssh")
    defer: delEnv(FakeSshDirEnv)
    var gone = startProcess("/bin/sh", args = @["-c", "exit 0"],
                            options = {poUsePath})
    discard gone.waitForExit()
    let pid = gone.processID
    gone.close()
    check not b.sysprepRunning(2251)
    check b.sysprepTookHold(2251, "/nonexistent-vmh-monitor.sock", pid,
                            epochTime() + 60.0, windowSec = 60,
                            pollMs = 5_000)

  test "a sysprep that died with its ssh session is caught, and bounded":
    let tmp = createTempDir("vmh-qwa-sysprep-dead-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    defer: delEnv(FakeSshDirEnv)
    var alive = startProcess("/bin/sh", args = @["-c", "sleep 30"],
                             options = {poUsePath})
    defer:
      alive.terminate()
      discard alive.waitForExit()
      alive.close()
    let start = epochTime()
    # Neither running nor powered off, and the window — not the build's whole
    # deadline — is what bounds the answer.
    check not b.sysprepTookHold(2252, "/nonexistent-vmh-monitor.sock",
                                alive.processID, epochTime() + 600.0,
                                windowSec = 1, pollMs = 30_000)
    let elapsed = epochTime() - start
    check elapsed >= 0.9
    check elapsed < 20.0

  test "the take-hold wait is bounded by the build deadline too":
    let tmp = createTempDir("vmh-qwa-sysprep-deadline-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    defer: delEnv(FakeSshDirEnv)
    var alive = startProcess("/bin/sh", args = @["-c", "sleep 30"],
                             options = {poUsePath})
    defer:
      alive.terminate()
      discard alive.waitForExit()
      alive.close()
    let start = epochTime()
    check not b.sysprepTookHold(2253, "/nonexistent-vmh-monitor.sock",
                                alive.processID, epochTime() - 1.0,
                                windowSec = 600, pollMs = 100)
    check epochTime() - start < 20.0

suite "Golden build: the install media keypress prompt":
  ## The defect MA4's first host run found, and the reason the fix has to
  ## stop as well as start. cdboot.efi will not hand over to Windows Setup
  ## until a key is pressed; the same prompt timing out on LATER boots is
  ## what makes Setup's own reboots fall past the still-first install media
  ## and onto the disk it is installing to. A keyer that never stopped would
  ## trade "the install never starts" for "the install restarts forever".

  test "a monitor command on an absent socket fails rather than raising":
    check not sendQemuMonitorCommand("/nonexistent-vmh-monitor.sock",
                                     "sendkey ret")

  test "keying STOPS once the guest starts writing to the target disk":
    # The load-bearing half. Setup's first reboot happens while the install
    # media is still ahead of the disk in BootOrder, so a key delivered then
    # restarts Setup from the ISO.
    let tmp = createTempDir("vmh-qwa-key-progress-", "")
    defer: removeDir(tmp)
    let disk = tmp / "windows.qcow2"
    writeFile(disk, newString(int(QwaInstallProgressBytes) + 1))
    check goldenDiskProgressed(disk)
    var alive = startProcess("/bin/sh", args = @["-c", "sleep 30"],
                             options = {poUsePath})
    defer:
      alive.terminate()
      discard alive.waitForExit()
      alive.close()
    let start = epochTime()
    let sent = answerInstallMediaKeyPrompt(
      tmp / "monitor.sock", disk, alive.processID,
      epochTime() + 30.0, windowSec = 30, intervalMs = 100)
    check sent == 0
    check epochTime() - start < 2.0

  test "keying is bounded by its own window when nothing ever happens":
    let tmp = createTempDir("vmh-qwa-key-window-", "")
    defer: removeDir(tmp)
    let disk = tmp / "windows.qcow2"
    writeFile(disk, "tiny")
    check not goldenDiskProgressed(disk)
    var alive = startProcess("/bin/sh", args = @["-c", "sleep 30"],
                             options = {poUsePath})
    defer:
      alive.terminate()
      discard alive.waitForExit()
      alive.close()
    let start = epochTime()
    discard answerInstallMediaKeyPrompt(
      tmp / "monitor.sock", disk, alive.processID,
      epochTime() + 30.0, windowSec = 1, intervalMs = 30_000)
    let elapsed = epochTime() - start
    # Bounded by windowSec, and not rounded up to the next poll interval —
    # this window sits inside the overall build deadline and must not eat it.
    check elapsed >= 0.9
    check elapsed < 6.0

  test "keying is bounded by the overall build deadline too":
    let tmp = createTempDir("vmh-qwa-key-deadline-", "")
    defer: removeDir(tmp)
    writeFile(tmp / "windows.qcow2", "tiny")
    var alive = startProcess("/bin/sh", args = @["-c", "sleep 30"],
                             options = {poUsePath})
    defer:
      alive.terminate()
      discard alive.waitForExit()
      alive.close()
    let start = epochTime()
    discard answerInstallMediaKeyPrompt(
      tmp / "monitor.sock", tmp / "windows.qcow2", alive.processID,
      epochTime() - 1.0, windowSec = 600, intervalMs = 100)
    check epochTime() - start < 2.0

  test "keying stops when the install boot has already died":
    let tmp = createTempDir("vmh-qwa-key-dead-", "")
    defer: removeDir(tmp)
    writeFile(tmp / "windows.qcow2", "tiny")
    var dead = startProcess("/bin/sh", args = @["-c", "exit 0"],
                            options = {poUsePath})
    discard dead.waitForExit()
    let pid = dead.processID
    dead.close()
    let start = epochTime()
    check answerInstallMediaKeyPrompt(
      tmp / "monitor.sock", tmp / "windows.qcow2", pid,
      epochTime() + 30.0, windowSec = 30, intervalMs = 100) == 0
    check epochTime() - start < 2.0

  test "a zero window presses nothing at all":
    let tmp = createTempDir("vmh-qwa-key-off-", "")
    defer: removeDir(tmp)
    writeFile(tmp / "windows.qcow2", "tiny")
    check answerInstallMediaKeyPrompt(
      tmp / "monitor.sock", tmp / "windows.qcow2", 0,
      epochTime() + 30.0, windowSec = 0) == 0

suite "The per-job boot: the reboot lifecycle":
  ## Runner-Fleet-M3-ARM-Wave MA4. The defect this suite exists for was NOT a
  ## regression: ``-no-reboot`` has been on the per-job vector since the
  ## backend was written, and it was harmless for as long as the fleet's
  ## Windows goldens were not sysprepped. A ``/generalize``d golden MUST
  ## reboot once, so the flag turned every per-job boot into a QEMU that
  ## exited rc=0 at ~38s with no SSH ever.
  ##
  ## WHAT THIS TIER CAN AND CANNOT SAY. The unit tier could not previously
  ## tell a bootable argument vector from an unbootable one — it asserted
  ## identity with HEAD, and HEAD was broken. It can now, in one specific and
  ## limited sense: the fake QEMU PERFORMS the mandatory reboot and takes
  ## QEMU's own decision on it from the argv it was handed, so restoring
  ## ``-no-reboot`` to production code makes the end-to-end tests below fail.
  ## What it still cannot say is that a real Windows guest reaches sshd; that
  ## is ``tests/e2e/t_qemu_windows_arm_per_job_boot_host.nim``, and it is the
  ## gate that should have caught this in the first place.

  setup:
    delEnv(FakeQemuEnv)
    delEnv(FakeSshDirEnv)
    delEnv(FakeFirstBootRebootEnv)
    delEnv(FakeBootLoopEnv)
    delEnv(FakeQmpRefuseEnv)

  teardown:
    delEnv(FakeQemuEnv)
    delEnv(FakeSshDirEnv)
    delEnv(FakeFirstBootRebootEnv)
    delEnv(FakeBootLoopEnv)
    delEnv(FakeQmpRefuseEnv)

  test "a guest that keeps rebooting is named, not waited out":
    ## The failure mode that allowing reboots at all introduces, and the
    ## reason the window is bounded rather than simply opened.
    let tmp = createTempDir("vmh-qwa-loop-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    let serial = tmp / QwaSerialLogName
    var banners = ""
    for _ in 1 .. QwaFirstBootMaxFirmwareBoots + 1:
      banners.add(FakeFirmwareBanner)
    writeFile(serial, banners)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")   # no ssh-ready flag: SSH never comes

    # A deadline far longer than this may take: the point is that the boot
    # allowance ends it, not the clock.
    let started = epochTime()
    let outcome = b.waitForFirstBootSshReady(0, 120, serial)
    check outcome.outcome == fbRebootLoop
    check outcome.firmwareBoots == QwaFirstBootMaxFirmwareBoots + 1
    check epochTime() - started < 30.0

  test "an unbounded wait still ends at its deadline":
    let tmp = createTempDir("vmh-qwa-loopoff-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    let serial = tmp / QwaSerialLogName
    var banners = ""
    for _ in 1 .. 20:
      banners.add(FakeFirmwareBanner)
    writeFile(serial, banners)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")

    # maxFirmwareBoots <= 0 disables the bound; the deadline is then the only
    # limit, and it is honoured.
    let started = epochTime()
    let outcome = b.waitForFirstBootSshReady(1, 1, serial,
                                             maxFirmwareBoots = 0)
    check outcome.outcome == fbSshTimedOut
    check epochTime() - started < 30.0

  test "a generalized golden's mandatory reboot is survived, then revoked":
    ## THE END-TO-END GATE FOR MA4'S BLOCKER, at the unit tier: the real
    ## ``revertToBaseline``, the real per-job argv, a real ``qemu-img``
    ## overlay, and a fake QEMU that reboots once before SSH exists exactly
    ## as a generalized guest does.
    ##
    ## Two things are asserted and both are load-bearing. The instance comes
    ## up AT ALL — with ``-no-reboot`` the fake QEMU exits at the reboot and
    ## this fails. And ``set-action reboot=shutdown`` really reached QEMU
    ## before the handle was returned, which is where the one-shot lifecycle
    ## guarantee now lives.
    let tmp = createTempDir("vmh-qwa-perjob-ok-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp, sshReadyTimeoutSec = 45)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    putEnv(FakeQemuEnv, "1")
    putEnv(FakeFirstBootRebootEnv, "1")

    # A real golden: a real qcow2 and the manifest that makes it admissible.
    let golden = tmp / "win-arm-runner-0400"
    createDir(golden)
    createGoldenDisk("qemu-img", golden, 1)
    writeFile(golden / "QEMU_EFI.fd", "efi code")
    writeFile(golden / "QEMU_VARS.fd", "efi vars")
    writeFile(golden / QwaGoldenManifestName, "{}")

    b.provisionBaseline(BaselineSpec(name: "win-arm-runner",
                                     sourceImage: golden, cpus: 1,
                                     memoryMB: 64))
    let vm = b.revertToBaseline("win-arm-runner")
    let vmDir = vm.extra["vmDir"]
    try:
      # It rebooted, and the harness saw both boots.
      check qwaFirmwareBootCount(vmDir / QwaSerialLogName) == 2
      check vm.extra["firmwareBoots"] == "2"
      # One-shot semantics were restored over QMP, with the right value, and
      # the handle says so.
      check vm.extra["rebootAction"] == QwaOneShotRebootAction
      check vm.extra["qmpSocket"] == qwaQmpSocketPath(vmDir)
      let qmpLog = readFile(vmDir / QmpLogName)
      check "qmp_capabilities" in qmpLog
      check "set-action" in qmpLog
      check "\"reboot\":\"" & QwaOneShotRebootAction & "\"" in
        qmpLog.replace(" ", "")
      # And the negotiation came FIRST. A real QMP monitor refuses every
      # command until it has, so a client that got this order wrong would
      # work against a lenient fake and fail on m3.
      check qmpLog.find("qmp_capabilities") < qmpLog.find("set-action")
    finally:
      b.stopAndCleanup(vm, deleteVm = true)
    check not dirExists(vmDir)

  test "a QEMU that will not take set-action fails the instance":
    ## The refusal path, which is the whole reason the transition is checked
    ## rather than fired and forgotten: a guest that answered SSH but can
    ## still reboot itself must NOT be handed to a job.
    let tmp = createTempDir("vmh-qwa-perjob-refuse-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp, sshReadyTimeoutSec = 45)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    putEnv(FakeQemuEnv, "1")
    putEnv(FakeFirstBootRebootEnv, "1")
    putEnv(FakeQmpRefuseEnv, "1")

    let golden = tmp / "win-arm-runner-0401"
    createDir(golden)
    createGoldenDisk("qemu-img", golden, 1)
    writeFile(golden / "QEMU_EFI.fd", "efi code")
    writeFile(golden / "QEMU_VARS.fd", "efi vars")
    writeFile(golden / QwaGoldenManifestName, "{}")

    b.provisionBaseline(BaselineSpec(name: "win-arm-runner",
                                     sourceImage: golden, cpus: 1,
                                     memoryMB: 64))
    var raised = false
    var handedOut: VmHandle = nil
    try:
      handedOut = b.revertToBaseline("win-arm-runner")
    except GuestBootFailureError as e:
      raised = true
      check "one-shot reboot semantics could not be restored" in e.msg
      check "refused" in e.msg
    if handedOut != nil:
      # Only reachable when the refusal has been IGNORED, i.e. under a
      # falsification of this very assertion. Reap it anyway: a leaked fake
      # QEMU inherits this process's stdout and keeps it open forever, so a
      # falsified build would hang the suite instead of failing it.
      b.stopAndCleanup(handedOut, deleteVm = true)
    check raised
    # And it was torn down, not leaked: nothing may survive a refusal.
    check dirExists(b.stateDir / "instances")
    var leftovers = 0
    for kind, _ in walkDir(b.stateDir / "instances"):
      if kind == pcDir:
        inc leftovers
    check leftovers == 0

suite "Golden build: the whole run":

  setup:
    delEnv(FakeQemuEnv)
    delEnv(FakeSshDirEnv)
    delEnv(FakeSshLogEnv)
    delEnv("VMH_GOLDEN_FAKE_SSH_VMDIR")
    # Keep the space precondition out of the way: it has its own suite, and
    # a busy CI host must not turn these into false failures.
    putEnv("VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB", "0")

  teardown:
    delEnv("VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB")
    delEnv(FakeQemuEnv)
    delEnv(FakeSshDirEnv)
    delEnv(FakeSshLogEnv)
    delEnv("VMH_GOLDEN_FAKE_SSH_VMDIR")
    delEnv("VMH_QEMU_EFI_CODE_TEMPLATE")
    delEnv("VMH_QEMU_EFI_VARS_TEMPLATE")
    delEnv("VMH_QEMU_FIRMWARE_DIR")

  test "a missing Windows ISO is refused before anything is allocated":
    let tmp = createTempDir("vmh-qwa-run-noiso-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    var raised = false
    try:
      discard b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = tmp / "golden", windowsIso = tmp / "absent.iso",
        autounattendIso = tmp / "absent-unattend.iso"))
    except VmHarnessError as e:
      raised = true
      check "absent.iso" in e.msg
      check "operator-supplied" in e.msg
    check raised
    check not dirExists(tmp / "golden")

  test "a missing answer-file ISO names the script that builds it":
    let tmp = createTempDir("vmh-qwa-run-nounattend-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    writeFile(tmp / "win.iso", "iso")
    var raised = false
    try:
      discard b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = tmp / "golden", windowsIso = tmp / "win.iso",
        autounattendIso = tmp / "absent-unattend.iso"))
    except VmHarnessError as e:
      raised = true
      check "build-autounattend-iso.sh" in e.msg
    check raised

  test "a build into a directory already holding a golden is refused":
    let tmp = createTempDir("vmh-qwa-run-inplace-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    writeFile(tmp / "win.iso", "iso")
    writeFile(tmp / "unattend.iso", "iso")
    let live = tmp / "win-arm-runner-live"
    createDir(live)
    writeFile(live / "windows.qcow2", "backs a live overlay")
    var raised = false
    try:
      discard b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = live, windowsIso = tmp / "win.iso",
        autounattendIso = tmp / "unattend.iso", diskGB = 1))
    except VmHarnessError as e:
      raised = true
      check "refusing to build a golden into" in e.msg
    check raised
    check readFile(live / "windows.qcow2") == "backs a live overlay"

  test "a failed install leaves the build directory and both logs behind":
    # A Windows install that goes wrong has no console and no SSH. If the
    # failure path tidies up, the run is undiagnosable and the next attempt
    # is a blind 60-minute retry.
    let tmp = createTempDir("vmh-qwa-run-failstart-", "")
    defer: removeDir(tmp)
    let deadQemu = tmp / "dead-qemu"
    writeExecutable(deadQemu, """#!/bin/sh
: > serial.log
: > qemu.log
exit 1
""")
    let b = goldenBackend(tmp, qemuCmd = deadQemu)
    writeFile(tmp / "win.iso", "iso")
    writeFile(tmp / "unattend.iso", "iso")
    writeFile(tmp / "code.fd", "efi code")
    writeFile(tmp / "vars.fd", "efi vars")
    putEnv("VMH_QEMU_EFI_CODE_TEMPLATE", tmp / "code.fd")
    putEnv("VMH_QEMU_EFI_VARS_TEMPLATE", tmp / "vars.fd")
    let golden = tmp / "win-arm-runner-0200"
    var raised = false
    try:
      discard b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = golden, windowsIso = tmp / "win.iso",
        autounattendIso = tmp / "unattend.iso", diskGB = 1,
        deadlineSec = 20))
    except VmHarnessError as e:
      raised = true
      check (golden / "serial.log") in e.msg
      check (golden / "qemu.log") in e.msg
      check "left in place" in e.msg
      check "NEW versioned directory" in e.msg
    check raised
    check dirExists(golden)
    check fileExists(golden / "serial.log")
    check fileExists(golden / "qemu.log")
    # The disk really was allocated, so the guard above is the thing that
    # stops the directory being reused rather than an accident of emptiness.
    check fileExists(golden / QwaBaseDiskName)

  test "an install that never finishes captures the guest's screen":
    ## MA4's first host run: Windows had installed, provisioned, written the
    ## sentinel and was sitting at its desktop, and the harness could not
    ## reach it. The serial log ended at the firmware handover and said
    ## nothing, because a Windows guest never writes to the serial port. The
    ## framebuffer is the only artifact that says where a headless install
    ## actually stopped, so the failure path has to grab it while QEMU is
    ## still alive — once it exits there is nothing left to dump.
    let tmp = createTempDir("vmh-qwa-run-screen-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    writeFile(tmp / "win.iso", "iso")
    writeFile(tmp / "unattend.iso", "iso")
    writeFile(tmp / "code.fd", "efi code")
    writeFile(tmp / "vars.fd", "efi vars")
    putEnv("VMH_QEMU_EFI_CODE_TEMPLATE", tmp / "code.fd")
    putEnv("VMH_QEMU_EFI_VARS_TEMPLATE", tmp / "vars.fd")
    createDir(tmp / "ssh")            # deliberately NO sentinel file
    putEnv(FakeSshDirEnv, tmp / "ssh")
    putEnv(FakeQemuEnv, "1")
    defer:
      delEnv(FakeSshDirEnv)
      delEnv(FakeQemuEnv)
    let golden = tmp / "win-arm-runner-0400"
    var raised = false
    try:
      discard b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = golden, windowsIso = tmp / "win.iso",
        autounattendIso = tmp / "unattend.iso", diskGB = 1, cpus = 1,
        memoryMB = 64, deadlineSec = 12, keyPressWindowSec = 1))
    except VmHarnessError as e:
      raised = true
      # The message names it, and names it as the thing to read first.
      check (golden / QwaGoldenScreenshotName) in e.msg
      check "framebuffer" in e.msg
      # ...and the sentinel diagnosis is in the message too, so an operator
      # who sees an EFI shell on that screen knows what it means.
      check "cdboot.efi" in e.msg
    check raised
    # The dump really landed, and it came from the monitor the argv publishes.
    check fileExists(golden / QwaGoldenScreenshotName)
    check readFile(golden / QwaGoldenScreenshotName).startsWith("P6")
    let monitorCmds = readFile(golden / MonitorLogName)
    check ("screendump " & (golden / QwaGoldenScreenshotName)) in monitorCmds

  test "a sysprep that does not take hold fails the build, fast and by name":
    ## The whole orchestration, with a guest that accepts the sysprep launch
    ## and then does nothing — which is exactly what MA4's second host run
    ## saw when sysprep was killed with the SSH session. Before this check
    ## the build spent its entire remaining deadline waiting for a power-off
    ## that could never come, and then blamed sysprep for not shutting down.
    let tmp = createTempDir("vmh-qwa-run-nohold-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    writeFile(tmp / "win.iso", "iso")
    writeFile(tmp / "unattend.iso", "iso")
    writeFile(tmp / "code.fd", "efi code")
    writeFile(tmp / "vars.fd", "efi vars")
    putEnv("VMH_QEMU_EFI_CODE_TEMPLATE", tmp / "code.fd")
    putEnv("VMH_QEMU_EFI_VARS_TEMPLATE", tmp / "vars.fd")
    createDir(tmp / "ssh")
    writeFile(tmp / "ssh" / "sentinel", "")   # the install finished...
    # ...but NO `sysprep-running` file, and no VMH_GOLDEN_FAKE_SSH_VMDIR, so
    # the launch is accepted and then nothing whatsoever happens.
    delEnv("VMH_GOLDEN_FAKE_SSH_VMDIR")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    putEnv(FakeQemuEnv, "1")
    defer:
      delEnv(FakeSshDirEnv)
      delEnv(FakeQemuEnv)
    let golden = tmp / "win-arm-runner-0500"
    var raised = false
    let start = epochTime()
    try:
      discard b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = golden, windowsIso = tmp / "win.iso",
        autounattendIso = tmp / "unattend.iso", diskGB = 1, cpus = 1,
        memoryMB = 64, deadlineSec = 25, keyPressWindowSec = 1))
    except VmHarnessError as e:
      raised = true
      # It has to say THIS, not "sysprep did not power the guest off": the
      # two have different fixes and only one of them is sysprep's fault.
      check "was launched but was not running" in e.msg
      check "killed with the SSH session" in e.msg
      check "setupact.log" in e.msg
    check raised
    # The launch really was issued — the guest is not being blamed for a
    # command it never received.
    check fileExists(tmp / "ssh" / "sysprep-launched")
    check epochTime() - start < 120.0

  test "a missing UEFI firmware template fails with the fix in the message":
    # Without firmware QEMU boots nothing at all, and an install that never
    # starts looks exactly like one that is merely slow.
    let tmp = createTempDir("vmh-qwa-run-nofw-", "")
    let savedCode = getEnv("VMH_QEMU_EFI_CODE")
    createDir(tmp / "empty")
    putEnv("VMH_QEMU_FIRMWARE_DIR", tmp / "empty")
    putEnv("VMH_QEMU_EFI_CODE_TEMPLATE", tmp / "absent.fd")
    delEnv("VMH_QEMU_EFI_CODE")
    defer:
      removeDir(tmp)
      delEnv("VMH_QEMU_FIRMWARE_DIR")
      if savedCode.len > 0: putEnv("VMH_QEMU_EFI_CODE", savedCode)
    var raised = false
    try:
      stageGoldenFirmware(tmp)
    except VmHarnessError as e:
      raised = true
      check "VMH_QEMU_EFI_CODE_TEMPLATE" in e.msg
      check "edk2-aarch64-code.fd" in e.msg
    check raised

  test "an explicit firmware directory is used instead of the search list":
    let tmp = createTempDir("vmh-qwa-run-fw-", "")
    let savedCode = getEnv("VMH_QEMU_EFI_CODE")
    let savedVars = getEnv("VMH_QEMU_EFI_VARS")
    createDir(tmp / "fw")
    writeFile(tmp / "fw" / "edk2-aarch64-code.fd", "code")
    writeFile(tmp / "fw" / "edk2-arm-vars.fd", "vars")
    createDir(tmp / "build")
    putEnv("VMH_QEMU_FIRMWARE_DIR", tmp / "fw")
    delEnv("VMH_QEMU_EFI_CODE")
    delEnv("VMH_QEMU_EFI_VARS")
    defer:
      removeDir(tmp)
      delEnv("VMH_QEMU_FIRMWARE_DIR")
      if savedCode.len > 0: putEnv("VMH_QEMU_EFI_CODE", savedCode)
      if savedVars.len > 0: putEnv("VMH_QEMU_EFI_VARS", savedVars)
    stageGoldenFirmware(tmp / "build")
    # A per-build, writable vars file: Windows Setup writes its boot entry
    # into it, and a shared one would be written by every guest at once.
    check readFile(tmp / "build" / "QEMU_EFI.fd") == "code"
    check readFile(tmp / "build" / "QEMU_VARS.fd") == "vars"
    check fpUserWrite in getFilePermissions(tmp / "build" / "QEMU_VARS.fd")
    # And the staged pair is what the boot argv resolves.
    let args = buildQemuWindowsArmArgs(tmp / "build", 2248)
    check args.anyIt("if=pflash" in it and
                     (tmp / "build" / "QEMU_VARS.fd") in it)

  test "install, sysprep and power-off drive through to a validated golden":
    ## The orchestration end to end, with no Windows and no hypervisor: a
    ## real qemu-img allocates the real disk, the real argument vector is
    ## handed to a fake QEMU that binds the real forwarded port and serves a
    ## real monitor socket, the real probe and sysprep commands go to a fake
    ## sshpass, and power-off is observed on the monitor while the QEMU
    ## process is still alive — so the assertion cannot pass by accident of
    ## the process having died.
    let tmp = createTempDir("vmh-qwa-run-ok-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    writeFile(tmp / "win.iso", "pretend windows iso")
    writeFile(tmp / "unattend.iso", "pretend answer iso")
    writeFile(tmp / "code.fd", "efi code")
    writeFile(tmp / "vars.fd", "efi vars")
    putEnv("VMH_QEMU_EFI_CODE_TEMPLATE", tmp / "code.fd")
    putEnv("VMH_QEMU_EFI_VARS_TEMPLATE", tmp / "vars.fd")
    createDir(tmp / "ssh")
    writeFile(tmp / "ssh" / "sentinel", "")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    putEnv(FakeQemuEnv, "1")

    let golden = tmp / "win-arm-runner-0300"
    putEnv("VMH_GOLDEN_FAKE_SSH_VMDIR", golden)

    # keyPressWindowSec is shortened from the shipped 180s only so the suite
    # stays fast: the fake guest never writes to the disk, so the early exit
    # on disk growth cannot fire and the window would run in full. The
    # shipped default is pinned in "the keypress window's default is the
    # shipped one".
    let produced = b.buildWindowsArmGolden(newGoldenBuildSpec(
      buildDir = golden, windowsIso = tmp / "win.iso",
      autounattendIso = tmp / "unattend.iso", recipeDir = recipeDir(),
      diskGB = 1, cpus = 1, memoryMB = 64, deadlineSec = 60,
      keyPressWindowSec = 2))

    check produced == absolutePath(golden)
    # The keypress that answers cdboot.efi really went to the monitor, and
    # it STOPPED before the power-off watch started: every `sendkey` precedes
    # every `info status`. A keyer still running during Setup's reboots is
    # the failure mode this ordering rules out.
    let monitorCmds = readFile(golden / MonitorLogName).strip().splitLines().
      mapIt(it.strip())
    var lastKey = -1
    var firstStatus = -1
    for i, cmd in monitorCmds:
      if cmd == "sendkey " & QwaInstallMediaKey:
        lastKey = i
      elif cmd == "info status" and firstStatus < 0:
        firstStatus = i
    check lastKey >= 0
    check firstStatus >= 0
    check lastKey < firstStatus
    # The consuming path accepts it — and by the ADMISSION check, not just
    # the structural one, so a build that produced a disk and no manifest
    # could not pass here either.
    check validateWindowsArmVmDir(produced) == absolutePath(golden)
    check requireWindowsArmGolden(produced) == absolutePath(golden)
    # ...sysprep really was issued, with the real command...
    check fileExists(tmp / "ssh" / "sysprep-launched")
    let issued = readFile(tmp / "ssh" / "sysprep-command")
    check "Win32_Process" in issued
    check "Start-Process" notin issued   # measured not to survive the session
    check "/generalize" in issued
    check ("/unattend:" & QwaSysprepAnswerGuestPath) in issued
    # ...the diagnostics are there even on the success path...
    check fileExists(golden / "serial.log")
    check fileExists(golden / "qemu.log")
    # ...and the golden says what it was built from.
    let m = parseJson(readFile(golden / QwaGoldenManifestName))
    check m["schema"].getStr == QwaGoldenManifestSchema
    check m["windowsIso"]["sha256"].getStr == fileSha256(tmp / "win.iso")
    check m["answerFiles"]["autounattend.xml"].getStr ==
      fileSha256(recipeDir() / "autounattend.xml")
    check m["builtAt"].getStr.len >= 20
    check m["diskGB"].getInt == 1
    # A second build into the same directory is refused, which is what makes
    # a rebuild an addition rather than an overwrite.
    expect VmHarnessError:
      discard b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = golden, windowsIso = tmp / "win.iso",
        autounattendIso = tmp / "unattend.iso", diskGB = 1))

  test "a build whose guest freezes power-cycles it and still finishes":
    ## MA4's blocker, driven end to end. The guest stops executing on one of
    ## the firmware boots the install needs; the only recovery measured to
    ## work on the real host is a power cycle of QEMU **and swtpm**, because
    ## `swtpm socket` exits with its client and a Windows 11 guest will not
    ## boot without a TPM.
    ##
    ## freezeSec is 1 rather than the shipped 600 only so the suite stays
    ## fast; the shipped value is pinned in "the shipped freeze bound is the
    ## measured one".
    let tmp = createTempDir("vmh-qwa-run-frozen-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    writeFile(tmp / "win.iso", "pretend windows iso")
    writeFile(tmp / "unattend.iso", "pretend answer iso")
    writeFile(tmp / "code.fd", "efi code")
    writeFile(tmp / "vars.fd", "efi vars")
    putEnv("VMH_QEMU_EFI_CODE_TEMPLATE", tmp / "code.fd")
    putEnv("VMH_QEMU_EFI_VARS_TEMPLATE", tmp / "vars.fd")
    createDir(tmp / "ssh")
    # NO sentinel up front: only a power cycle can produce one here.
    putEnv(FakeSshDirEnv, tmp / "ssh")
    putEnv(FakeQemuEnv, "1")
    putEnv(FakeFreezeEnv, "1")
    putEnv(FakeSwtpmLogEnv, tmp / "swtpm.log")
    defer:
      delEnv(FakeFreezeEnv)
      delEnv(FakeSwtpmLogEnv)

    let golden = tmp / "win-arm-runner-0301"
    putEnv("VMH_GOLDEN_FAKE_SSH_VMDIR", golden)

    let produced = b.buildWindowsArmGolden(newGoldenBuildSpec(
      buildDir = golden, windowsIso = tmp / "win.iso",
      autounattendIso = tmp / "unattend.iso", recipeDir = recipeDir(),
      diskGB = 1, cpus = 1, memoryMB = 64, deadlineSec = 180,
      keyPressWindowSec = 2, freezeSec = 1, maxPowerCycles = 2))

    check produced == absolutePath(golden)
    check requireWindowsArmGolden(produced) == absolutePath(golden)
    # The guest really was booted more than once...
    check fileExists(golden / FakeBootCountName)
    # ...and swtpm really came back with it. One start would mean a recovery
    # that brings QEMU up against a TPM socket that no longer exists, which
    # is the exact error the first hand-run power cycle on m3 hit.
    let swtpmStarts = readFile(tmp / "swtpm.log").strip().splitLines()
    check swtpmStarts.len >= 2
    for line in swtpmStarts:
      check "type=unixio,path=" in line

  test "a guest that never comes back is refused, not promoted":
    ## The other half of the watchdog contract: the allowance is spent and
    ## the build FAILS. A half-installed disk must never be finalized, and
    ## the message has to say power cycles were spent so the next operator
    ## reads "the guest kept freezing" and not "the answer file is wrong".
    let tmp = createTempDir("vmh-qwa-run-frozen-dead-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    writeFile(tmp / "win.iso", "pretend windows iso")
    writeFile(tmp / "unattend.iso", "pretend answer iso")
    writeFile(tmp / "code.fd", "efi code")
    writeFile(tmp / "vars.fd", "efi vars")
    putEnv("VMH_QEMU_EFI_CODE_TEMPLATE", tmp / "code.fd")
    putEnv("VMH_QEMU_EFI_VARS_TEMPLATE", tmp / "vars.fd")
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    putEnv(FakeQemuEnv, "1")
    delEnv(FakeFreezeEnv)   # a guest that is simply never done
    let golden = tmp / "win-arm-runner-0302"
    putEnv("VMH_GOLDEN_FAKE_SSH_VMDIR", golden)

    var msg = ""
    try:
      discard b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = golden, windowsIso = tmp / "win.iso",
        autounattendIso = tmp / "unattend.iso", recipeDir = recipeDir(),
        diskGB = 1, cpus = 1, memoryMB = 64, deadlineSec = 60,
        keyPressWindowSec = 0, freezeSec = 1, maxPowerCycles = 1))
    except VmHarnessError as e:
      msg = e.msg
    check msg.len > 0
    check "1 power cycle(s) were spent on a frozen guest, of 1 allowed" in msg
    # Nothing was promoted: no manifest, so the admission check refuses it.
    check not fileExists(golden / QwaGoldenManifestName)
    expect ValueError:
      discard requireWindowsArmGolden(golden)
    # And the diagnostics are still there.
    check fileExists(golden / "serial.log")
