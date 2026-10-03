# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Portable Windows-ARM golden contracts, independent of host hypervisors.
## Every case was moved unchanged from t_qemu_windows_arm_golden_build.
## Real files exercise argv construction, recipe contents, admission, progress,
## free-space policy, SHA-256 and manifest provenance. No guest, QEMU process
## or mock is used here. The Unix monitor/QMP and real child-process lifecycle
## fixture stays in that original program and runs on POSIX hosts.
import std/[json, os, sequtils, strutils, tempfiles, times, unittest]
import vm_harness
import qwa_fixture_paths

suite "QemuWindowsArmBackend golden build":
  ## The golden install boot and the guards that keep a rebuild from
  ## corrupting the instances running on top of the golden it replaces.

  test "install argv boots the media and defers the empty target disk":
    let tmp = createTempDir("vmh-qemu-win-arm-install-", "")
    defer: removeDir(tmp)
    writeFile(tmp / "windows.qcow2", "")
    writeFile(tmp / "QEMU_EFI.fd", "")
    let winIso = tmp / "win11-arm64.iso"
    let unattendIso = tmp / "autounattend.iso"
    writeFile(winIso, "")
    writeFile(unattendIso, "")

    let args = buildQemuWindowsArmInstallArgs(
      tmp, winIso, unattendIso, 2240, cpus = 6, memoryMB = 12288)

    # Install media first, answer file second, target disk last. The disk is
    # empty at this point, so anything else leaves the firmware with nothing
    # bootable.
    check "usb-storage,bus=usb.0,drive=installcd,bootindex=0" in args
    check "ide-cd,bus=sata.0,drive=unattendcd,bootindex=1" in args
    check "nvme,drive=disk0,serial=winarm0,bootindex=2" in args

    # The two ISOs go on DIFFERENT controllers, and the split is measured.
    #
    # MEASURED on m3 2026-09-15: with BOTH CD-ROMs on the xHCI as
    # usb-storage, two of five runs froze in the firmware on a boot after
    # Setup's first reboot, the serial log ending on exactly the two
    # `UsbBootExecCmd: Success to Exec 0x0 Cmd` lines UsbMassStorageDxe emits
    # — one per CD-ROM — without ever reaching a boot option. EDK2
    # re-enumerates the media on every boot and the install needs three, so a
    # per-boot hazard is a per-build one.
    #
    # The install ISO cannot move: it is the one the firmware has to boot,
    # and this EDK2 (edk2-stable202408, the ArmVirtQemu build QEMU ships) has
    # no ATA/AHCI driver — MEASURED, with the install ISO on ich9-ahci the
    # firmware created no boot option for it at all and dropped to the EFI
    # shell. Nor can it go on virtio-scsi, which the firmware CAN boot:
    # Win11 ARM64's sources/boot.wim carries storahci.sys and USBSTOR.SYS but
    # neither vioscsi.sys nor viostor.sys, so WinPE would have no way to read
    # install.wim.
    check "qemu-xhci,id=usb" in args

    # The answer-file ISO CAN move, because nothing boots it — Windows reads
    # it by drive letter in the specialize and oobeSystem passes, and
    # storahci.sys is inbox in both boot.wim and install.wim. Its being
    # invisible to the firmware is the whole point.
    check "ich9-ahci,id=sata" in args
    check args.countIt("usb-storage" in it) == 1
    # Controllers have to precede the devices that name their buses: a drive
    # on a bus QEMU has not created yet is a startup failure, not a warning.
    check args.find("ich9-ahci,id=sata") <
          args.find("ide-cd,bus=sata.0,drive=unattendcd,bootindex=1")
    check args.find("qemu-xhci,id=usb") <
          args.find("usb-storage,bus=usb.0,drive=installcd,bootindex=0")

    # A KEYBOARD. MEASURED on m3 2026-09-15: without one the install cannot
    # start. \EFI\BOOT\BOOTAA64.EFI on a Windows install ISO is cdboot.efi,
    # which waits for a keypress and returns EFI_TIMEOUT when none arrives;
    # the firmware then logs `failed to start Boot0001 ...: Time out` and
    # drops to the EFI shell, and the build sits out its whole deadline
    # having installed nothing. -display none plus an output-only
    # `-serial file:` leaves the machine with no input device at all, so the
    # keyboard has to be added here and the key injected on the monitor.
    check "usb-kbd,bus=usb.0" in args
    # It has to hang off the controller the install boot creates, and after
    # it: a keyboard on no bus is a QEMU startup failure, not a warning.
    check args.find("qemu-xhci,id=usb") < args.find("usb-kbd,bus=usb.0")
    check "id=installcd,file=" & winIso & ",media=cdrom,readonly=on,if=none" in args
    check "id=unattendcd,file=" & unattendIso &
          ",media=cdrom,readonly=on,if=none" in args

    # Windows setup reboots several times before OOBE. Exiting on the first
    # one leaves a half-installed disk that looks like a hung build.
    check "-no-reboot" notin args
    # And it never stops being rebootable, so it needs no way to revoke that
    # at runtime. Keeping the QMP socket OUT of this vector is what keeps the
    # golden on disk reproducible from this source: the argv that built it
    # did not have one.
    check "-qmp" notin args
    check not args.anyIt("vmh-qwa-qmp" in it)

    # The install writes the base disk directly; overlays are a per-job
    # concern and must not appear here.
    check "id=disk0,file=" & tmp / "windows.qcow2" &
          ",format=qcow2,if=none,cache=writeback,discard=unmap" in args

    # Still headless, still measurable.
    check "-display" in args
    check args[args.find("-display") + 1] == "none"
    check args.anyIt(it.startsWith("file:") and it.endsWith("serial.log"))

  test "the per-job boot allows its one mandatory reboot, and can revoke it":
    ## THIS TEST USED TO PIN THE DEFECT. Until 2026-09-15 it asserted
    ## ``-no-reboot`` was PRESENT, and it was: a ``/generalize``d golden
    ## reboots once between its specialize and oobeSystem passes
    ## (``repro-sysprep.xml``, and the recipe README §7 says so), ``sshd`` is
    ## started by the FirstLogonCommands that run AFTER that reboot, so
    ## ``-no-reboot`` made QEMU exit rc=0 at ~38s and ``revertToBaseline``
    ## NEVER reached SSH. The gate certified the vector as unchanged three
    ## times while it was byte-identically unbootable.
    ##
    ## So the assertions here are now about the SHAPE the boot needs, in both
    ## directions: the reboot is allowed at start-time, AND the channel that
    ## can revoke it at runtime is present. "The argv is byte-identical to
    ## HEAD" is not a correctness claim and never was; the claim that the
    ## per-job boot WORKS belongs to the host tier
    ## (``tests/e2e/t_qemu_windows_arm_per_job_boot_host.nim``) and to the
    ## end-to-end test in "The per-job boot: the reboot lifecycle" below.
    let tmp = createTempDir("vmh-qemu-win-arm-runargv-", "")
    defer: removeDir(tmp)
    writeFile(tmp / "windows.qcow2", "")

    let args = buildQemuWindowsArmArgs(tmp, 2241)
    # Not -no-reboot, which is -action reboot=shutdown by another name.
    check "-no-reboot" notin args
    check "-action" in args
    check args[args.find("-action") + 1] ==
      "reboot=" & QwaFirstBootRebootAction
    check QwaFirstBootRebootAction == "reset"
    # And the runtime channel that takes it back once SSH is reached. HMP has
    # no set-action, so this has to be a SECOND socket and a different one
    # from the monitor.
    check "-qmp" in args
    check args[args.find("-qmp") + 1] ==
      "unix:" & qwaQmpSocketPath(tmp) & ",server=on,wait=off"
    check qwaQmpSocketPath(tmp) != qwaMonitorSocketPath(tmp)
    check "-monitor" in args
    check args[args.find("-monitor") + 1] ==
      "unix:" & qwaMonitorSocketPath(tmp) & ",server=on,wait=off"
    check "nvme,drive=disk0,serial=winarm0,bootindex=1" in args
    check not args.anyIt("usb-storage" in it)
    # And no keyboard, and no xHCI to hang one off. This argument vector is
    # already DEPLOYED on m3; the install boot's keypress workaround must not
    # leak into the per-job shape that every CI job boots.
    check not args.anyIt("usb-kbd" in it)
    check not args.anyIt("qemu-xhci" in it)
    # Nor the install boot's AHCI CD-ROM controller. A golden carries no
    # install media, so a SATA controller on the per-job boot is either dead
    # weight or a sign the run path grew a dependency on the build inputs.
    check not args.anyIt("ich9-ahci" in it)
    check not args.anyIt("ide-cd" in it)
    check not args.anyIt("sata" in it)

  test "a golden build refuses to overwrite an existing golden":
    let tmp = createTempDir("vmh-qemu-win-arm-guard-", "")
    defer: removeDir(tmp)
    let existing = tmp / "win-arm-runner-0001"
    createDir(existing)
    writeFile(existing / "windows.qcow2", "pretend this backs a live overlay")

    # Overwriting it would not fail at the qcow2 layer: every overlay naming
    # it as a backing store would silently continue against different data.
    expect VmHarnessError:
      prepareGoldenBuildDir(existing)
    check readFile(existing / "windows.qcow2") ==
      "pretend this backs a live overlay"

  test "a golden build accepts a fresh or empty directory":
    let tmp = createTempDir("vmh-qemu-win-arm-fresh-", "")
    defer: removeDir(tmp)
    let fresh = tmp / "win-arm-runner-0002"
    prepareGoldenBuildDir(fresh)
    check dirExists(fresh)
    # Re-running before any disk exists is fine; a failed build leaves a
    # directory nothing ever points at.
    prepareGoldenBuildDir(fresh)
    check dirExists(fresh)

  test "golden disk allocation rejects a nonsense size":
    let tmp = createTempDir("vmh-qemu-win-arm-size-", "")
    defer: removeDir(tmp)
    expect VmHarnessError:
      createGoldenDisk("qemu-img", tmp, 0)

