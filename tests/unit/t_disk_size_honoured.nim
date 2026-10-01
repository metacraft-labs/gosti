# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Every cloning backend honours the requested per-job disk size.
##
## A per-job clone used to inherit the golden's disk size whatever
## ``--disk-gb`` said (libvirt's CoW overlay, qcow2 import and media-boot
## overlay, qemu-boot's overlay, UTM's clone, Hyper-V's differencing clone
## and qcow2 conversion; the Tart and
## Windows-ARM QEMU backends have their own gates). The rules asserted here,
## per backend:
##
## * a clone smaller than the request is grown before the guest boots;
## * a clone already at least that large is not touched — disks never shrink;
## * an EXPLICIT request below the golden's size is refused with
##   ``DiskSizeTooSmallError`` before anything is created;
## * a DEFAULTED request below the golden's size keeps the golden's size,
##   and for boot-from-media IMAGES a defaulted size (sized for an ISO's blank
##   disk) never resizes the image at all;
## * once the guest is reachable its system volume is grown (growpart +
##   resize2fs on Linux, ``Resize-Partition`` on Windows) and VERIFIED, and a
##   volume that still does not span the disk fails by name
##   (``GuestDiskNotGrownError``).
##
## MOCK JUSTIFICATION (workspace policy). ``qemu-img`` is REAL: every image is
## a real qcow2 and every size asserted is what ``qemu-img info`` reads back.
## The hypervisor front-ends are shell-script fakes passed through each
## backend's command fields — ``virsh``/``virt-install`` (libvirt needs a
## running libvirtd and KVM), a QEMU that only reads back the disk it was
## given (a real boot is the host tier's job), ``utmctl`` (UTM exists only on macOS; the fake
## clones a bundle the way UTM lays one out, ``<name>.utm/Data/*.qcow2``) —
## and so are ``ssh``/``sshpass``, because there is no guest behind them: they
## answer the backend's real ``hostname``/``echo ready`` probes and the real
## encoded PowerShell growth script with the volume size a test chooses. The
## guest-growth decision itself is also driven through ``FakeGuestBackend``,
## an in-process ``execInGuest`` script, for the same reason. Hyper-V cannot
## run here at all, so its coverage is the rendered PowerShell only.
##
## NOT VERIFIED ON REAL HARDWARE by this file: that UTM names a clone's
## bundle ``<name>.utm`` in its documents folder and accepts a clone whose
## qcow2 was grown with ``qemu-img resize``; that ``Resize-VHD`` grows a
## differencing VHDX on the Windows hosts; that Windows' ``Resize-Partition``
## extends ``C:`` on the recipes' goldens.

import std/[base64, os, osproc, options, strutils, tables, tempfiles, unittest]
import vm_harness

when not defined(posix):
  {.error: "t_disk_size_honoured uses shell-script fakes (POSIX only)".}

proc writeExecutable(path, body: string) =
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc qemuImg(args: varargs[string]) =
  let r = execCmdEx("qemu-img " & args.join(" "))
  doAssert r.exitCode == 0, r.output

proc makeQcow2(path: string, gib: int) =
  qemuImg("create", "-q", "-f", "qcow2", path, $gib & "G")

proc virtualSize(path: string): int64 =
  let r = execCmdEx("qemu-img info -U --output=json " & quoteShell(path))
  doAssert r.exitCode == 0, r.output
  parseQemuImgVirtualSize(r.output)

proc decodePowershell(argv: seq[string]): string =
  let raw = decode(argv[^1])
  for i in countup(0, raw.len - 1, 2):
    result.add(raw[i])

# ---------------------------------------------------------------------------
# The shared decisions.

type FakeGuestBackend = ref object of VmBackend
  ## A guest reduced to its ``execInGuest`` answers.
  calls: seq[seq[string]]
  volumeBytes: int64          ## what the Windows script reports
  rootBytes: seq[int64]       ## successive ``df`` answers on Linux

method execInGuest(b: FakeGuestBackend, vm: VmHandle,
                   env: Table[string, string], cmd: seq[string],
                   stdin: string = "", timeoutSec: int = 600): ExecResult =
  b.calls.add(cmd)
  if cmd[0] == "powershell":
    return ExecResult(exitCode: 0,
                      stdout: VolumeBytesMarker & $b.volumeBytes & "\n")
  if cmd[^1] == LinuxRootFsBytesScript:
    let v = if b.rootBytes.len > 1: b.rootBytes[0] else: b.rootBytes[^1]
    if b.rootBytes.len > 1: b.rootBytes.delete(0)
    return ExecResult(exitCode: 0, stdout: $v & "\n")
  ExecResult(exitCode: 0)

