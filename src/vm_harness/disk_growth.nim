# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Per-job disk sizing shared by every backend that clones a golden image.
##
## A clone starts at the golden's size. When the caller asks for more
## (``BaselineSpec.diskGB``), the backend grows the clone's disk before the
## guest boots, then the guest's system volume has to grow into the new
## space. This module holds the parts that are identical everywhere:
##
## * the sizing decision (``planDiskResize``): grow when the request is
##   larger, keep when it is equal, zero or a DEFAULT the golden already
##   exceeds, and refuse (``DiskSizeTooSmallError``) when the caller
##   explicitly asked for less than the golden has — disks are never shrunk;
## * ``qemu-img`` probes and resizes for the qcow2-based backends;
## * the in-guest step (``ensureGuestDiskGrown``): Linux root filesystems
##   are checked with ``df`` and grown with ``growpart`` + ``resize2fs`` when
##   cloud-init did not already do it; Windows ``C:`` is extended with
##   ``Resize-Partition``. Either way the result is VERIFIED, and a volume
##   that still does not span the disk fails the boot with
##   ``GuestDiskNotGrownError`` instead of failing the job later with
##   "no space left on device".

import std/[base64, json, osproc, streams, strutils, tables]
import ./types

type
  DiskSizeTooSmallError* = object of VmHarnessError
    ## The caller explicitly requested a disk smaller than the golden image.
    ## Disks are only ever grown, and silently running the larger image would
    ## hide the sizing mistake, so the clone is refused.
    requestedBytes*: int64
    imageBytes*: int64

  GuestDiskNotGrownError* = object of VmHarnessError
    ## The clone's disk was grown but the guest's system volume still does not
    ## use the space after the in-guest growth step.

  DiskResizePlan* = enum
    drKeep     ## leave the clone at the golden's size
    drGrow     ## grow the clone to the requested size
    drRefuse   ## the caller asked for less than the golden has

const
  GiB* = 1024'i64 * 1024 * 1024
  VolumeBytesMarker* = "vmh-volume-bytes="

proc gibToBytes*(gb: int): int64 = int64(gb) * GiB

proc planDiskResize*(imageBytes, requestedBytes: int64,
                     defaulted: bool): DiskResizePlan =
  ## A request below the golden's size is a mistake when the caller made it
  ## (refused) and harmless when it is a default the golden already exceeds
  ## (kept).
  if requestedBytes <= 0 or requestedBytes == imageBytes:
    drKeep
  elif requestedBytes > imageBytes:
    drGrow
  elif defaulted:
    drKeep
  else:
    drRefuse

proc newDiskSizeTooSmallError*(backend: string, phase: LifecyclePhase,
                               requestedBytes, imageBytes: int64,
                               image: string): ref DiskSizeTooSmallError =
  (ref DiskSizeTooSmallError)(
    msg: backend & ": requested disk size " & $requestedBytes &
         " bytes is smaller than the image's " & $imageBytes & " bytes (" &
         image & "); disks can only grow. Request at least the image's size.",
    backend: backend, phase: phase,
    requestedBytes: requestedBytes, imageBytes: imageBytes)

# ---------------------------------------------------------------------------
# qemu-img