suite "Golden build space precondition":
  ## Pure policy, so the thresholds can be exercised without a filesystem.

  setup:
    delEnv("VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB")

  test "a build that cannot finish is refused":
    let v = goldenBuildSpaceVerdict(freeGB = 40, diskGB = QwaDefaultGoldenDiskGB)
    check v.fatal
    check "refusing to start a golden build" in v.message
    check "40GB free" in v.message

  test "a tight but survivable build warns instead of failing":
    # Enough for the image, not enough to also absorb a saturated fleet.
    let v = goldenBuildSpaceVerdict(freeGB = 100, diskGB = QwaDefaultGoldenDiskGB)
    check not v.fatal
    check "concurrent CI" in v.message

  test "an idle host with room says nothing":
    let v = goldenBuildSpaceVerdict(
      freeGB = QwaGoldenInstallPeakGB + QwaGoldenBuildSlackGB +
               QwaFleetPeakGB + 1,
      diskGB = QwaDefaultGoldenDiskGB)
    check not v.fatal
    check v.message == ""

  test "a smaller requested image lowers the floor":
    # qcow2 cannot outgrow its requested size, so a 20GB image needs less
    # than the full install-peak estimate.
    check qwaGoldenFloorGB(20) == 20 + QwaGoldenBuildSlackGB
    check qwaGoldenFloorGB(QwaDefaultGoldenDiskGB) ==
      QwaGoldenInstallPeakGB + QwaGoldenBuildSlackGB
    check not goldenBuildSpaceVerdict(freeGB = 40, diskGB = 20).fatal
    check goldenBuildSpaceVerdict(freeGB = 40,
                                  diskGB = QwaDefaultGoldenDiskGB).fatal

  test "an operator can override the estimate":
    putEnv("VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB", "5")
    defer: delEnv("VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB")
    check qwaGoldenFloorGB(QwaDefaultGoldenDiskGB) == 5
    check not goldenBuildSpaceVerdict(freeGB = 10,
                                      diskGB = QwaDefaultGoldenDiskGB).fatal

  test "a garbage override falls back to the computed floor":
    putEnv("VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB", "not-a-number")
    defer: delEnv("VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB")
    check qwaGoldenFloorGB(QwaDefaultGoldenDiskGB) ==
      QwaGoldenInstallPeakGB + QwaGoldenBuildSlackGB

  test "unknown free space proceeds rather than blocking":
    # A failed statvfs must not be reported as a full disk.
    let warning = checkGoldenBuildSpace("/nonexistent-path-for-vmh-test",
                                        QwaDefaultGoldenDiskGB)
    check "could not determine free space" in warning

  test "free space on a real path is plausible":
    let tmp = createTempDir("vmh-qemu-win-arm-space-", "")
    defer: removeDir(tmp)
    when defined(posix):
      check freeSpaceGB(tmp) >= 0
    else:
      check freeSpaceGB(tmp) == -1