suite "sizing decision":
  test "grow, keep and refuse":
    check planDiskResize(20 * GiB, 50 * GiB, false) == drGrow
    check planDiskResize(20 * GiB, 50 * GiB, true) == drGrow
    check planDiskResize(50 * GiB, 50 * GiB, false) == drKeep
    check planDiskResize(20 * GiB, 0, false) == drKeep
    check planDiskResize(80 * GiB, 50 * GiB, true) == drKeep
    check planDiskResize(80 * GiB, 50 * GiB, false) == drRefuse

suite "in-guest growth":
  let vm = VmHandle(name: "guest")

  test "Windows: C: is extended with Resize-Partition and verified":
    let b = FakeGuestBackend(id: biLibvirt, volumeBytes: 49 * GiB)
    ensureGuestDiskGrown(b, vm, goWindows, 50 * GiB)
    check b.calls.len == 1
    check b.calls[0][0 .. 4] == @["powershell", "-NoLogo", "-NoProfile",
                                  "-NonInteractive", "-EncodedCommand"]
    let script = decodePowershell(b.calls[0])
    check "Resize-Partition -DriveLetter C -Size $max" in script
    check VolumeBytesMarker in script

  test "Windows: a C: that did not grow fails by name":
    let b = FakeGuestBackend(id: biLibvirt, volumeBytes: 30 * GiB)
    expect GuestDiskNotGrownError:
      ensureGuestDiskGrown(b, vm, goWindows, 50 * GiB)

  test "Linux: an already-grown root is only measured":
    let b = FakeGuestBackend(id: biLibvirt, rootBytes: @[48 * GiB])
    ensureGuestDiskGrown(b, vm, goLinux, 50 * GiB)
    check b.calls.len == 1

  test "Linux: an ungrown root is grown in the guest, then re-measured":
    let b = FakeGuestBackend(id: biLibvirt, rootBytes: @[19 * GiB, 48 * GiB])
    ensureGuestDiskGrown(b, vm, goLinux, 50 * GiB)
    check b.calls.len == 3
    check "growpart" in b.calls[1][^1]

  test "Linux: a root that stays small fails by name":
    let b = FakeGuestBackend(id: biLibvirt, rootBytes: @[19 * GiB])
    expect GuestDiskNotGrownError:
      ensureGuestDiskGrown(b, vm, goLinux, 50 * GiB)

# ---------------------------------------------------------------------------
# libvirt

proc libvirtFixture(tmp: string): LibvirtBackend =
  let virsh = tmp / "virsh"
  writeExecutable(virsh, "#!/bin/sh\n" &
    "printf '%s\\n' \"$*\" >> '" & tmp & "/virsh.log'\n" &
    "for a in \"$@\"; do case \"$a\" in dominfo) exit 1 ;; esac; done\n" &
    "exit 0\n")
  let sshpass = tmp / "sshpass"
  writeExecutable(sshpass, "#!/bin/sh\nshift\nexec \"$@\"\n")
  let ssh = tmp / "ssh"
  writeExecutable(ssh, "#!/bin/sh\n" &
    "printf '%s\\n' \"$*\" >> '" & tmp & "/ssh.log'\n" &
    "case \"$*\" in\n" &
    "  *EncodedCommand*) echo \"" & VolumeBytesMarker & "$(cat '" & tmp & "/volume')\" ;;\n" &
    "  *) echo guest-host ;;\n" &
    "esac\n")
  writeFile(tmp / "volume", "0")
  createDir(tmp / "pool")
  result = newLibvirtBackend(virshCmd = virsh, sshCmd = ssh,
    sshpassCmd = sshpass, imagePoolDir = tmp / "pool",
    libvirtUri = "qemu:///session")