proc runCapture(cmd: seq[string]): tuple[code: int, output: string] =
  var p = startProcess(cmd[0], args = cmd[1 .. ^1],
                       options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  let output = p.outputStream.readAll()
  (p.waitForExit(), output)

proc parseQemuImgVirtualSize*(infoJson: string): int64 =
  ## ``virtual-size`` from ``qemu-img info --output=json``; -1 when absent.
  try:
    let node = parseJson(infoJson){"virtual-size"}
    if node != nil and node.kind == JInt:
      return node.getBiggestInt().int64
  except JsonParsingError:
    discard
  -1

proc qemuImgVirtualSize*(qemuImgCmd, path, backend: string): int64 =
  ## The image's virtual (guest-visible) size in bytes. ``-U`` because a
  ## golden that backs running clones is legitimately locked by them.
  let r = runCapture(@[qemuImgCmd, "info", "-U", "--output=json", path])
  result = if r.code == 0: parseQemuImgVirtualSize(r.output) else: -1
  if result < 0:
    raise newVmHarnessError(backend, lpProvisioning,
      "qemu-img info " & path & " did not report a virtual size (exit " &
      $r.code & "): " & r.output)

proc qemuImgResize*(qemuImgCmd, path: string, bytes: int64, backend: string) =
  ## Grow a qcow2 image's virtual size. Never used to shrink: callers go
  ## through ``planDiskResize`` first.
  let r = runCapture(@[qemuImgCmd, "resize", "-f", "qcow2", path, $bytes])
  if r.code != 0:
    raise newVmHarnessError(backend, lpProvisioning,
      "qemu-img resize " & path & " " & $bytes & " failed (exit " & $r.code &
      "): " & r.output)

proc planQcow2Clone*(qemuImgCmd, golden: string, requestedBytes: int64,
                     defaulted: bool, backend: string,
                     phase: LifecyclePhase): int64 =
  ## Decide the virtual size of a per-job clone of ``golden``. Returns the
  ## size to give the clone, or 0 to inherit the golden's. Raises
  ## ``DiskSizeTooSmallError`` for an explicit request below the golden's.
  if requestedBytes <= 0:
    return 0
  let imageBytes = qemuImgVirtualSize(qemuImgCmd, golden, backend)
  case planDiskResize(imageBytes, requestedBytes, defaulted)
  of drKeep: 0'i64
  of drGrow: requestedBytes
  of drRefuse:
    raise newDiskSizeTooSmallError(backend, phase, requestedBytes,
                                   imageBytes, golden)

proc mediaOverlayRequestBytes*(diskGB: int, defaulted: bool): int64 =
  ## The size a boot-from-media overlay of an existing image is grown to.
  ## ``BootMediaSpec.diskGB``'s default (8) exists to size a blank install
  ## disk for an ISO; applied to an image it would grow every small test image
  ## and then demand that its guest fill the space. So for image media only an
  ## EXPLICIT size counts.
  if defaulted or diskGB <= 0: 0'i64 else: gibToBytes(diskGB)

# ---------------------------------------------------------------------------
# In-guest growth

const
  LinuxRootFsBytesScript* =
    "df -P -k / | awk 'NR==2 {printf \"%.0f\\n\", $2 * 1024}'"
    ## Size of the guest's root filesystem in bytes.
  LinuxGrowRootFsScript* = "set -eu\n" &
    "src=$(findmnt -n -o SOURCE /)\n" &
    "part=$(basename \"$src\")\n" &
    "disk=$(lsblk -n -o PKNAME \"$src\" | head -n1)\n" &
    "num=$(cat /sys/class/block/\"$part\"/partition)\n" &
    "sudo -n growpart \"/dev/$disk\" \"$num\" || true\n" &
    "sudo -n resize2fs \"$src\"\n"
    ## Fallback for a guest whose cloud-init did not grow the root partition:
    ## growpart (exits non-zero when there is nothing to grow) then resize2fs.
  WindowsGrowSystemVolumeScript* = "$ErrorActionPreference = 'Stop'\n" &
    "try { Update-HostStorageCache } catch { }\n" &
    "$part = Get-Partition -DriveLetter C\n" &
    "$max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax\n" &
    "if ($max -gt ($part.Size + 1MB)) { Resize-Partition -DriveLetter C -Size $max }\n" &
    "Write-Output ('" & VolumeBytesMarker & "' + [string](Get-Volume -DriveLetter C).Size)\n"
    ## Extend ``C:`` over the grown disk and report the volume's size. The
    ## Windows recipes put ``C:`` last (EFI, MSR, Windows), so nothing blocks
    ## the extension; a layout with a partition after ``C:`` is caught by the
    ## verification rather than assumed away.

proc powershellEncodedArgv*(script: string): seq[string] =
  ## ``powershell -EncodedCommand``: UTF-16LE base64, so the script crosses
  ## cmd.exe, a PowerShell default shell and PowerShell Direct unquoted.
  var utf16 = newStringOfCap(script.len * 2)
  for ch in script:
    utf16.add(ch)
    utf16.add('\0')
  @["powershell", "-NoLogo", "-NoProfile", "-NonInteractive",
    "-EncodedCommand", encode(utf16)]

proc volumeGrownEnough*(volumeBytes, requestedBytes: int64): bool =
  ## Whether a system volume plausibly spans a disk of ``requestedBytes``.
  ## Partition tables, EFI/boot/MSR partitions and filesystem metadata take a
  ## share, so the bar is the request less 10% or 2 GB, whichever is larger.
  volumeBytes >= requestedBytes - max(requestedBytes div 10, 2_000_000_000'i64)

proc parseFirstInt(output: string): int64 =
  for line in output.splitLines():
    try:
      return parseBiggestInt(line.strip()).int64
    except ValueError:
      discard
  -1

proc parseVolumeBytes*(output: string): int64 =
  for line in output.splitLines():
    let s = line.strip()
    if s.startsWith(VolumeBytesMarker):
      try:
        return parseBiggestInt(s[VolumeBytesMarker.len .. ^1]).int64
      except ValueError:
        discard
  -1

proc ensureGuestDiskGrown*(b: VmBackend, vm: VmHandle, guestOs: GuestOs,
                           requestedBytes: int64) =
  ## Make the guest's system volume use a disk grown to ``requestedBytes``
  ## and verify it did, over the backend's own ``execInGuest``. Raises
  ## ``GuestDiskNotGrownError`` naming the sizes when it did not. A macOS
  ## guest is not handled (its APFS container can only be grown from
  ## recovery), and callers do not grow macOS disks.
  if requestedBytes <= 0:
    return
  let noEnv = initTable[string, string]()
  case guestOs
  of goLinux:
    proc rootBytes(): int64 =
      let r = b.execInGuest(vm, noEnv, @["/bin/sh", "-c", LinuxRootFsBytesScript],
                            timeoutSec = 60)
      if r.exitCode == 0: parseFirstInt(r.stdout) else: -1
    if volumeGrownEnough(rootBytes(), requestedBytes):
      return
    let grow = b.execInGuest(vm, noEnv, @["/bin/sh", "-c", LinuxGrowRootFsScript],
                             timeoutSec = 180)
    let after = rootBytes()
    if volumeGrownEnough(after, requestedBytes):
      return
    raise (ref GuestDiskNotGrownError)(
      msg: $b.id & ": disk of " & vm.name & " was grown to " &
           $requestedBytes & " bytes but the guest root filesystem is " &
           $after & " bytes after growpart/resize2fs (exit " &
           $grow.exitCode & "): " & grow.stdout & grow.stderr,
      backend: $b.id, phase: lpStartup)
  of goWindows:
    let r = b.execInGuest(vm, noEnv,
                          powershellEncodedArgv(WindowsGrowSystemVolumeScript),
                          timeoutSec = 300)
    let volume = parseVolumeBytes(r.stdout & "\n" & r.stderr)
    if r.exitCode == 0 and volumeGrownEnough(volume, requestedBytes):
      return
    raise (ref GuestDiskNotGrownError)(
      msg: $b.id & ": disk of " & vm.name & " was grown to " &
           $requestedBytes & " bytes but volume C: is " & $volume &
           " bytes after Resize-Partition (exit " & $r.exitCode & "): " &
           r.stdout & r.stderr,
      backend: $b.id, phase: lpStartup)
  of goMacos:
    discard