# ---------------------------------------------------------------------------
# New in MA3: the orchestration.
# ---------------------------------------------------------------------------

suite "Golden build: the harness agrees with the checked-in recipe":
  ## These are cross-file assertions on purpose. The sentinel and the sysprep
  ## answer file are a CONTRACT between Nim code and an XML answer file that
  ## nothing else links together; if either side is edited alone the build
  ## polls forever for a file that is never written, and a Windows install
  ## that never finishes is indistinguishable from one that is merely slow.

  test "the sentinel polled for is the one autounattend.xml writes":
    let xml = readFile(recipeDir() / "autounattend.xml")
    check QwaInstallSentinelPath in xml
    # ...and it is written by the FirstLogonCommands pass, not merely
    # mentioned in a comment.
    let firstLogon = xml.find("<FirstLogonCommands>")
    check firstLogon >= 0
    check xml.find(QwaInstallSentinelPath, firstLogon) > firstLogon
    # The recipe writes it only after sshd is confirmed running; that
    # condition is what makes the sentinel mean "install finished" rather
    # than "Windows booted".
    check "Get-Service -Name sshd" in xml

  test "the sysprep answer file named is the one the recipe stages on C:":
    let xml = readFile(recipeDir() / "autounattend.xml")
    check QwaSysprepAnswerGuestPath in xml
    check fileExists(recipeDir() / "repro-sysprep.xml")
    # The ISO-to-C: copy the FirstLogonCommands perform is what puts it
    # there; sysprep is invoked with /unattend: pointing at the destination.
    check ("copy /Y %i:\\repro-sysprep.xml " & QwaSysprepAnswerGuestPath) in xml

  test "the recipe opens sshd on EVERY firewall profile, and asserts it":
    # MEASURED on m3 2026-09-15, and it cost a whole build deadline against a
    # perfectly provisioned guest. `Add-WindowsCapability OpenSSH.Server`
    # installs an inbound allow for TCP 22 scoped to the PRIVATE profile
    # only. QEMU's user-mode network is unidentified, so Windows classifies
    # it PUBLIC, whose policy is BlockInbound. Everything inside the guest
    # reads healthy — sshd Running, 0.0.0.0:22 LISTENING, NIC up on
    # 10.0.2.15 — and every forwarded SYN is dropped before it reaches sshd.
    #
    # The old recipe created a rule only when NONE existed, so the
    # capability's Private-only rule made it a no-op on exactly this path.
    # Nothing host-side can observe any of this: the harness's only view of
    # the guest is the SSH that is blocked. So it is asserted on the recipe.
    let ps1 = readFile(recipeDir() / "provision-openssh.ps1")
    check "-Profile Any" in ps1
    check "New-NetFirewallRule" in ps1
    # It must not be conditional on there being no rule already — that is
    # the defect.
    check "if (-not (Get-NetFirewallRule" notin ps1
    # And it must FAIL provisioning when the rule is not what it asked for:
    # a golden whose sshd is firewalled off is indistinguishable from one
    # that never finished installing.
    check "is not an Any-profile allow" in ps1

  test "sysprep carries every flag the golden depends on":
    let argv = buildSysprepCommand()
    check argv[0] == QwaSysprepExePath
    # /generalize is load-bearing: without it every ephemeral clone of this
    # golden shares one machine SID.
    check "/generalize" in argv
    check "/oobe" in argv
    check "/shutdown" in argv
    check ("/unattend:" & QwaSysprepAnswerGuestPath) in argv
    # /mode:vm is what the checked-in recipe README documents as the
    # invocation that produced a working golden, and is sound only because
    # every instance boots the identical machine shape this backend builds.
    check "/mode:vm" in argv
    check "/mode:vm" notin buildSysprepCommand(modeVm = false)
    # Dropping /generalize must not be reachable by flipping that knob.
    check "/generalize" in buildSysprepCommand(modeVm = false)

  test "sysprep outlives the ssh session that starts it":
    # /shutdown powers the guest off under the session that issued it, and a
    # generalize runs 10-20 minutes. A session-bound invocation is one hangup
    # away from a half-generalized disk that still looks like a golden.
    #
    # `Start-Process` is NOT session-independent, which is the assumption
    # this code shipped on until MA4's host run disproved it. Windows OpenSSH
    # puts every process of a session into a job object and kills the job
    # when the session ends; a Start-Process child stays in that job.
    # MEASURED on m3 2026-09-15 with a harmless long-running process:
    # Start-Process -> 0 survivors two seconds after the session closed,
    # Win32_Process.Create -> still running 25 seconds later, because the WMI
    # provider host creates it and it is therefore in no session job at all.
    let remote = buildSysprepRemoteCommand()
    check "Win32_Process" in remote
    check "Invoke-CimMethod" in remote
    check "-MethodName Create" in remote
    # And NOT the thing that was measured not to work.
    check "Start-Process" notin remote
    # A refused creation has to exit non-zero: a sysprep that never started
    # must be reported, not waited for.
    check ".ReturnValue -ne 0" in remote
    check "exit 1" in remote

    for flag in ["/generalize", "/oobe", "/shutdown", "/mode:vm",
                 "/unattend:" & QwaSysprepAnswerGuestPath]:
      check flag in remote
    check QwaSysprepExePath in remote

  test "no remote command carries a bare $, which the guest would eat":
    # provision-openssh.ps1 sets sshd's DefaultShell to powershell.exe, so an
    # OUTER PowerShell parses what arrives over SSH before the inner
    # `powershell.exe -Command "..."` string exists — and that outer parse
    # expands $ inside double quotes. MEASURED on m3 2026-09-15: a sysprep
    # launch that stashed its result in $r arrived in the guest as
    # `rc=' + .ReturnValue`, a parse error, and the build died at the very
    # last step of a 20-minute install. Nothing about the fake sshpass can
    # catch that, so the constraint is asserted on the strings themselves.
    for pair in {
        "buildSysprepRemoteCommand": buildSysprepRemoteCommand(),
        "buildSysprepRemoteCommand(modeVm = false)":
          buildSysprepRemoteCommand(modeVm = false),
        "buildSysprepRunningProbe": buildSysprepRunningProbe(),
        "buildInstallSentinelProbe": buildInstallSentinelProbe()}:
      checkpoint(pair[0] & ": " & pair[1])
      check '$' notin pair[1]

  test "the sysprep liveness probe cannot be satisfied by an echo of itself":
    let probe = buildSysprepRunningProbe()
    check "Get-Process sysprep" in probe
    # The marker printed differs from anything in the probe's own subject, so
    # an ssh wrapper that echoes its argument cannot look like a live sysprep
    # — the same trap QwaInstallDoneMarker exists to avoid.
    check QwaSysprepRunningMarker notin "Get-Process sysprep"
    check QwaSysprepRunningMarker == "VMH-SYSPREP-RUNNING"

  test "the install probe cannot be satisfied by an echo of itself":
    let probe = buildInstallSentinelProbe()
    check QwaInstallSentinelPath in probe
    check "Test-Path" in probe
    # The marker the probe PRINTS is deliberately not a substring of the
    # command, so an ssh wrapper that echoes its argument cannot look like a
    # finished install.
    check QwaInstallDoneMarker notin QwaInstallSentinelPath
    check probe.count(QwaInstallDoneMarker) == 1
    check "Write-Output" in probe

