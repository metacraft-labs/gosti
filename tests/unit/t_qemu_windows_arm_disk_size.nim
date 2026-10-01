# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## The Windows-ARM QEMU backend honours the requested per-job disk size.
##
## Driven END TO END through the real ``provisionBaseline`` +
## ``revertToBaseline``: a real golden qcow2, a real per-job overlay made by
## the real ``qemu-img``, the shared fake QEMU and swtpm, and the SSH-ready
## lifecycle of a generalized golden. Asserted:
##
## * a golden smaller than the request gets an overlay of the requested
##   virtual size, and ``C:`` is extended in the guest (encoded PowerShell
##   ``Resize-Partition``) and verified;
## * a ``C:`` that does not grow fails the instance with
##   ``GuestDiskNotGrownError`` and the instance directory is removed;
## * an explicit size below the golden's is refused with
##   ``DiskSizeTooSmallError`` before any instance file or process exists;
## * a defaulted size below the golden's keeps the golden's, with no guest
##   step.
##
## MOCKING NOTE (workspace policy). The fake QEMU, swtpm and sshpass are the
## SHARED ones in ``tests/unit/qwa_fake_qemu.nim`` (see its header for why they
## are faithful). This file adds one thin sshpass wrapper in front of them that
## answers the growth script — the one remote command the shared fake does not
## know — with a volume size the test chooses, because there is no Windows
## guest here to run ``Resize-Partition``. That Windows actually extends
## ``C:`` on the recipe's golden is NOT verified by this file.

include qwa_fake_qemu

proc goldenOf(tmp, name: string, gib: int): string =
  result = tmp / name
  createDir(result)
  createGoldenDisk("qemu-img", result, gib)
  writeFile(result / "QEMU_EFI.fd", "efi code")
  writeFile(result / "QEMU_VARS.fd", "efi vars")
  writeFile(result / QwaGoldenManifestName, "{}")

proc diskBackend(tmp: string): QemuWindowsArmBackend =
  result = goldenBackend(tmp, sshReadyTimeoutSec = 45)
  createDir(tmp / "ssh")
  putEnv(FakeSshDirEnv, tmp / "ssh")
  putEnv(FakeQemuEnv, "1")
  putEnv(FakeFirstBootRebootEnv, "1")
  writeFile(tmp / "volume", "0")
  let wrapper = tmp / "sshpass-disk"
  writeExecutable(wrapper, "#!/bin/sh\n" &
    "last=\"\"\nfor a in \"$@\"; do last=\"$a\"; done\n" &
    "case \"$last\" in\n" &
    "  *EncodedCommand*)\n" &
    "    printf '%s\\n' \"$last\" >> '" & tmp & "/grow.log'\n" &
    "    echo \"" & VolumeBytesMarker & "$(cat '" & tmp & "/volume')\"; exit 0 ;;\n" &
    "esac\n" &
    "exec '" & result.sshpassCmd & "' \"$@\"\n")
  result.sshpassCmd = wrapper

proc overlaySize(vmDir: string): int64 =
  let r = execCmdEx("qemu-img info -U --output=json " &
                    quoteShell(vmDir / QwaOverlayDiskName))
  doAssert r.exitCode == 0, r.output
  parseQemuImgVirtualSize(r.output)

suite "qemu-windows-arm per-job disk size":
  test "a golden smaller than the request is grown and C: is extended":
    let tmp = createTempDir("vmh-qwa-disk-", "")
    defer: removeDir(tmp)
    let b = diskBackend(tmp)
    writeFile(tmp / "volume", $(2 * GiB))
    b.provisionBaseline(BaselineSpec(name: "win-arm-runner",
      sourceImage: goldenOf(tmp, "golden", 1), cpus: 1, memoryMB: 64,
      diskGB: 2))
    let vm = b.revertToBaseline("win-arm-runner")
    try:
      check overlaySize(vm.extra["vmDir"]) == 2 * GiB
      check vm.extra["diskBytes"] == $(2 * GiB)
      check fileExists(tmp / "grow.log")
    finally:
      b.stopAndCleanup(vm, deleteVm = true)

  test "a C: that does not grow fails the instance by name":
    let tmp = createTempDir("vmh-qwa-disk-", "")
    defer: removeDir(tmp)
    let b = diskBackend(tmp)
    writeFile(tmp / "volume", "1000")
    b.provisionBaseline(BaselineSpec(name: "win-arm-runner",
      sourceImage: goldenOf(tmp, "golden", 1), cpus: 1, memoryMB: 64,
      diskGB: 2))
    var raised = false
    try:
      # A guest handed out anyway must still be torn down, or its fake QEMU
      # outlives the test and the failure shows up as a hang.
      b.stopAndCleanup(b.revertToBaseline("win-arm-runner"), deleteVm = true)
    except GuestDiskNotGrownError:
      raised = true
    check raised
    var left: seq[string]
    for kind, path in walkDir(b.stateDir / "instances"):
      left.add(path)
    check left.len == 0

  test "an explicit size below the golden's is refused before anything runs":
    let tmp = createTempDir("vmh-qwa-disk-", "")
    defer: removeDir(tmp)
    let b = diskBackend(tmp)
    b.provisionBaseline(BaselineSpec(name: "win-arm-runner",
      sourceImage: goldenOf(tmp, "golden", 3), cpus: 1, memoryMB: 64,
      diskGB: 2))
    var raised = false
    try:
      discard b.revertToBaseline("win-arm-runner")
    except DiskSizeTooSmallError as e:
      raised = true
      check e.requestedBytes == 2 * GiB
      check e.imageBytes == 3 * GiB
    check raised
    var left: seq[string]
    for kind, path in walkDir(b.stateDir / "instances"):
      left.add(path)
    check left.len == 0
    check b.qemuPids.len == 0

  test "a defaulted size below the golden's keeps the golden's":
    let tmp = createTempDir("vmh-qwa-disk-", "")
    defer: removeDir(tmp)
    let b = diskBackend(tmp)
    b.provisionBaseline(BaselineSpec(name: "win-arm-runner",
      sourceImage: goldenOf(tmp, "golden", 3), cpus: 1, memoryMB: 64,
      diskGB: 2, diskGBDefaulted: true))
    let vm = b.revertToBaseline("win-arm-runner")
    try:
      check overlaySize(vm.extra["vmDir"]) == 3 * GiB
      check "diskBytes" notin vm.extra
      check not fileExists(tmp / "grow.log")
    finally:
      b.stopAndCleanup(vm, deleteVm = true)
