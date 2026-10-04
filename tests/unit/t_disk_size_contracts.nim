# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Portable disk-size decisions, guest-growth and Hyper-V command contracts.
## Moved unchanged from t_disk_size_honoured so they also execute on Windows.
## FakeGuestBackend replaces only guest execution: no guest is booted at this
## tier. It records the actual commands and returns controlled volume sizes
## to exercise successful growth, unchanged disks and failed growth. Hyper-V
## checks its rendered production PowerShell. Real image and hypervisor
## lifecycle fixtures remain in t_disk_size_honoured on POSIX hosts.
import std/[base64, os, options, strutils, tables, unittest]
import vm_harness

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