suite "Golden build: power-off is read off the monitor, not off SSH":

  test "the monitor path watched is the one the argv publishes":
    let tmp = createTempDir("vmh-qwa-monitor-", "")
    defer: removeDir(tmp)
    writeFile(tmp / "windows.qcow2", "")
    let expected = "unix:" & qwaMonitorSocketPath(tmp) & ",server=on,wait=off"
    for args in [buildQemuWindowsArmArgs(tmp, 2242),
                 buildQemuWindowsArmInstallArgs(tmp, tmp / "a.iso",
                                                tmp / "b.iso", 2243)]:
      check "-monitor" in args
      check args[args.find("-monitor") + 1] == expected

  test "an info status reply is read off the status line only":
    check not monitorTextSaysPoweredOff("")
    check not monitorTextSaysPoweredOff(
      "QEMU 9.2.0 monitor\n(qemu) info status\r\nVM status: running\r\n(qemu) ")
    check monitorTextSaysPoweredOff(
      "QEMU 9.2.0 monitor\n(qemu) info status\r\n" &
      "VM status: paused (shutdown)\r\n(qemu) ")
    # The word can appear in the echoed command or the banner while the guest
    # is plainly still running; only the status line decides.
    check not monitorTextSaysPoweredOff(
      "(qemu) system_powerdown -- shutdown requested\r\nVM status: running\r\n")
    check not monitorTextSaysPoweredOff("no status here at all")