suite "libvirt":
  test "a per-job overlay is given the requested size when it is larger":
    let tmp = createTempDir("vmh-disk-lv-", "")
    defer: removeDir(tmp)
    let b = libvirtFixture(tmp)
    makeQcow2(tmp / "golden.qcow2", 1)
    let vm = b.provisionEphemeralClone(EphemeralCloneSpec(
      name: "job-grow", goldenImage: tmp / "golden.qcow2",
      diskGB: 2, diskGBDefaulted: false))
    check virtualSize(vm.extra["overlayPath"]) == 2 * GiB
    check b.guestDiskBytes["job-grow"] == 2 * GiB

  test "a defaulted size below the golden's keeps the golden's":
    let tmp = createTempDir("vmh-disk-lv-", "")
    defer: removeDir(tmp)
    let b = libvirtFixture(tmp)
    makeQcow2(tmp / "golden.qcow2", 3)
    let vm = b.provisionEphemeralClone(EphemeralCloneSpec(
      name: "job-keep", goldenImage: tmp / "golden.qcow2",
      diskGB: 2, diskGBDefaulted: true))
    check virtualSize(vm.extra["overlayPath"]) == 3 * GiB
    check "job-keep" notin b.guestDiskBytes

  test "an explicit size below the golden's is refused before anything exists":
    let tmp = createTempDir("vmh-disk-lv-", "")
    defer: removeDir(tmp)
    let b = libvirtFixture(tmp)
    makeQcow2(tmp / "golden.qcow2", 3)
    var raised = false
    try:
      discard b.provisionEphemeralClone(EphemeralCloneSpec(
        name: "job-refuse", goldenImage: tmp / "golden.qcow2",
        diskGB: 2, diskGBDefaulted: false))
    except DiskSizeTooSmallError as e:
      raised = true
      check e.requestedBytes == 2 * GiB
      check e.imageBytes == 3 * GiB
    check raised
    check not fileExists(b.overlayPathFor("job-refuse"))
    check "define" notin readFile(tmp / "virsh.log")

  test "the qcow2 import path grows the domain disk":
    let tmp = createTempDir("vmh-disk-lv-", "")
    defer: removeDir(tmp)
    let b = libvirtFixture(tmp)
    makeQcow2(tmp / "golden.qcow2", 1)
    # virt-install is resolved through PATH on this path.
    writeExecutable(tmp / "virt-install", "#!/bin/sh\nexit 0\n")
    let oldPath = getEnv("PATH")
    putEnv("PATH", tmp & ":" & oldPath)
    defer: putEnv("PATH", oldPath)
    b.provisionBaseline(BaselineSpec(name: "win-import",
      sourceImage: tmp / "golden.qcow2", diskGB: 2))
    check virtualSize(b.domainDiskPath("win-import")) == 2 * GiB
    check b.guestDiskBytes["win-import"] == 2 * GiB

  test "startAndAwaitReady extends C: of a grown domain and verifies it":
    let tmp = createTempDir("vmh-disk-lv-", "")
    defer: removeDir(tmp)
    let b = libvirtFixture(tmp)
    b.guestDiskBytes["win-grown"] = 50 * GiB
    let vm = VmHandle(backend: b, name: "win-grown",
                      ipAddress: some("192.0.2.30"))
    writeFile(tmp / "volume", $(49 * GiB))
    b.startAndAwaitReady(vm, timeoutSec = 10)
    check "EncodedCommand" in readFile(tmp / "ssh.log")

    writeFile(tmp / "volume", $(30 * GiB))
    expect GuestDiskNotGrownError:
      b.startAndAwaitReady(vm, timeoutSec = 10)

  test "a domain whose disk was not grown is not touched in the guest":
    let tmp = createTempDir("vmh-disk-lv-", "")
    defer: removeDir(tmp)
    let b = libvirtFixture(tmp)
    let vm = VmHandle(backend: b, name: "win-plain",
                      ipAddress: some("192.0.2.31"))
    b.startAndAwaitReady(vm, timeoutSec = 10)
    check "EncodedCommand" notin readFile(tmp / "ssh.log")

