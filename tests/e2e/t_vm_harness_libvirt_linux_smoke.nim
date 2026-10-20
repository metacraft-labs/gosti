# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## e2e_vm_harness_libvirt_linux_smoke (Multi-OS VM Automation campaign M4).
##
## A Linux cloud guest under libvirt, end to end, with nothing mocked:
##
##   1. clone the Ubuntu 24.04 cloud golden into a per-job CoW overlay;
##   2. attach a NoCloud ``cidata`` seed carrying a throwaway SSH key;
##   3. boot it on /dev/kvm with a user-mode NIC and a loopback SSH forward
##      (``qemu:///session`` has no ``default`` NAT network);
##   4. wait for SSH, wait for cloud-init to finish, run the no-op gate and
##      check the hostname the seed set;
##   5. tear it down and assert no domain, overlay or seed is left behind.
##
## The golden comes from ``guest-recipes/linux-x64-cloud/fetch-image.sh``
## (pinned release and SHA-256). Point ``VMH_LINUX_CLOUD_GOLDEN`` at the
## qcow2 it prints; the test skips with a reason when that, ``/dev/kvm``,
## ``virsh`` or ``ssh-keygen`` is missing.
##
## Run (Linux host with /dev/kvm, from the dev shell):
##   export VMH_LINUX_CLOUD_GOLDEN=$(guest-recipes/linux-x64-cloud/fetch-image.sh)
##   nim r --hints:off tests/e2e/t_vm_harness_libvirt_linux_smoke.nim

import std/[net, options, os, osproc, strutils, tables, unittest]
import std/posix
import vm_harness
import vm_harness/cloud_init_seed
import vm_harness/backends/libvirt

when not defined(linux):
  echo "[skip] t_vm_harness_libvirt_linux_smoke: Linux host required"
  quit(0)

proc kvmAvailable(): bool =
  var st: Stat
  stat("/dev/kvm", st) == 0 and S_ISCHR(st.st_mode)

proc freeLoopbackPort(): int =
  let s = newSocket()
  defer: s.close()
  s.bindAddr(Port(0), "127.0.0.1")
  int(s.getLocalAddr()[1])

let golden = getEnv("VMH_LINUX_CLOUD_GOLDEN")
if golden.len == 0 or not fileExists(golden):
  echo "[skip] t_vm_harness_libvirt_linux_smoke: VMH_LINUX_CLOUD_GOLDEN not " &
       "set (run guest-recipes/linux-x64-cloud/fetch-image.sh)"
  quit(0)
if not kvmAvailable():
  echo "[skip] t_vm_harness_libvirt_linux_smoke: /dev/kvm not available"
  quit(0)
for tool in ["virsh", "ssh-keygen", "ssh", "qemu-img"]:
  if findExe(tool).len == 0:
    echo "[skip] t_vm_harness_libvirt_linux_smoke: " & tool & " not on PATH"
    quit(0)

const Hostname = "vmh-linux-smoke"

suite "e2e_vm_harness_libvirt_linux_smoke":
  test "cloud-init guest boots, runs the no-op gate over SSH, leaves no residue":
    let scratch = getTempDir() / ("vmh-libvirt-linux-smoke-" & $getpid())
    removeDir(scratch)
    createDir(scratch)
    let key = scratch / "id_ed25519"
    let kg = execCmdEx("ssh-keygen -q -t ed25519 -N '' -C vmh-smoke -f " &
                       quoteShell(key))
    check kg.exitCode == 0
    let pub = readFile(key & ".pub").strip()

    let b = newLibvirtBackend(
      libvirtUri = "qemu:///session",
      imagePoolDir = scratch / "pool",
      sshUser = "vmh",
      sshPassword = "",
      sshKeyPath = key,
      sshGuestOs = goLinux,
      sshReadyTimeoutSec = 300)
    let name = "repro-vm-libvirt-linux-smoke-" & $getpid()
    createDir(b.imagePoolDir)
    let seed = b.noCloudSeedIsoPathFor(name)
    writeNoCloudIso(seed,
      "#cloud-config\n" &
      "users:\n" &
      "  - name: vmh\n" &
      "    shell: /bin/bash\n" &
      "    sudo: ALL=(ALL) NOPASSWD:ALL\n" &
      "    ssh_authorized_keys:\n" &
      "      - " & pub & "\n" &
      "ssh_pwauth: false\n",
      "instance-id: " & name & "\nlocal-hostname: " & Hostname & "\n")

    let spec = EphemeralCloneSpec(
      name: name,
      goldenImage: golden,
      cpus: 2,
      memoryMB: 2048,
      serialLogPath: scratch / "serial.log",
      noCloudSeedIso: seed,
      sshForwardPort: freeLoopbackPort())
    var vm = b.provisionEphemeralClone(spec)
    let overlay = vm.extra.getOrDefault("overlayPath", "")
    check vm.ipAddress == some("127.0.0.1")
    try:
      b.startAndAwaitReady(vm, timeoutSec = 300)
      let ci = b.execInGuest(vm, initTable[string, string](),
                             @["cloud-init", "status", "--wait"],
                             timeoutSec = 300)
      checkpoint "cloud-init status: " & ci.stdout
      check ci.exitCode == 0
      let gate = b.execInGuest(vm, initTable[string, string](),
                               @["sh", "-c", "true && hostname"])
      check gate.exitCode == 0
      check gate.stdout.strip() == Hostname
    finally:
      b.stopAndCleanup(vm, deleteVm = true)

    check not b.domainExists(name)
    check overlay.len > 0 and not fileExists(overlay)
    check not fileExists(seed)
    check fileExists(golden)
    removeDir(scratch)