suite "Golden build: the freeze watchdog":
  ## MA4's fourth and fifth host runs: the guest stopped dead in the firmware
  ## on a boot after Windows Setup's first reboot — serial log frozen for 23
  ## minutes, target qcow2 for 30 — and the build spent its whole 90-minute
  ## deadline waiting for a sentinel from a guest that was no longer
  ## executing. Nothing in the harness could tell that from a slow install,
  ## because it was not looking.

  test "a guest that writes to either surface is not stalled":
    let tmp = createTempDir("vmh-qwa-progress-", "")
    defer: removeDir(tmp)
    let serial = tmp / "serial.log"
    let disk = tmp / "windows.qcow2"
    writeFile(serial, "boot\n")
    writeFile(disk, "x")
    var w = newGuestProgressWatch(serial, disk, now = 1000.0)
    # Nothing moved: the stall clock keeps running.
    check not observeGuestProgress(w, now = 1100.0)
    check guestStalledSec(w, now = 1100.0) == 100.0

    # The serial console alone is enough, and it resets the clock.
    writeFile(serial, "boot\nmore firmware chatter\n")
    check observeGuestProgress(w, now = 1200.0)
    check guestStalledSec(w, now = 1200.0) == 0.0

    # So is the target disk alone. Windows says nothing on the serial port
    # once the firmware hands over, so for most of a healthy install this is
    # the ONLY signal there is — which is exactly why both are watched.
    writeFile(disk, "xxxxxxxx")
    check observeGuestProgress(w, now = 1300.0)
    check guestStalledSec(w, now = 1300.0) == 0.0

  test "a freeze is both surfaces still, past a bound, and nothing less":
    let tmp = createTempDir("vmh-qwa-frozen-", "")
    defer: removeDir(tmp)
    let serial = tmp / "serial.log"
    let disk = tmp / "windows.qcow2"
    writeFile(serial, "")
    writeFile(disk, "")
    var w = newGuestProgressWatch(serial, disk, now = 0.0)
    discard observeGuestProgress(w, now = 100.0)
    # Under the bound is not a freeze. Windows Setup has phases longer than
    # this with no disk growth at all -- Add-WindowsCapability
    # OpenSSH.Server took eight minutes on its own on m3.
    check not guestFrozen(w, freezeSec = 600, now = 599.0)
    check guestFrozen(w, freezeSec = 600, now = 600.0)
    # A missing file is not a freeze signal of its own: it reads as size 0
    # and only counts once it has been 0 for the whole bound.
    var missing = newGuestProgressWatch(tmp / "nope", tmp / "also-nope",
                                        now = 0.0)
    check not guestFrozen(missing, freezeSec = 600, now = 100.0)
    check guestFrozen(missing, freezeSec = 600, now = 900.0)
    # And a zero or negative bound disables the watchdog outright.
    check not guestFrozen(w, freezeSec = 0, now = 1e9)
    check not guestFrozen(w, freezeSec = -1, now = 1e9)

  test "the shipped freeze bound is the measured one":
    # Ten minutes, and the reason is in QwaInstallFreezeSec: the two runs that
    # froze sat still for 23 and 30 minutes, and the longest quiet phase a
    # healthy install has is the ~8 minute OpenSSH capability install.
    check QwaInstallFreezeSec == 600
    check QwaInstallMaxPowerCycles == 2
    # The default has to BE the shipped constant, not a copy of its value:
    # a watchdog whose default is 0 is a watchdog that never fires.
    let tmp = createTempDir("vmh-qwa-freeze-default-", "")
    defer: removeDir(tmp)
    var w = newGuestProgressWatch(tmp / "serial.log", tmp / "windows.qcow2",
                                  now = 0.0)
    check not guestFrozen(w, now = QwaInstallFreezeSec.float - 1.0)
    check guestFrozen(w, now = QwaInstallFreezeSec.float)

