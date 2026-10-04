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
## HOST CONTRACT. docs/design.md section 4.5 restricts libvirt operations
## to Linux. Their complete sizing cases run there; other POSIX hosts
## assert BackendUnavailableError before a disk, virsh or SSH side effect.
## Portable sizing, guest-growth and Hyper-V contracts are preserved in
## t_disk_size_contracts and run on every supported host.
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

import std/[os, osproc, options, strutils, tables, tempfiles, unittest]
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

when defined(linux):
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

else:
  # The production operations deliberately require Linux (design §4.5).
  # Command stand-ins cannot make that host contract disappear. Exercise
  # the refusal before side effects here; the exact nine disk/growth cases
  # above remain Linux gates with all their original assertions.
  suite "libvirt refuses operations on non-Linux hosts":
    test "a clone is refused before creating an overlay or invoking virsh":
      let tmp = createTempDir("vmh-disk-lv-host-", "")
      defer: removeDir(tmp)
      let b = libvirtFixture(tmp)
      expect BackendUnavailableError:
        discard b.provisionEphemeralClone(EphemeralCloneSpec(
          name: "job-refuse", goldenImage: tmp / "golden.qcow2", diskGB: 2))
      check not fileExists(b.overlayPathFor("job-refuse"))
      check not fileExists(tmp / "virsh.log")
      check b.guestDiskBytes.len == 0

    test "an import is refused before creating the domain disk":
      let tmp = createTempDir("vmh-disk-lv-host-", "")
      defer: removeDir(tmp)
      let b = libvirtFixture(tmp)
      expect BackendUnavailableError:
        b.provisionBaseline(BaselineSpec(name: "win-import",
          sourceImage: tmp / "golden.qcow2", diskGB: 2))
      check not fileExists(b.domainDiskPath("win-import"))
      check not fileExists(tmp / "virsh.log")
      check b.guestDiskBytes.len == 0

    test "guest growth is refused before executing SSH":
      let tmp = createTempDir("vmh-disk-lv-host-", "")
      defer: removeDir(tmp)
      let b = libvirtFixture(tmp)
      b.guestDiskBytes["win-grown"] = 50 * GiB
      let vm = VmHandle(backend: b, name: "win-grown",
                        ipAddress: some("192.0.2.30"))
      expect BackendUnavailableError:
        b.startAndAwaitReady(vm, timeoutSec = 10)
      check not fileExists(tmp / "ssh.log")
      check b.guestDiskBytes["win-grown"] == 50 * GiB

    test "media boot is refused before creating a disk or invoking virsh":
      let tmp = createTempDir("vmh-disk-lv-host-", "")
      defer: removeDir(tmp)
      let b = libvirtFixture(tmp)
      let name = BootDomainNamePrefix & "refused"
      expect BackendUnavailableError:
        discard b.bootFromMedia(BootMediaSpec(name: name, kind: bmkQcow2,
          mediaPath: tmp / "media.qcow2", diskGB: 2))
      check not fileExists(b.domainDiskPath(name))
      check not fileExists(tmp / "virsh.log")
      check b.guestDiskBytes.len == 0

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