suite "libvirt media boot":
  test "an explicit size grows the qcow2 overlay and marks the guest":
    let tmp = createTempDir("vmh-disk-lvm-", "")
    defer: removeDir(tmp)
    let b = libvirtFixture(tmp)
    b.virtInstallCmd = tmp / "virt-install"
    writeExecutable(b.virtInstallCmd, "#!/bin/sh\nexit 0\n")
    makeQcow2(tmp / "media.qcow2", 1)
    let vm = b.bootFromMedia(BootMediaSpec(kind: bmkQcow2,
      mediaPath: tmp / "media.qcow2", diskGB: 2))
    check virtualSize(b.domainDiskPath(vm.name)) == 2 * GiB
    check b.guestDiskBytes[vm.name] == 2 * GiB

  test "the boot default never resizes an image":
    let tmp = createTempDir("vmh-disk-lvm-", "")
    defer: removeDir(tmp)
    let b = libvirtFixture(tmp)
    b.virtInstallCmd = tmp / "virt-install"
    writeExecutable(b.virtInstallCmd, "#!/bin/sh\nexit 0\n")
    makeQcow2(tmp / "media.qcow2", 1)
    let vm = b.bootFromMedia(BootMediaSpec(kind: bmkQcow2,
      mediaPath: tmp / "media.qcow2", diskGB: 8, diskGBDefaulted: true))
    check virtualSize(b.domainDiskPath(vm.name)) == 1 * GiB
    check vm.name notin b.guestDiskBytes

  test "an explicit size below the image's is refused before any disk exists":
    let tmp = createTempDir("vmh-disk-lvm-", "")
    defer: removeDir(tmp)
    let b = libvirtFixture(tmp)
    b.virtInstallCmd = tmp / "virt-install"
    writeExecutable(b.virtInstallCmd, "#!/bin/sh\ntouch '" & tmp &
                    "/virt-install-ran'\nexit 0\n")
    makeQcow2(tmp / "media.qcow2", 3)
    expect DiskSizeTooSmallError:
      discard b.bootFromMedia(BootMediaSpec(name: BootDomainNamePrefix & "r",
        kind: bmkQcow2, mediaPath: tmp / "media.qcow2", diskGB: 2))
    check not fileExists(b.domainDiskPath(BootDomainNamePrefix & "r"))
    check not fileExists(tmp / "virt-install-ran")

# ---------------------------------------------------------------------------
# qemu-boot (no in-guest channel: host-side sizing only)

proc qemuBootFixture(tmp: string): QemuBootBackend =
  ## A fake QEMU that records the virtual size of the disk it was handed
  ## (read with the real qemu-img), then exits: the overlay lives in the run
  ## directory, which a failed boot removes.
  let qemu = tmp / "qemu"
  writeExecutable(qemu, "#!/bin/sh\n" &
    "for a in \"$@\"; do case \"$a\" in file=*overlay.qcow2*)\n" &
    "  f=${a#file=}; f=${f%%,*}\n" &
    "  qemu-img info -U --output=json \"$f\" > '" & tmp & "/disk.json' ;;\n" &
    "esac; done\nexit 1\n")
  newQemuBootBackend(qemuCmd = qemu, stateDir = tmp / "state")

proc recordedSize(tmp: string): int64 =
  parseQemuImgVirtualSize(readFile(tmp / "disk.json"))

suite "qemu-boot media boot":
  test "an explicit size grows the qcow2 overlay":
    let tmp = createTempDir("vmh-disk-qb-", "")
    defer: removeDir(tmp)
    let b = qemuBootFixture(tmp)
    makeQcow2(tmp / "media.qcow2", 1)
    expect VmHarnessError:
      discard b.bootFromMedia(BootMediaSpec(kind: bmkQcow2, generation: 1,
        acceleration: baTcg, mediaPath: tmp / "media.qcow2", diskGB: 2))
    check recordedSize(tmp) == 2 * GiB

  test "the boot default never resizes an image":
    let tmp = createTempDir("vmh-disk-qb-", "")
    defer: removeDir(tmp)
    let b = qemuBootFixture(tmp)
    makeQcow2(tmp / "media.qcow2", 1)
    expect VmHarnessError:
      discard b.bootFromMedia(BootMediaSpec(kind: bmkQcow2, generation: 1,
        acceleration: baTcg, mediaPath: tmp / "media.qcow2", diskGB: 8,
        diskGBDefaulted: true))
    check recordedSize(tmp) == 1 * GiB

  test "an explicit size below the image's is refused before anything runs":
    let tmp = createTempDir("vmh-disk-qb-", "")
    defer: removeDir(tmp)
    let b = qemuBootFixture(tmp)
    makeQcow2(tmp / "media.qcow2", 3)
    let name = QemuBootNamePrefix & "refused"
    expect DiskSizeTooSmallError:
      discard b.bootFromMedia(BootMediaSpec(name: name, kind: bmkQcow2,
        generation: 1, acceleration: baTcg, mediaPath: tmp / "media.qcow2",
        diskGB: 2))
    check not fileExists(tmp / "disk.json")
    check not dirExists(b.runDirFor(name))