suite "Golden build: the install media keypress prompt":
  ## The defect MA4's first host run found, and the reason the fix has to
  ## stop as well as start. cdboot.efi will not hand over to Windows Setup
  ## until a key is pressed; the same prompt timing out on LATER boots is
  ## what makes Setup's own reboots fall past the still-first install media
  ## and onto the disk it is installing to. A keyer that never stopped would
  ## trade "the install never starts" for "the install restarts forever".

  test "the keypress window's default is the shipped one":
    # The e2e test below shortens it to keep the suite fast, so the default
    # has to be pinned somewhere that a shortened test cannot satisfy.
    let spec = newGoldenBuildSpec(buildDir = "/nonexistent",
                                  windowsIso = "/nonexistent",
                                  autounattendIso = "/nonexistent")
    check spec.keyPressWindowSec == QwaInstallKeyPressWindowSec
    check QwaInstallKeyPressWindowSec >= 60
    check QwaInstallMediaKey == "ret"

suite "Golden build: finalize drops the install media":

  test "a finished directory validates and boots with no install media":
    let tmp = createTempDir("vmh-qwa-finalize-", "")
    defer: removeDir(tmp)
    let golden = tmp / "win-arm-runner-0100"
    createDir(golden)
    writeFile(golden / "windows.qcow2", "golden")
    writeFile(golden / "QEMU_EFI.fd", "")
    writeFile(golden / "QEMU_VARS.fd", "")
    # Build leftovers that must not be adopted as part of the artifact.
    writeFile(golden / QwaOverlayDiskName, "leftover overlay")
    writeFile(golden / QwaInstanceLockName, "")
    createDir(golden / "tpm")
    writeFile(golden / "tpm" / ".lock", "")

    let resolved = finalizeGoldenDir(golden)
    check resolved == absolutePath(golden)
    check not fileExists(golden / QwaOverlayDiskName)
    check not fileExists(golden / QwaInstanceLockName)
    check not fileExists(golden / "tpm" / ".lock")
    check validateWindowsArmVmDir(golden) == absolutePath(golden)

    # The ISOs are build INPUTS. Nothing in the consuming boot may reference
    # them, because on the host that consumes the golden they are not there.
    let boot = buildQemuWindowsArmArgs(golden, 2247)
    check not boot.anyIt("media=cdrom" in it)
    check not boot.anyIt("usb-storage" in it)
    check not boot.anyIt("ide-cd" in it)
    check "id=disk0,file=" & golden / "windows.qcow2" &
          ",format=qcow2,if=none,cache=writeback,discard=unmap" in boot

  test "a build that produced no disk is refused, not promoted":
    let tmp = createTempDir("vmh-qwa-finalize-bad-", "")
    defer: removeDir(tmp)
    let empty = tmp / "win-arm-runner-0101"
    createDir(empty)
    var raised = false
    try:
      discard finalizeGoldenDir(empty)
    except VmHarnessError as e:
      raised = true
      check "windows.qcow2" in e.msg
    check raised

