# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Gate: the qemu-boot backend's ARM guests, read-only boot disks,
## NoCloud seeds and SSH access preconditions.
##
## The argv half asserts on ``buildQemuBootArgs``, the pure function the
## live boot path calls, so it runs on every host. The x86 polarity of
## every new option is checked too: an option that is not requested must
## leave the argv exactly as it was, because every existing x86 boot gate
## was measured on that argv.
##
## *Mocking.* None. Real value types in, real argv out; the SSH
## precondition checks run against a real handle the backend would build,
## minus the QEMU process.

import std/[os, strutils, tables, unittest]
import gosti

proc idx(args: seq[string], needle: string): int =
  result = -1
  for i, a in args:
    if a == needle:
      return i

proc valueAfter(args: seq[string], flag: string): string =
  let i = idx(args, flag)
  if i < 0 or i + 1 >= args.len: "" else: args[i + 1]

proc values(args: seq[string], flag: string): seq[string] =
  for i, a in args:
    if a == flag and i + 1 < args.len:
      result.add(args[i + 1])

proc baseLaunch(arch = gaX86_64): QemuBootLaunch =
  QemuBootLaunch(
    vmName: "repro-test-boot-qemu-1-abc",
    diskPath: "/tmp/disk.qcow2",
    diskFormat: "qcow2",
    serialSocketPath: "/tmp/gosti-qb-1/serial.sock",
    serialLogPath: "/tmp/artifacts/serial.log",
    cpus: 2,
    memoryMB: 1024,
    accel: baTcg,
    arch: arch)

suite "qemu-boot guest architectures":
  test "x86 argv is unchanged when no new option is requested":
    let a = buildQemuBootArgs(baseLaunch())
    check valueAfter(a, "-machine") == "q35"
    check valueAfter(a, "-cpu") == "qemu64"
    check values(a, "-drive") == @["file=/tmp/disk.qcow2,format=qcow2,if=virtio"]

  test "arm64 boots the virt board with an emulated arm64 CPU":
    let a = buildQemuBootArgs(baseLaunch(gaArm64))
    check valueAfter(a, "-machine") == "virt"
    check valueAfter(a, "-cpu") == "max,pauth-impdef=on"
    check valueAfter(a, "-accel") == "tcg"

  test "armv7 boots the virt board with a cortex-a15":
    let a = buildQemuBootArgs(baseLaunch(gaArmv7))
    check valueAfter(a, "-machine") == "virt"
    check valueAfter(a, "-cpu") == "cortex-a15"

  test "KVM keeps the host CPU on every architecture":
    var l = baseLaunch(gaArm64)
    l.accel = baKvm
    let a = buildQemuBootArgs(l)
    check valueAfter(a, "-cpu") == "host"

  test "a foreign architecture is emulated unless KVM is demanded":
    let foreign = if hostGuestArch() == gaX86_64: gaArm64 else: gaX86_64
    check resolveQemuAccelFor(baAuto, foreign) == baTcg
    check resolveQemuAccelFor(baTcg, hostGuestArch()) == baTcg
    check resolveQemuAccelFor(baKvm, foreign) == baKvm

  test "the TPM device is spelled per architecture":
    var l = baseLaunch(gaArm64)
    l.tpmSocketPath = "/tmp/gosti-qb-1/tpm.sock"
    check "tpm-tis-device,tpmdev=tpm0" in buildQemuBootArgs(l)
    var x = baseLaunch()
    x.tpmSocketPath = "/tmp/gosti-qb-1/tpm.sock"
    check "tpm-tis,tpmdev=tpm0" in buildQemuBootArgs(x)

suite "read-only disks and seeds":
  test "readonly=on is added to the boot disk only when asked":
    var l = baseLaunch()
    l.diskReadonly = true
    check values(buildQemuBootArgs(l), "-drive") ==
      @["file=/tmp/disk.qcow2,format=qcow2,if=virtio,readonly=on"]

  test "a seed is a read-only raw virtio disk on every architecture":
    for arch in [gaX86_64, gaArm64, gaArmv7]:
      var l = baseLaunch(arch)
      l.seedPath = "/tmp/seed.iso"
      let drives = values(buildQemuBootArgs(l), "-drive")
      check "file=/tmp/seed.iso,format=raw,if=virtio,readonly=on" in drives
      check idx(buildQemuBootArgs(l), "-cdrom") < 0

suite "ARM firmware resolution":
  test "an explicit image wins, and a missing one is an error":
    let f = getTempDir() / ("gosti-fw-" & $getCurrentProcessId() & ".fd")
    writeFile(f, "x")
    defer: removeFile(f)
    check resolveArmFirmware(true, "qemu-system-aarch64", f) == f
    expect ValueError:
      discard resolveArmFirmware(true, "qemu-system-aarch64", f & ".missing")

  test "the environment variable is searched first":
    putEnv(AavmfCodeEnvVar, "/nonexistent/code.fd")
    defer: delEnv(AavmfCodeEnvVar)
    check armFirmwareCandidates(true, "/usr/bin/qemu-system-aarch64")[0] ==
      "/nonexistent/code.fd"
    check armFirmwareCandidates(false, "/usr/bin/qemu-system-arm")[0] !=
      "/nonexistent/code.fd"

  test "QEMU's own share directory is searched next to the binary":
    let c = armFirmwareCandidates(false, "/opt/qemu/bin/qemu-system-arm")
    check "/opt/qemu/share/qemu/edk2-arm-code.fd" in c

suite "SSH access preconditions":
  let b = newQemuBootBackend(stateDir = getTempDir() / "gosti-qb-unit",
                             sshUser = "root", sshKeyPath = "/tmp/key")
  test "the per-architecture emulator is selected":
    check b.qemuCmdFor(gaX86_64) == "qemu-system-x86_64"
    check b.qemuCmdFor(gaArm64) == "qemu-system-aarch64"
    check b.qemuCmdFor(gaArmv7) == "qemu-system-arm"

  test "exec without a forwarded port is refused, not attempted":
    let vm = VmHandle(backend: b, name: "repro-test-boot-qemu-1-x", sshPort: 0,
                      sshUser: "root", extra: initTable[string, string]())
    expect BackendUnavailableError:
      discard b.execInGuest(vm, initTable[string, string](), @["true"])

  test "exec without a login is refused":
    let vm = VmHandle(backend: b, name: "repro-test-boot-qemu-1-x", sshPort: 2222,
                      sshUser: "", extra: initTable[string, string]())
    expect BackendUnavailableError:
      discard b.execInGuest(vm, initTable[string, string](), @["true"])

  test "exec on a torn-down handle is refused":
    var extra = initTable[string, string]()
    extra["cleanedUp"] = "true"
    let vm = VmHandle(backend: b, name: "repro-test-boot-qemu-1-x", sshPort: 2222,
                      sshUser: "root", extra: extra)
    expect GostiError:
      discard b.execInGuest(vm, initTable[string, string](), @["true"])