# ---------------------------------------------------------------------------
# UTM

proc utmFixture(tmp: string, goldenGiB: int): UtmBackend =
  ## A fake ``utmctl`` whose ``clone`` lays the clone out the way UTM does:
  ## ``<documents>/<name>.utm/Data/disk.qcow2``, a copy of the golden's disk.
  let docs = tmp / "docs"
  createDir(docs / "golden.utm" / "Data")
  makeQcow2(docs / "golden.utm" / "Data" / "disk.qcow2", goldenGiB)
  let utmctl = tmp / "utmctl"
  writeExecutable(utmctl, "#!/bin/sh\n" &
    "printf '%s\\n' \"$*\" >> '" & tmp & "/utmctl.log'\n" &
    "case \"$1\" in\n" &
    "  clone) mkdir -p '" & docs & "'/\"$4\".utm/Data && " &
    "cp '" & docs & "/golden.utm/Data/disk.qcow2' '" & docs & "'/\"$4\".utm/Data/ ;;\n" &
    "  status) echo stopped ;;\n" &
    "  ip-address) echo 192.0.2.40 ;;\n" &
    "  list) echo 'UUID Status Name' ;;\n" &
    "esac\n" &
    "exit 0\n")
  let sshpass = tmp / "sshpass"
  writeExecutable(sshpass, "#!/bin/sh\nshift 2\nexec \"$@\"\n")
  let ssh = tmp / "ssh"
  writeExecutable(ssh, "#!/bin/sh\n" &
    "printf '%s\\n' \"$*\" >> '" & tmp & "/ssh.log'\n" &
    "case \"$*\" in\n" &
    "  *EncodedCommand*) echo \"" & VolumeBytesMarker & "$(cat '" & tmp & "/volume')\" ;;\n" &
    "  *) echo ready ;;\n" &
    "esac\n")
  writeFile(tmp / "volume", $(49 * GiB))
  writeFile(tmp / "ssh.log", "")
  result = newUtmBackend(utmctlCmd = utmctl, sshpassCmd = sshpass,
    sshCmd = ssh, goldenBundleName = "golden", bootTimeoutSec = 5,
    sshReadyTimeoutSec = 10)
  result.utmDocumentsDir = docs

proc cloneDisk(b: UtmBackend, vm: VmHandle): string =
  b.utmDocumentsDir / (vm.name & ".utm") / "Data" / "disk.qcow2"

suite "UTM":
  test "a clone smaller than the request is grown and C: follows":
    let tmp = createTempDir("vmh-disk-utm-", "")
    defer: removeDir(tmp)
    let b = utmFixture(tmp, goldenGiB = 1)
    b.provisionBaseline(BaselineSpec(name: "golden", diskGB: 50))
    let vm = b.revertToBaseline("golden")
    check virtualSize(b.cloneDisk(vm)) == 50 * GiB
    check vm.extra["diskBytes"] == $(50 * GiB)
    check "EncodedCommand" in readFile(tmp / "ssh.log")

  test "an explicit size below the golden's is refused and never started":
    let tmp = createTempDir("vmh-disk-utm-", "")
    defer: removeDir(tmp)
    let b = utmFixture(tmp, goldenGiB = 3)
    b.provisionBaseline(BaselineSpec(name: "golden", diskGB: 2))
    expect DiskSizeTooSmallError:
      discard b.revertToBaseline("golden")
    let log = readFile(tmp / "utmctl.log")
    check "delete " & b.ephemeralPrefix in log
    check "start" notin log

  test "a defaulted size below the golden's keeps it, with no guest step":
    let tmp = createTempDir("vmh-disk-utm-", "")
    defer: removeDir(tmp)
    let b = utmFixture(tmp, goldenGiB = 3)
    b.provisionBaseline(BaselineSpec(name: "golden", diskGB: 2,
                                     diskGBDefaulted: true))
    let vm = b.revertToBaseline("golden")
    check virtualSize(b.cloneDisk(vm)) == 3 * GiB
    check "EncodedCommand" notin readFile(tmp / "ssh.log")

  test "a C: that does not grow fails the clone by name":
    let tmp = createTempDir("vmh-disk-utm-", "")
    defer: removeDir(tmp)
    let b = utmFixture(tmp, goldenGiB = 1)
    writeFile(tmp / "volume", $(1 * GiB))
    b.provisionBaseline(BaselineSpec(name: "golden", diskGB: 50))
    expect GuestDiskNotGrownError:
      discard b.revertToBaseline("golden")
    check "delete " & b.ephemeralPrefix in readFile(tmp / "utmctl.log")

  test "an unlocatable clone disk fails an explicit request, keeps a default":
    let tmp = createTempDir("vmh-disk-utm-", "")
    defer: removeDir(tmp)
    let b = utmFixture(tmp, goldenGiB = 1)
    b.utmDocumentsDir = tmp / "elsewhere"
    b.provisionBaseline(BaselineSpec(name: "golden", diskGB: 50))
    expect VmHarnessError:
      discard b.revertToBaseline("golden")
    b.provisionBaseline(BaselineSpec(name: "golden", diskGB: 50,
                                     diskGBDefaulted: true))
    discard b.revertToBaseline("golden")