suite "Golden build: the manifest":
  ## The artifact that was lost had no way to say what it was built from.

  test "an answer-file ISO older than the recipe it carries is refused":
    # FOUND on m3 2026-09-15, before the first host run, and it would have
    # poisoned every manifest produced from it:
    # guest-recipes/windows-arm-base/build/autounattend.iso was 7.6 MiB from
    # 2026-07-06 while the recipe files were from 2026-09-08 — it predated
    # the Git-for-Windows, PowerShell-7 and credential-expiry changes. The
    # manifest digests the RECIPE FILES; the guest installs what is on the
    # ISO. Nothing regenerates the ISO when a recipe file changes, because
    # build/ is a gitignored artifact built by hand, so the two drift in
    # silence and the golden claims provenance it does not have.
    let tmp = createTempDir("vmh-qwa-stale-iso-", "")
    defer: removeDir(tmp)
    let recipe = tmp / "recipe"
    createDir(recipe)
    let iso = tmp / "autounattend.iso"
    writeFile(iso, "an ISO built in July")
    for name in QwaRecipeAnswerFiles:
      writeFile(recipe / name, "edited in September")
    let isoTime = fromUnix(1_700_000_000)
    setLastModificationTime(iso, isoTime)
    for name in QwaRecipeAnswerFiles:
      setLastModificationTime(recipe / name, isoTime + initDuration(days = 60))

    check staleAnswerIsoRecipeFiles(iso, recipe).len == QwaRecipeAnswerFiles.len

    # And the build refuses BEFORE spending an hour on it.
    let b = newQemuWindowsArmBackend(qemuCmd = "/nonexistent-qemu",
                                     stateDir = tmp / "state")
    writeFile(tmp / "win.iso", "pretend windows iso")
    var raised = false
    try:
      discard b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = tmp / "build", windowsIso = tmp / "win.iso",
        autounattendIso = iso, recipeDir = recipe, diskGB = 1))
    except VmHarnessError as e:
      raised = true
      check "OLDER than the recipe files" in e.msg
      check "build-autounattend-iso.sh" in e.msg
    check raised
    # It refused, so it must not have started a build directory either.
    check not dirExists(tmp / "build")

    # Rebuilt after the edits, it is accepted.
    setLastModificationTime(iso, isoTime + initDuration(days = 90))
    check staleAnswerIsoRecipeFiles(iso, recipe).len == 0

  test "the recorded vm-harness version tracks the package version":
    let nimble = readFile(repoRoot() / "vm_harness.nimble")
    check ("version       = \"" & QwaVmHarnessVersion & "\"") in nimble

  test "a digest is a real SHA-256 of the file's CONTENT":
    let tmp = createTempDir("vmh-qwa-sha-", "")
    defer: removeDir(tmp)
    let empty = tmp / "empty"
    writeFile(empty, "")
    check fileSha256(empty) ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let abc = tmp / "abc"
    writeFile(abc, "abc")
    check fileSha256(abc) ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  test "the manifest identifies the ISO, the recipe and the answer files":
    let tmp = createTempDir("vmh-qwa-manifest-", "")
    defer: removeDir(tmp)
    let golden = tmp / "win-arm-runner-0102"
    createDir(golden)
    let winIso = tmp / "win11-arm64.iso"
    let unattendIso = tmp / "autounattend.iso"
    writeFile(winIso, "pretend windows iso")
    writeFile(unattendIso, "pretend answer iso")

    let path = writeGoldenManifest(GoldenManifestInputs(
      baseline: "win-arm-runner", buildDir: golden, diskGB: 64,
      windowsIso: winIso, autounattendIso: unattendIso,
      recipeDir: recipeDir(), builtAt: "2026-09-15T00:00:00Z"))
    check path == golden / QwaGoldenManifestName
    let m = parseJson(readFile(path))

    check m["schema"].getStr == QwaGoldenManifestSchema
    check m["baseline"].getStr == "win-arm-runner"
    check m["builtAt"].getStr == "2026-09-15T00:00:00Z"
    check m["vmHarnessVersion"].getStr == QwaVmHarnessVersion
    check m["diskGB"].getInt == 64

    # The ISO is pinned by CONTENT, not by the path it happened to sit at.
    check m["windowsIso"]["sha256"].getStr == fileSha256(winIso)
    check m["autounattendIso"]["sha256"].getStr == fileSha256(unattendIso)
    check m["windowsIso"]["sha256"].getStr !=
          m["autounattendIso"]["sha256"].getStr

    # Every checked-in answer file the recipe contributes is digested.
    for name in QwaRecipeAnswerFiles:
      check m["answerFiles"].hasKey(name)
      check m["answerFiles"][name].getStr ==
        fileSha256(recipeDir() / name)
      check m["answerFiles"][name].getStr.len == 64

    # The recipe commit, when the recipe lives in a git checkout.
    let commit = m["recipe"]["commit"].getStr
    if dirExists(repoRoot() / ".git"):
      check commit.len == 40
      check commit.allIt(it in {'0' .. '9', 'a' .. 'f'})
    check m["recipe"]["dir"].getStr == recipeDir()

  test "a different ISO produces a different manifest":
    let tmp = createTempDir("vmh-qwa-manifest-diff-", "")
    defer: removeDir(tmp)
    createDir(tmp / "a")
    createDir(tmp / "b")
    writeFile(tmp / "iso-a", "iso a")
    writeFile(tmp / "iso-b", "iso b")
    writeFile(tmp / "unattend", "u")
    proc digestOf(iso, dir: string): string =
      discard writeGoldenManifest(GoldenManifestInputs(
        baseline: "win-arm-runner", buildDir: dir, diskGB: 64,
        windowsIso: iso, autounattendIso: tmp / "unattend",
        recipeDir: recipeDir(), builtAt: "2026-09-15T00:00:00Z"))
      parseJson(readFile(dir / QwaGoldenManifestName))["windowsIso"]["sha256"]
        .getStr
    check digestOf(tmp / "iso-a", tmp / "a") !=
          digestOf(tmp / "iso-b", tmp / "b")

  test "a machine SID is the account SID without its RID":
    # What the host tier compares across two clones. A golden that skipped
    # /generalize gives both clones the same value.
    check machineSidFromUserSid("S-1-5-21-1004336348-1177238915-682003330-500") ==
      "S-1-5-21-1004336348-1177238915-682003330"
    check machineSidFromUserSid(
      "  S-1-5-21-1004336348-1177238915-682003330-1001  ") ==
      "S-1-5-21-1004336348-1177238915-682003330"
    check machineSidFromUserSid("not-a-sid") == ""
    check machineSidFromUserSid("") == ""
    check machineSidFromUserSid("S-1-5") == ""