# ---------------------------------------------------------------------------
# Hyper-V (rendered PowerShell only: no Hyper-V host here)

suite "Hyper-V":
  let b = newHyperVBackend()

  test "the per-job clone is grown with Resize-VHD, never shrunk":
    let spec = HyperVEphemeralCloneSpec(
      name: ephemeralVmNamePrefix() & "disk", goldenVhdx: "C:\\g.vhdx",
      useDifferencing: true, diskGB: 50)
    let ps = b.buildEphemeralCloneCommand(spec, "C:\\c.vhdx")
    check "$vmhWantBytes = [int64]" & $(50 * GiB) in ps
    check "Resize-VHD -Path $clone -SizeBytes $vmhWantBytes" in ps
    check "-not $false" in ps
    # The sizing runs after the per-job disk exists and before the VM does.
    check ps.find("New-VHD -Path $clone -ParentPath") < ps.find("Resize-VHD")
    check ps.find("Resize-VHD") < ps.find("New-VM ")

  test "a defaulted clone size never refuses a larger golden":
    let ps = b.buildEphemeralCloneCommand(HyperVEphemeralCloneSpec(
      name: ephemeralVmNamePrefix() & "disk", goldenVhdx: "C:\\g.vhdx",
      diskGB: 50, diskGBDefaulted: true), "C:\\c.vhdx")
    check "-not $true" in ps

  test "no requested size renders no sizing at all":
    let ps = b.buildEphemeralCloneCommand(HyperVEphemeralCloneSpec(
      name: ephemeralVmNamePrefix() & "disk", goldenVhdx: "C:\\g.vhdx"),
      "C:\\c.vhdx")
    check "Resize-VHD" notin ps

  test "a converted qcow2 is grown, and a caller's VHDX is left alone":
    let qcow = b.buildNewBootVmCommand(BootMediaSpec(kind: bmkQcow2,
      mediaPath: "C:\\m.qcow2", diskGB: 64), BootVmNamePrefix & "x", "p",
      "C:\\s.vhdx")
    check "Resize-VHD -Path $scratchVhdx" in qcow
    check "-not $false" in qcow
    check qcow.find(" convert -f qcow2") < qcow.find("Resize-VHD")
    # The boot default (8, sized for an ISO's blank disk) never resizes an
    # image.
    let defaulted = b.buildNewBootVmCommand(BootMediaSpec(kind: bmkQcow2,
      mediaPath: "C:\\m.qcow2", diskGB: 8, diskGBDefaulted: true),
      BootVmNamePrefix & "x", "p", "C:\\s.vhdx")
    check "Resize-VHD" notin defaulted
    # The resize lives INSIDE the qcow2 branch: bmkVhdx attaches the caller's
    # own disk, which is never resized.
    let branch = qcow.find("elseif ($kind -eq 'qcow2')")
    let vhdxBranch = qcow.find("bmkVhdx requires mediaPath")
    check branch >= 0 and vhdxBranch > branch
    check qcow.find("Resize-VHD") in branch .. vhdxBranch

  test "the refusal and growth markers round-trip":
    let refused = parseDiskTooSmall("Exception: " & DiskTooSmallMarker &
      " requested=53687091200 image=85899345920\r\n")
    check refused.found
    check refused.requested == 50 * GiB
    check refused.image == 80 * GiB
    check not parseDiskTooSmall("all good").found
    check parseDiskGrown("x\n" & DiskGrownMarker & $(50 * GiB) & "\n") ==
      50 * GiB