suite "The per-job boot: the reboot lifecycle":

  test "firmware boots are counted off the serial console":
    let tmp = createTempDir("vmh-qwa-bootcount-", "")
    defer: removeDir(tmp)
    let serial = tmp / QwaSerialLogName

    # No log at all is "the firmware has not spoken yet", not an error.
    check qwaFirmwareBootCount(serial) == 0
    check qwaFirmwareBootCount("") == 0

    writeFile(serial, FakeFirmwareBanner & "SyncPcrAllocations!\n")
    check qwaFirmwareBootCount(serial) == 1
    # A guest reset appends; the chardev stays open across it.
    let f = open(serial, fmAppend)
    f.write("BdsDxe: starting Boot0003\n" & FakeFirmwareBanner)
    f.close()
    check qwaFirmwareBootCount(serial) == 2
    # And the marker is the one the REAL firmware prints, not a paraphrase.
    check QwaFirmwareBannerMarker in
      readFile(currentSourcePath().parentDir.parentDir.parentDir /
               "src" / "vm_harness" / "backends" / "qemu_windows_arm.nim")

  test "the shipped reboot allowance is the measured one, doubled":
    # MEASURED on m3 2026-09-15: a healthy first boot of the real golden
    # shows EXACTLY TWO banners, and SSH answered at 52s.
    check QwaFirstBootMaxFirmwareBoots == 4
    check QwaFirstBootRebootAction == "reset"
    check QwaOneShotRebootAction == "shutdown"

  test "the shipped SSH-ready deadline is the production one":
    # The per-job end-to-end tests below shorten this deliberately. The
    # default a real instance gets must not move with them.
    check newQemuWindowsArmBackend().sshReadyTimeoutSec == 300

suite "Golden build: only a FINISHED golden is admissible":
  ## MEASURED on m3 2026-09-15, and the reason this suite exists: after MA4's
  ## five host runs, SIX directories sat under
  ## /private/var/lib/vm-harness/qemu-windows-arm/golden/ — 12-15 GB each,
  ## every one of them holding a windows.qcow2 and none of them holding a
  ## manifest, because the golden build creates the disk EMPTY as its first
  ## act and writes the manifest as its LAST. The structural check accepted
  ## all six as baselines to boot CI jobs from.
  ##
  ## MA3's contract deliberately RETAINS failed builds for diagnosis, so the
  ## directories are not the bug; admitting them is. This campaign exists
  ## because a golden could not be identified, and its rule is that an
  ## artifact must be identifiable AS one.

  test "a retained failed build is NOT admissible as a golden":
    let tmp = createTempDir("vmh-qwa-admit-failed-", "")
    defer: removeDir(tmp)
    # Exactly the shape of win-arm-runner-20260915T102158Z on m3: a large,
    # entirely plausible disk from an install that got part-way and stopped.
    writeFile(tmp / QwaBaseDiskName, "a 15 GB half-installed Windows")
    writeFile(tmp / "serial.log", "")
    writeFile(tmp / "qemu.log", "")
    createDir(tmp / "tpm")

    # The structural check still accepts it — it only ever asked whether
    # there is a disk, and that is all the overlay path needs to know.
    check validateWindowsArmVmDir(tmp) == absolutePath(tmp)

    # The admission check does not, and says why.
    var raised = false
    try:
      discard requireWindowsArmGolden(tmp)
    except ValueError as e:
      raised = true
      check QwaGoldenManifestName in e.msg
      check "NOT a finished golden" in e.msg
      check "failed" in e.msg
    check raised

  test "the consuming path refuses one too, rather than booting jobs off it":
    let tmp = createTempDir("vmh-qwa-admit-provision-", "")
    defer: removeDir(tmp)
    let failedBuild = tmp / "win-arm-runner-20260915T102158Z"
    createDir(failedBuild)
    writeFile(failedBuild / QwaBaseDiskName, "half an install")

    let b = newQemuWindowsArmBackend(qemuCmd = "/nonexistent-qemu",
                                     stateDir = tmp / "state")
    var raised = false
    try:
      b.provisionBaseline(BaselineSpec(name: "win-arm-runner",
                                       sourceImage: failedBuild))
    except VmHarnessError as e:
      raised = true
      check QwaGoldenManifestName in e.msg
    check raised

  test "a finished golden is admissible":
    let tmp = createTempDir("vmh-qwa-admit-ok-", "")
    defer: removeDir(tmp)
    writeFile(tmp / QwaBaseDiskName, "golden")
    writeFile(tmp / QwaGoldenManifestName, "{}")
    check requireWindowsArmGolden(tmp) == absolutePath(tmp)

  test "an absent or diskless directory is refused before the manifest":
    let tmp = createTempDir("vmh-qwa-admit-empty-", "")
    defer: removeDir(tmp)
    expect ValueError:
      discard requireWindowsArmGolden(tmp / "nope")
    expect ValueError:
      discard requireWindowsArmGolden(tmp)
    # A manifest with no disk is not a golden either.
    writeFile(tmp / QwaGoldenManifestName, "{}")
    expect ValueError:
      discard requireWindowsArmGolden(tmp)

