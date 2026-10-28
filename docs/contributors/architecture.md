# Gosti architecture

**Audience**: contributors working on gosti (formerly vm-harness). This
document describes the library and CLI as they are built in this tree. It is
kept true by the code and tests it names. A change that alters what a section
describes updates that section in the same pull request. How to *use* gosti is
in the [user guide](https://metacraft-labs.github.io/gosti/).

## 1. Overview

**vm-harness** is a focused library + CLI for cross-platform VM lifecycle orchestration in test harnesses and dev workflows. It provides one abstraction over multiple backend hypervisors (Hyper-V, WSL, libvirt/QEMU, Tart, UTM) so test code can drive any of them through the same primitives.

**In scope**: provision a baseline guest image, fast per-gate reset between test invocations, exec command in guest with captured output, copy files in/out, install argv-tracing shims around guest-side tools, write a standardized output envelope. Single-machine, single-process orchestration.

**Out of scope**: image-build pipelines (use Packer for those), agent execution semantics (vm-harness doesn't know what a "task" is — consumers compose), cloud-fleet management (use Terraform or AH's own fleet orchestrator), microVM-grade sub-second cold-starts (use microsandbox if that's the requirement).

The library lives in a standalone repository, `metacraft-labs/vm-harness`, deliberately *not* bundled inside `nixos-modules` — consumers should be able to add it as a focused dependency without pulling in unrelated infrastructure.

## 2. Why this exists (prior-art summary)

No existing project fills this niche. The closest matches each fail structurally:

| Project | Why it doesn't replace vm-harness |
|---|---|
| **libvirt** | Closest abstraction depth; many bindings exist (libvirt-go, libvirt-python, `virt` Rust crate). But its backend set is KVM/QEMU/Xen/ESX/Bhyve plus a *read-mostly* Hyper-V driver. No Tart, no UTM, no WSL — those frameworks aren't libvirt-shaped. |
| **HashiCorp Vagrant** | Right backend topology (built-in Hyper-V, plugins for libvirt/UTM, pending Tart). But Ruby user-tool; the Go rewrite has been alpha since 2022; the Tart provider request ([vagrant#12760](https://github.com/hashicorp/vagrant/issues/12760)) has been open four years with no shipped plugin. Not viable as a library foundation. |
| **KubeVirt v1.8 HAL** (Mar 2026) | Newest serious multi-hypervisor abstraction. But K8s-bound; server hypervisors only. |
| **microsandbox** (Rust, 2025) | Closest *delivery shape* — multi-language SDKs over multiple backends. But optimized for ephemeral OCI microVMs (<200 ms cold start), not golden-image VM testing. Bypasses Tart/UTM/Hyper-V rather than wrapping them. |
| **Cua/Lume**, **Tart**, **Anka**, **Orchard** | Single-backend silos. Tart itself is a CLI, not a library with a stable API. |
| **Packer** | Image-build only — no start/exec/snapshot lifecycle. But its `packer-plugin-tart` and `packer-plugin-utm` are reference implementations for driving those backends programmatically. |

**Design references worth borrowing from**:

- *libvirt domain API* — the battle-tested lifecycle contract; informs which primitives the trait needs (start/stop/snapshot/revert/clone).
- *Cuckoo Sandbox "Machinery" interface* — clean abstract-base-class shape for multi-backend VM management (used for malware analysis). Worth reading their abstraction layer for API design.
- *KubeVirt v1.8 HAL plugin model* — recent thinking on multi-hypervisor abstraction; clean separation of generic lifecycle from per-backend transport.
- *microsandbox API* — the cross-platform SDK delivery model that informs how vm-harness ships: one Nim library and CLI, with other languages binding to the CLI (§8).
- *cirruslabs/packer-plugin-tart* and *cirruslabs/packer-plugin-utm* — Go reference implementations for driving Tart and UTM. We won't depend on them but can study the patterns.
- *vagrant_utm* (Ruby+AppleScript) — proves UTM CLI automation is feasible; reference for `utmctl` invocation patterns.

## 3. Architecture

### 3.1 Three-tier ownership model

vm-harness provides *generic primitives only*. Consumer-specific orchestration lives in the consumer's own repo.

- **Tier 1 — vm-harness (this library)**: VM lifecycle (provision, revert, start, stop), generic in-guest scripts (`exec a command`, `install argv tracer for any binary`, `write output to standardized layout`), output envelope.
- **Tier 2 — reprobuild's test suite**: gate-binary build steps, REPRO_M69_*_VM env-var dispatch, reprobuild-specific argv-trace shim installations (`useradd`, `launchctl`, `dscl`, etc.), result parsing for reprobuild's `RESULT.txt` schema.
- **Tier 3 — Agent Harbor**: AH binary install, mutagen source sync, cargo test orchestration with isolation flags, JUnit XML extraction.

vm-harness never imports or references Tiers 2 or 3. Consumers compose Tier-1 primitives.

### 3.2 The VmBackend abstraction

Nim concept (concrete OOP-style for clarity):

```nim
type
  VmBackend* = ref object of RootObj
    id*: string                   # "hyperv" | "wsl" | "tart" | "utm" | "libvirt"
    hostPlatform*: HostPlatform   # what host OS this backend runs on
    supportedGuests*: set[GuestOs]

  HostPlatform* = enum hpWindows, hpLinux, hpMacosArm
  GuestOs* = enum goWindows, goLinux, goMacos
  GuestArch* = enum gaX86_64, gaArm64

  BaselineSpec* = object
    name*: string                 # e.g. "base-clean", "base-with-vs"
    sourceImage*: string          # backend-specific reference
    cpus*: int
    memoryMB*: int
    diskGB*: int

  VmHandle* = ref object
    backend*: VmBackend
    name*: string
    ipAddress*: Option[string]
    sshPort*: int
    sshUser*: string
    sshAuth*: SshAuth

  SshAuth* = object
    case kind*: SshAuthKind
    of saPassword: password*: string
    of saKeyFile: keyPath*: string

  ExecResult* = object
    exitCode*: int
    stdout*: string
    stderr*: string
    elapsedMs*: int

  ArgvTraceShim* = object
    wrappedBinaryName*: string    # e.g. "useradd"
    traceLogPath*: string         # in-guest path where argv lines accumulate

# Methods every backend must implement
method probeAvailability*(b: VmBackend): bool {.base.}
  ## Quick capability check: is the underlying tool installed and usable?
  ## Used by `vm-harness --backend auto` for dispatch.

method provisionBaseline*(b: VmBackend, spec: BaselineSpec) {.base.}
  ## Idempotent. Builds the baseline image if absent, else no-op.
  ## Wall-clock budget: minutes to hours (one-time per baseline).

method revertToBaseline*(b: VmBackend, baselineName: string): VmHandle {.base.}
  ## Fast per-gate reset. Returns a started VM ready for exec.
  ## Per-backend wall-clock budget — see §3.4 Performance Contract.

method execInGuest*(b: VmBackend, vm: VmHandle,
                   env: Table[string, string],
                   cmd: seq[string],
                   stdin: string = "",
                   timeoutSec: int = 600): ExecResult {.base.}

method copyToGuest*(b: VmBackend, vm: VmHandle,
                   hostPath: string, guestPath: string) {.base.}

method copyFromGuest*(b: VmBackend, vm: VmHandle,
                     guestPath: string, hostPath: string) {.base.}

method installArgvTraceShim*(b: VmBackend, vm: VmHandle,
                            shim: ArgvTraceShim) {.base.}
  ## Replaces the named binary with a wrapper that logs argv to traceLogPath
  ## then exec's the real binary. Backend-specific implementation but the
  ## contract is the same regardless of guest OS.

method stopAndCleanup*(b: VmBackend, vm: VmHandle, deleteVm: bool = true) {.base.}
  ## Must be safe to call from a `finally` block. Never raises.
```

### 3.3 Lifecycle phases

```
┌─── Session ─────────────────────────────────────────────────────────────┐
│ 1. provisionBaseline("base-clean")  ← one-time, idempotent, slow (mins) │
│                                                                         │
│ ┌─── Per gate (called 10-15× per session) ───────────────────────────┐  │
│ │ 2. vm = revertToBaseline("base-clean")  ← FAST per §3.4            │  │
│ │ 3. copyToGuest(vm, …)                                              │  │
│ │ 4. installArgvTraceShim(vm, …)   (consumer requests, e.g. Tier-2)  │  │
│ │ 5. execInGuest(vm, env, cmd)     (consumer's actual test command)  │  │
│ │ 6. copyFromGuest(vm, …)          (artifact harvest)                │  │
│ │ 7. stopAndCleanup(vm, deleteVm=true)   in `finally`                │  │
│ └────────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│ 8. Session-end cleanup: ensure no stale ephemerals remain               │
└─────────────────────────────────────────────────────────────────────────┘
```

The `revertToBaseline` semantics are deliberately uniform across backends with different underlying mechanisms:

- Hyper-V: `Restore-VMCheckpoint` (native snapshot)
- libvirt: `virsh snapshot-revert` (native snapshot)
- UTM: `utmctl clone <base-clean.utm> <ephemeral>` (no native snapshots; clone is substitute)
- Tart: `tart delete <ephemeral> && tart clone <golden> <ephemeral>` (no native snapshots; clone-from-OCI-cache is substitute)
- WSL: `wsl --unregister <ephemeral> && wsl --import <ephemeral> <dir> <rootfs.tar.gz>` (no snapshots; throwaway-distro is substitute)

The consumer doesn't care which mechanism the backend uses; it only cares that revert is fast enough to be acceptable between every gate.

### 3.4 Per-Gate Reset Performance Contract

| Backend | Per-gate revert wall-clock target | Mechanism |
|---|---|---|
| Hyper-V | ≤ 10s | `Restore-VMCheckpoint` |
| libvirt/QEMU | ≤ 10s | `virsh snapshot-revert --running` |
| UTM | ≤ 20s | `utmctl clone` from local `base-clean.utm` |
| Tart | ≤ 30s | `tart clone` from local OCI cache (CoW APFS) |
| WSL | ≤ 20s | `wsl --import` from cached rootfs tarball |

Budgets are *targets*, not hard SLAs. Backends that miss budget by >50% must either:

1. Reduce overhead (e.g., keep base-clean VM pre-warmed instead of cold-cloning each time).
2. Implement *gate-grouping* — a consumer-side optimization where pure-logic gates (no host mutations) run back-to-back in one clone, and only destructive gates trigger a fresh revert.

No single regression test enforces this table across every backend. The
libvirt budget is checked by `tests/e2e/t_libvirt_live_snapshot_restore.nim`,
and the measured numbers behind the Hyper-V and libvirt rows are in
[`per-backend-notes/`](per-backend-notes/).

### 3.5 Output envelope

vm-harness defines the *directory layout and a few mandatory envelope files*; consumers fill in their own domain-specific artifacts.

```
<output-dir>/
├── 00-provision.log    ← vm-harness's session-start log (mandatory)
├── 02-<cmd>-run.txt    ← stdout/stderr/exit of each execInGuest call (mandatory)
├── RESULT.txt          ← vm-harness's per-step status + verdict (mandatory)
├── DONE                ← sentinel written last (mandatory)
│
├── 01-<gate>-build.log ← reprobuild's gate-build output (consumer-written)
├── 03-passwd-cmd-trace.log ← reprobuild's argv-trace harvest (consumer-written)
└── …                   ← arbitrary consumer files
```

The `DONE` sentinel pattern is borrowed from the existing PowerShell harnesses and ensures downstream parsers can distinguish complete from interrupted runs.

### 3.6 Error model

```nim
type
  VmHarnessError* = object of CatchableError
    backend*: string
    phase*: LifecyclePhase  # provisioning, revert, exec, copy, cleanup
    cause*: ref Exception   # the underlying error if any

  LifecyclePhase* = enum lpProvisioning, lpRevert, lpExec, lpCopy, lpCleanup, lpProbe

  TimeoutError* = object of VmHarnessError
  BackendUnavailableError* = object of VmHarnessError
  GuestBootFailureError* = object of VmHarnessError
  CommandFailedError* = object of VmHarnessError
    exitCode*: int
```

Cleanup *never raises* — `stopAndCleanup` swallows errors and logs them. Everything else can raise; consumers wrap calls in `try/finally` and ensure `stopAndCleanup` runs.

## 4. Per-backend specifications

### 4.1 Hyper-V (HostPlatform: hpWindows; Guests: goWindows, goLinux)

- **Transport**: PowerShell Direct via VMBus (no networking needed in guest). `Invoke-Command -VMName <name> -ScriptBlock { ... }`.
- **File transfer**: `Copy-VMFile -VM <name> -SourcePath ... -DestinationPath ...` (Integration Services file-copy channel).
- **Provisioning**: wraps the existing `reprobuild/tools/hyperv-m69-system/provision-base-vm.ps1` (the Windows-11-dev VHDX + Panther-override autounattend + Nim/gcc install + checkpoint pattern). The script stays in reprobuild; vm-harness's HyperVBackend calls it via `osproc.startProcess`.
- **Revert**: `Restore-VMCheckpoint -VMName <name> -Name <baseline>` + `Start-VM`. Poll `Invoke-Command -VMName <name> { hostname }` for ready signal.
- **Auth**: PowerShell Direct uses SAM credentials cached in DPAPI-sealed `vm-cred.xml` (existing mechanism from `provision-base-vm.ps1`). No SSH needed.
- **Cleanup**: `Stop-VM -TurnOff -Force` (never `Save-VM` — saved-state revert desyncs the snapshot).

### 4.2 WSL (HostPlatform: hpWindows; Guests: goLinux)

- **Transport**: `wsl -d <distro> -- <cmd>` direct exec. No SSH; no networking dance.
- **File transfer**: `/mnt/d/...` 9P bridge from host to guest; `cp` from inside the distro to copy out. (Slower than ext4 inside the distro — see existing WSL harness README.)
- **Provisioning**: download Ubuntu cloud rootfs once (`ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz`, ~325 MB, cached); `wsl --import <name> <install-dir> <rootfs.tar.gz>` to register a throwaway distro.
- **Revert**: `wsl --terminate <name> && wsl --unregister <name> && wsl --import <name> <install-dir> <rootfs.tar.gz>`. No real snapshot — re-import is the substitute.
- **Auth**: runs as root inside the throwaway distro by default.
- **Cleanup**: `wsl --terminate <name> && wsl --unregister <name>` in `finally`. Verify post-cleanup that `wsl --list --quiet` no longer lists the distro.

### 4.3 Tart (HostPlatform: hpMacosArm; Guests: goMacos, goLinux ARM64)

- **Transport**: SSH over Tart's user-mode networking. `tart ip <name>` returns the auto-assigned IP. `sshpass -p admin ssh admin@<ip>` for the cirruslabs golden's default password (alternative: seed an authorized_keys file at clone time for key-only auth).
- **File transfer**: `scp` over SSH for small payloads; `tart --dir <name>=<host-path>:<guest-path>` for larger shared folders.
- **Provisioning**: `tart pull <golden-image-ref>` (cirruslabs golden or our own AH-branded golden). Stored in `~/.tart/cache/OCIs/`.
- **Revert**: `tart stop <ephemeral> && tart delete <ephemeral> && tart clone <golden-image-ref> <ephemeral> && tart run --no-graphics <ephemeral> &` + SSH-ready poll. Tart's clone is CoW APFS — fast but not snapshot-fast.
- **Auth**: cirruslabs golden defaults to admin/admin password SSH.
- **Cleanup**: `tart stop <ephemeral> && tart delete <ephemeral>` in `finally`. Stale-ephemeral cleanup at session start: `tart list` and delete any `repro-vm-*` left from prior aborted runs.

#### 4.3.1 Running-state snapshots

The Tart backend does not implement `snapshotRunning`, so every Tart revert is
a clone plus a cold boot. The backends that do implement it are Hyper-V,
libvirt and Incus (and the `noop` and `mock` fixtures).

### 4.4 UTM (HostPlatform: hpMacosArm; Guests: goWindows ARM64)

- **Transport**: SSH over UTM's user-mode networking. `utmctl ip <name>` to get the IP. Windows OpenSSH on the guest side.
- **File transfer**: `scp` over SSH; or virtio-9p/SMB shared folder via UTM bundle config.
- **Provisioning**: download Windows 11 ARM Insider Preview ISO (URL resolved at runtime); build an autounattend ISO mirroring the Hyper-V Panther-override structure (admin user, OOBE skip flags, OpenSSH server enabled); drive install via `qemu-system-aarch64 -accel hvf` with both ISOs attached; capture as `base-clean.utm` bundle.
- **Revert**: `utmctl stop <ephemeral> && utmctl delete <ephemeral> && utmctl clone <base-clean.utm> <ephemeral> && utmctl start <ephemeral>` + SSH-ready poll. utmctl clone is local-disk (faster than Tart's OCI-cache clone).
- **Auth**: admin/<configured-password> set in autounattend.xml.
- **Cleanup**: `utmctl stop <ephemeral> && utmctl delete <ephemeral>` in `finally`.

### 4.4.1 Direct QEMU Windows ARM helper startup

The direct QEMU Windows ARM backend starts swtpm before launching the guest.
Wait for its control socket for up to 30 seconds, using a monotonic deadline;
report an early child exit immediately. This allows a live helper to start
while the macOS host serves other fleet jobs. The former three-second bound
repeatedly expired under load; Gosti CI reproduced that at `33aa89dc` on
2026-09-29.

If startup fails, terminate and reap the helper and remove its socket before
returning the error. The caller receives a PID only after successful startup,
so it cannot own cleanup of a failed attempt. A successful startup transfers
process ownership to the existing guest lifecycle. Tests must cover delayed
socket creation, early exit and a helper that never becomes ready.

### 4.5 libvirt/QEMU (HostPlatform: hpLinux; Guests: goLinux, goWindows)

- **Transport**: SSH over libvirt's default-switch NAT. Guest's IP via `virsh domifaddr`.
- **File transfer**: `scp` over SSH; or virtiofs shared folder via libvirt domain XML.
- **Provisioning**: libvirt domain XML defining the VM; cloud-init seed for Linux guests (NoCloud ISO); autounattend.xml for Windows guests. Existing `nixos-modules/vm-images/ubuntu/` and `nixos-modules/vm-images/windows/` recipes inform the provisioning.
- **Revert**: `virsh snapshot-revert <domain> <baseline> --running` (native qcow2 snapshot).
- **Auth**: cloud-init injects SSH pubkey for Linux; autounattend creates admin user for Windows.
- **Cleanup**: `virsh shutdown <domain>` then `virsh undefine --remove-all-storage <domain>` (only for ephemeral domains; baseline domains preserved).
- **TPM**: on the transient `bootFromMedia` path, `BootMediaSpec.tpmEnabled` emits `--tpm emulator,model=tpm-tis,version=2.0` (`transientBootTpmArgs`), and nothing when it is false. `emulator` makes **libvirtd** own the swtpm lifecycle — it starts one per domain, keeps its state under the domain's directory and reaps it when the domain goes away — which is why this backend deliberately does *not* copy `qemu_boot.nim`'s hand-rolled swtpm supervision. `version=2.0` is pinned rather than left to libvirt's default, which is 1.2 on some releases. The `EphemeralCloneSpec` clone path (`buildEphemeralDomainXml`) has no `tpmEnabled` field and therefore nothing to honour; the Windows-golden install argv (`buildVirtInstallArgs`) deliberately emits no TPM at all and relies on the autounattend's `LabConfig` bypass keys instead.

### 4.6 qemu-boot (HostPlatform: hpLinux; Guests: goLinux, goWindows)

A **daemon-less direct-boot** backend (`backends/qemu_boot.nim`). It implements only the `bootFromMedia` / `captureSerial` / `expectLine` / `serialSend` / `waitForShutdown` / `stopAndCleanup` slice of the trait — it boots a disk image or ISO to assert on OS bring-up, and does not pretend to offer baselines, snapshots or `execInGuest`.

**Why it exists alongside §4.5.** For a long-lived, networked, pool-managed guest the libvirt backend is the right adapter. It is the wrong one for a boot-assertion gate:

- It needs `virt-install` and a running `libvirtd` the caller has authorisation on. A gate whose purpose is to prove the serial-expect engine works must not be able to *skip* because a system daemon is missing.
- It defines a domain in a **host-global namespace**. On a host that also runs production CI, a leaked transient domain is a hazard; an owned child process that dies with its parent is not.
- Its file-backed serial device is output-only — `LibvirtBackend.serialSend` raises by construction — so driving a login prompt is not reachable from it without changing the device model.

**What it does not duplicate.** Matching goes through `serial.nim`'s `SerialLineBuffer` / `expectLineImpl`, the same cursor-advancing PCRE engine every other backend uses. There is exactly one serial-expect implementation in the tree. Firmware resolution is shared too: both this backend and §4.5 call `firmware.resolveOvmfPair`.

- **Serial device**: one `-chardev socket` carrying QEMU's own `logfile=`, wired to `-serial`. QEMU writes every guest byte to the log from the first firmware byte onward whether or not anything is connected, so reads poll a plain file (no reader thread, no connect race). `serialSend` connects to the socket, writes, drains briefly and disconnects — never holding the connection means the harness cannot back-pressure the guest's console by failing to drain it.
- **Disk**: always a qcow2 CoW overlay over the caller's image, inside the run directory. The artifact under test is never mutated.
- **Direct kernel boot**: `BootMediaKind.bmkKernel` treats `mediaPath` as a kernel image and takes `extra["initrdPath"]` / `extra["kernelCmdline"]`, emitting `-kernel` / `-initrd` / `-append`. There is no disk, bootloader or partition table, so a purpose-built guest reaches userspace in about a second — which is what makes an unconditional, non-skipping boot gate affordable. It is a qemu-boot capability only: `hyperv` and `libvirt` reject `bmkKernel` explicitly rather than falling through to a disk boot.
- **Firmware**: `generation: 2` resolves an OVMF pair and copies the NVRAM *template* to a per-VM writable file; `generation: 1` boots SeaBIOS. The default is 2, except for `bmkKernel` where it is 1 — OVMF's fw_cfg kernel loader adds seconds of firmware initialisation to a guest whose whole point is to be measured in seconds.
- **Acceleration**: `baAuto` picks KVM when `/dev/kvm` is openable read-write and TCG otherwise, so the backend works in a container with no `/dev/kvm`. The existence probe must be `pathExists`, not `fileExists`: `/dev/kvm` is a character device and `fileExists` is `S_ISREG`.
- **Naming**: every VM name must start with the backend's configured `namePrefix`, which is what lets `sweepStaleQemuBootProcesses` recognise what the harness owns (it matches the `-name <prefix>…` argv entry, never "is a qemu process"). swtpm carries no `-name`, so the sweep matches it on its `--tpmstate dir=<stateDir>/<prefix>…/tpm` argument instead.
- **Socket paths**: serial and swtpm sockets share an exclusively claimed mode-0700 directory, named from the absolute run-directory hash. Paths reserve the terminating NUL within the host's `sun_path` byte limit. If `TMPDIR` is too deep, a short, owned mode-0700 `XDG_RUNTIME_DIR` is preferred, otherwise POSIX `/tmp` is used. Existing socket or run directories are refused, never adopted or deleted; the state root must be owned and not writable by others.
- **Cleanup**: `stopAndCleanup` SIGTERMs then SIGKILLs the child and removes both the socket directory and the run directory (overlay, NVRAM copy, swtpm state and QEMU's own logs). It also kills the swtpm, which is *not* a child of QEMU and is reaped by nothing else. Startup records both paths and their device/inode identities. Cleanup checks those identities without following symlinks before directory removal, including after partial setup failure and when a retained run is deleted later; missing identities or mismatches do not authorize deletion. Cleanup does not depend on later environment changes, is idempotent, and can retry a failed removal. Callers should place `BootMediaSpec.serialLogPath` *outside* the run directory so the transcript survives as an artifact.
- **TPM**: `BootMediaSpec.tpmEnabled` starts a per-VM `swtpm socket --tpm2` whose state directory lives inside the run directory, waits for its control socket, and appends the QEMU trio:

  ```
  -chardev socket,id=chrtpm,path=<swtpm ctrl socket>
  -tpmdev emulator,id=tpm0,chardev=chrtpm
  -device tpm-tis,tpmdev=tpm0
  ```

  Three things about that trio are load-bearing. The device is **`tpm-tis`** — `qemu_windows_arm.nim`, the backend this lifecycle is modelled on, emits `tpm-tis-device`, which is aarch64's spelling and does not exist on x86_64. The chardev is swtpm's **control** channel, not a data channel: QEMU's `emulator` backend hands swtpm a socketpair for data itself. And the trio is appended **last**, so the TPM argv is exactly the TPM-less argv plus six entries — an invariant `t_tpm_device_args` asserts, because a vTPM change that also perturbed the machine model or the serial wiring would make the two polarities of every other boot gate incomparable.

  A missing `swtpm` is a hard failure, never a silent TPM-less boot. Availability is deliberately *not* folded into `probeAvailability`: a TPM-less boot must not become unavailable because swtpm is absent, and a TPM-requiring boot must not be skipped because it is.

  Both polarities are gated. `tests/unit/t_tpm_device_args.nim` asserts the argv is present when enabled and absent when not; `tests/integration/t_guest_sees_tpm_device.nim` boots a real Linux guest (`nix/guest-linux-tpm.nix` — a stock nixpkgs `bzImage` plus a busybox initramfs, direct-kernel-booted) and asserts the guest reports `/dev/tpm0` plus a real TPM2_GetCapability(FAMILY_INDICATOR) response of `"2.0"` with the flag, and no TPM device without it.

### 4.7 Incus (HostPlatform: hpLinux; Guests: goLinux)

- **Transport**: the local Incus administrative socket through the `incus`
  CLI; in-guest commands use `incus exec`.
- **Default ephemeral lifecycle**: `incus launch` → probe → force-delete. No
  KVM device or nesting key is present by default, preserving the original
  command path.
- **Operator capability lifecycle**: `EphemeralIncusSpec.securityNesting` or
  `.nestedKvm` switches creation to `incus init`; vm-harness applies the fixed
  configuration/device policy while stopped and then calls `incus start`.
  Nested KVM implies `security.nesting`, attaches only host `/dev/kvm` at guest
  `/dev/kvm` as `unix-char mode=0666`, converges that mode after start, and
  verifies the numeric mode plus an actual read/write open before returning.
  Any failure force-deletes the half-created container.
- **Trust boundary**: these fields and matching CLI flags are host-controller
  policy. They accept no arbitrary device path/type/mode and must never be
  populated from guest user-data or workflow input. Over `serve`, possession
  of the overlay-only bearer token already authorizes the complete host worker
  CLI, including these flags; the token is an operator secret.
- **Tests**: the deterministic subprocess contract pins default-off argv,
  pre-start ordering, implied nesting, every failure-stage cleanup, and the
  authenticated `serve` forwarding path. The separate host-gated roundtrip is
  designed to prove a real Incus guest receives accessible nested KVM and
  leaves no residue when its explicit Incus/KVM prerequisites are healthy; a
  prerequisite skip is not claimed as coverage.

## 5. In-guest scripts (Tier-1 only)

### 5.1 posix.sh

Used by WSL, Tart-macOS, Tart-Linux. Provides POSIX shell primitives.

Signature (CLI):

```
vm-harness-guest.sh <subcommand> [args]
  exec <output-dir> [--env KEY=VAL ...] -- <cmd...>
    # Runs <cmd>, captures stdout to <output-dir>/02-<basename>-run.txt
    # with stderr interleaved, exit code recorded.
  
  install-trace-shim <real-binary> <log-path>
    # Replaces /usr/local/bin/<real-binary> with a wrapper that appends
    # argv (one per line, format: "ts <tab> argv0 <tab> argv1 ..."), then
    # exec's the original via /usr/bin/<real-binary>.real.
    # Backs up the original to <real-binary>.real if not already done.
  
  uninstall-trace-shim <real-binary>
    # Restores the original binary, removes the .real backup.
  
  write-result <output-dir> <step-name> <status>
    # Appends a row to <output-dir>/RESULT.txt.
  
  finalize <output-dir> <verdict>
    # Writes final verdict to RESULT.txt, then creates the DONE sentinel.
```

Output format:

```
RESULT.txt:
  step: provision  status: ok      elapsed_ms: 12345
  step: exec       status: ok      elapsed_ms: 234
  step: harvest    status: ok      elapsed_ms: 567
  verdict: PASS
```

The shim wrapper template (for `install-trace-shim`):

```bash
#!/bin/sh
printf '%s\t%s\n' "$(date +%s%N)" "$0 $*" >> "@TRACE_LOG_PATH@"
exec "@REAL_BIN_PATH@" "$@"
```

(`@…@` placeholders are replaced at install time.)

### 5.2 windows.ps1

Used by Hyper-V and UTM backends. Same subcommand surface as posix.sh, PowerShell semantics:

```powershell
vm-harness-guest.ps1 -Subcommand exec -OutputDir <dir> -Env @{...} -Cmd <args>
vm-harness-guest.ps1 -Subcommand install-trace-shim -RealBinary <name> -LogPath <path>
…
```

Trace shim template (PowerShell):

```powershell
"$([DateTimeOffset]::Now.ToUnixTimeMilliseconds())`t$($MyInvocation.MyCommand.Path) $($args -join ' ')" |
    Out-File -FilePath "@TRACE_LOG_PATH@" -Append -Encoding utf8
& "@REAL_BIN_PATH@" @args
exit $LASTEXITCODE
```

### 5.3 Shim semantics

- Shim writes happen *before* the real exec, so even if the real binary hangs, the call is recorded.
- Multi-second precision (POSIX uses nanoseconds; Windows uses milliseconds) is sufficient for argv-trace ordering.
- Shims preserve argv0, exit code, stdin, stdout, stderr — they are transparent except for the log line.
- Multiple shims can wrap the same binary if they chain via `.real` / `.real.real` — but the design assumes one shim layer.

## 6. CLI reference

### 6.0 Command names

The project was renamed vm-harness → gosti. The binary is installed under
BOTH names, and they are the same file:

- `bin/gosti` — the primary name. `meta.mainProgram` is `gosti`, so
  `lib.getExe` consumers run this.
- `bin/vm-harness` — a relative symlink to `gosti`, kept indefinitely for
  compatibility. Existing callers (the `vm-harness serve` units, the GARM
  provider's default binary path, scripts, operator muscle memory) need no
  change.

Both the flake's `installPhase` and `just build` produce this layout through
the one script `scripts/install-binaries.sh`, so they cannot disagree.
Windows releases use `scripts/install-binaries.ps1` to install byte-identical
`gosti.exe` and `vm-harness.exe` files. This preserves the compatibility name
without requiring symlink privileges. The command-name integration test runs
the corresponding production installer on each OS, then checks help output
and a real daemon started through the compatibility name.
Behaviour does not depend on the invoked name: argv, exit codes, output, and
the serve daemon's worker re-exec (it runs the RESOLVED executable) are
identical. Gated by `t_gosti_command_names`.

Some surfaces keep the old name because their consumers have to move first.
The environment variables and state directories accept both names (§6.0.1).
The `share/vm-harness/` payload path and the `vm_harness` Nim package and
module name are unchanged.

Diagnostics are prefixed `gosti: …` and the serve daemon logs
`[gosti serve] …`. No consumer keys on the
prefix: the GARM provider identifies an old daemon by the substrings
`Unknown flag: '--label'` / `unknown subcommand '<verb>'`, and the enrollment
harvest greps `identity keyId`, so both prefixes are accepted wherever text is
matched. The `vm-harness` command name stays as a symlink indefinitely.

#### 6.0.1 Environment variables and state directories

Every setting the binary reads from the environment has a canonical
`GOSTI_<X>` name. The legacy name keeps working: `VMH_<X>` for most settings,
`VM_HARNESS_<X>` for the per-backend state dirs (`VM_HARNESS_TART_STATE_DIR`
→ `GOSTI_TART_STATE_DIR`). The canonical name is read first; if it is SET it
wins (even when empty, like any set variable), otherwise the legacy one is
read. A host can therefore export both during a rollout, and a host that still
exports only `VMH_*` is unaffected. One helper, `env_names.gostiEnv`, does this
for every reader, and `t_gosti_env_names` checks new-only / old-only / both for
each variable, plus that no reader escapes the list.

Default state directories (`$XDG_STATE_HOME/…`, `~/.local/state/…`,
`%LOCALAPPDATA%\…`, `/var/lib/…/ephemeral`) prefer `…/gosti/…` and fall back to
an EXISTING `…/vm-harness/…`; nothing is ever moved, because a running daemon
may hold the old one. A fresh host with neither gets `gosti/`. Independent
processes resolve the same way, so they still agree without probing.

Still spelled the old way: the guest-recipe shell seams (`VMH_RUNNER_*`,
`VMH_BUILD_DIR`; libvirt passes `GOSTI_BUILD_DIR` alongside) and the
PowerShell output markers (`VMH_GONE`, `VMH_DISK_GROWN=`, …).

The examples below use `vm-harness`; `gosti` is interchangeable.

```
vm-harness <subcommand> [flags]

PROVISION:
  vm-harness provision \
    --backend <hyperv|wsl|tart|utm|libvirt|auto> \
    --baseline <name> \
    [--cpus N] [--memory-mb N] [--disk-gb N] \
    [--source-image <ref>]

REVERT-AND-EXEC (one-shot — provisions if needed, reverts, execs, cleans up):
  vm-harness run \
    --backend <name|auto> \
    --baseline <name> \
    --output-dir <path> \
    [--env KEY=VAL ...] \
    [--copy-to host:guest ...] \
    [--copy-from guest:host ...] \
    [--install-shim binary:logpath ...] \
    -- <command args>

BOOT (assert on OS bring-up over the serial console):
  vm-harness boot \
    --backend <libvirt|hyperv|qemu-boot|auto> \
    --source-image <path> \
    [--kind <auto|iso|qcow2|vhdx|rootfs-tar|kernel>] \
    [--initrd <path>] [--kernel-cmdline <string>] \
    [--generation <1|2>] [--tpm] [--secure-boot] \
    [--expect <regex>] [--keep | --viewer | --screenshot <path>]

  `--tpm` sets `BootMediaSpec.tpmEnabled`; `--secure-boot` sets
  `BootMediaSpec.secureBootEnabled`. Both are threaded through — a spec
  field no caller can set is the same defect as one no backend reads.
  `--initrd` / `--kernel-cmdline` are valid only with `--kind kernel`,
  which auto-selects the `qemu-boot` backend on Linux.

PROBE (capability detection):
  vm-harness probe
    # Prints a JSON report of available backends + supported guests.

SHELL (interactive, useful for debugging):
  vm-harness shell \
    --backend <name|auto> \
    --baseline <name>

LIST-BACKENDS:
  vm-harness backends
    # Tabular listing.
```

The `auto` backend selection picks based on `(host OS, requested guest OS)`:

```
(Windows host, Windows guest) → hyperv
(Windows host, Linux guest)   → wsl
(Linux host, Linux guest)     → libvirt
(Linux host, Windows guest)   → libvirt    (QEMU+autounattend)
(macOS host, macOS guest)     → tart
(macOS host, Linux guest)     → tart       (Linux ARM64 via tart)
(macOS host, Windows guest)   → utm
```

## 7. Library API (Nim consumers)

reprobuild's tests import vm-harness as a regular Nim library:

```nim
import vm_harness

let backend = autoSelectBackend(guest = goMacos)
backend.provisionBaseline(BaselineSpec(name: "base-clean", ...))

try:
  let vm = backend.revertToBaseline("base-clean")
  backend.copyToGuest(vm, "build/bin/repro", "/tmp/repro")
  backend.installArgvTraceShim(vm,
    ArgvTraceShim(wrappedBinaryName: "dscl",
                  traceLogPath: "/tmp/dscl-trace.log"))
  let r = backend.execInGuest(vm,
    env = {"REPRO_PHASE5_MACOS_PASSWD_VM": "1"}.toTable,
    cmd = @["/tmp/repro", "test", "passwd-user-mac"])
  backend.copyFromGuest(vm, "/tmp/dscl-trace.log",
                            outputDir / "03-dscl-cmd-trace.log")
  if r.exitCode != 0:
    raise newException(GateFailureError, ...)
finally:
  backend.stopAndCleanup(vm)
```

The dotfiles `vm` CLI invokes vm-harness as a child process:

```sh
vm-harness shell --backend tart --baseline base-clean
# or
vm-harness run --backend tart --baseline base-clean ... -- <cmd>
```

## 8. Language bindings (thin subprocess adapters)

There is exactly one implementation of the backends: this Nim library. A
binding in another language carries no backend code. The Rust binding in
agent-harbor's `ah-vm` crate is the reference case: its `GostiOrchestrator`
implements `ah-vm`'s existing `VmOrchestrator` trait by driving `gosti`:

- **local** — invoke the `vm-harness` CLI's generic-CRUD subcommands
  (`vm-harness crud <verb> … `, §6), or
- **remote** — `POST /v1/exec` against a `vm-harness serve` daemon ([`serve.md`](serve.md), the
  serve protocol),

and in both cases **parse the CRUD `--json` envelope** documented below. The
binding carries no backend logic, no guest scripts, and no output-envelope
writer of its own — it marshals trait calls into argv/HTTP and unmarshals the
JSON reply. gosti remains the single source of truth for how a VM is created,
started, execed, snapshotted, and destroyed.

### 8.1 The CRUD wire contract (canonical)

This is the contract the binding parses; it is established by the gosti
`crud` façade (`src/vm_harness/crud.nim`) and is the frozen
consumer-facing spec. Do not change a key name or an exit code without
versioning it here.

**Verbs** (one per `VmOrchestrator` method):
`create_vm`, `start_vm`, `stop_vm`, `delete_vm`, `get_vm`, `list_vms`, `exec`,
`copy_to_vm`, `copy_from_vm`, `ssh_endpoint`, `snapshot`, `restore_snapshot`,
`list_snapshots`.

**Response envelope** — every invocation prints exactly one JSON object on
stdout:

```jsonc
// success
{"ok": true,  "verb": "<verb>", "data": { /* verb-specific, see below */ }}
// failure
{"ok": false, "verb": "<verb>",
 "error": {"code": <int>, "kind": "<kind>", "message": "<human text>"}}
```

**`data` shapes** (all keys stable):

| verb | `data` |
|---|---|
| create_vm / start_vm / stop_vm / get_vm | `{"vm": VmInfo}` |
| delete_vm | `{"name": str, "deleted": true, "state": "stopped"}` |
| list_vms | `{"vms": [VmInfo, …]}` |
| exec | `{"exit_code": int, "stdout": str, "stderr": str, "elapsed_ms": int}` |
| copy_to_vm / copy_from_vm | `{"copied": true, "source": str, "dest": str}` |
| ssh_endpoint | `{"ssh": SshEndpoint}` |
| snapshot | `{"snapshot": {"vm": str, "name": str, "id": str}}` |
| restore_snapshot | `{"vm": str, "snapshot": str, "restored": true}` |
| list_snapshots | `{"vm": str, "snapshots": [str, …]}` |

```jsonc
VmInfo      = {"name": str, "backend": str, "baseline": str,
               "state": VmState, "ssh": SshEndpoint | null}
SshEndpoint = {"host": str, "port": int, "user": str, "auth": AuthKind}
VmState     = "stopped" | "starting" | "running" | "paused" | "error"
AuthKind    = "none" | "password" | "keyfile"
```

**Exit codes** (frozen — the binding branches on these, never on message text):

| code | kind | meaning |
|---|---|---|
| 0 | — | success (`"ok": true`) |
| 2 | `bad-args` | missing/invalid argument, unknown verb |
| 3 | `not-found` | VM or snapshot does not resolve |
| 4 | `backend-unavailable` | backend cannot run on this host / not usable |
| 5 | `backend-error` | a backend operation failed |
| 1 | `internal` | any other/unexpected failure |

Over the remote path the same envelope and exit code are relayed by the serve
worker (which re-invokes this exact CLI), so local and remote behaviour are
byte-for-byte identical.

**Framing — where the envelope is on each path:**

- **Local** (`vm-harness crud <verb> …` as a child process): stdout carries
  exactly one line, the envelope, and nothing else. Backend diagnostics, if
  any, go to stderr. The process exit code is the code in the table above.
- **Remote** (`POST /v1/exec` with `argv = ["crud", "<verb>", …]`): serve
  merges the worker's stdout and stderr into NDJSON `log` events, followed by
  a terminal `exit` event that carries the same exit code. The envelope is
  the **last** `log` line, because the CLI prints it after the verb has
  finished. Any earlier `log` lines are backend diagnostics, which the
  consumer should ignore or surface as logs. An `error` event means serve
  itself failed to run the worker (e.g. it could not spawn it, or the exec
  deadline killed it), not that a verb failed, and it carries no envelope.

`tests/e2e/t_crud_serve_parity.nim` pins this: for each case, the local
stdout line and the remote `log` line are byte-identical, and the two exit
codes match.

**Scope of one invocation:** VM state persists across invocations (§8.6).
A VM created by one `vm-harness crud` call, whether local or forwarded over
`/v1/exec`, is visible to `get_vm`/`list_vms`/`start_vm`/`stop_vm`/`exec`/
`copy_*`/`snapshot*`/`delete_vm` in any later call on the same host that
resolves the same crud state directory.

### 8.2 Verb → VmBackend mapping

gosti has no *defined-but-stopped instance* at the `VmBackend` layer —
`provisionBaseline` builds a template, `revertToBaseline` materialises a running
instance. The façade adapts accordingly:

- `create_vm` ⇒ `provisionBaseline` (idempotent) + `revertToBaseline` ⇒ Running.
- `start_vm` ⇒ idempotent when running; re-`revertToBaseline` after a stop.
- `stop_vm` ⇒ `stopAndCleanup(deleteVm=false)`.
- `delete_vm` ⇒ `stopAndCleanup(deleteVm=true)`.
- `exec` / `copy_*` / `ssh_endpoint` ⇒ `execInGuest` / `copyTo|FromGuest` / project the `VmHandle`.
- `snapshot` / `restore_snapshot` / `list_snapshots` ⇒ the matching `VmBackend` snapshot methods.

See `crud.nim`'s module header for the full table. §8.6 covers how the
instance registry persists across invocations.

### 8.3 What a binding depends on

A binding depends on the `gosti` *binary* (built from this repo) at runtime,
discovered on `PATH` or by an explicit path or endpoint. It vendors no backend
sources and no guest scripts.

### 8.4 Correctness gate

A binding's acceptance test is *contract conformance*: drive every method
through the binding against a gosti CLI configured with the `noop` or `mock`
backend, and assert the parsed `VmInfo` / `SshEndpoint` / error mapping. On
this side the contract is pinned by `tests/unit/t_crud_facade.nim`,
`tests/e2e/t_crud_store_roundtrip.nim` and `tests/e2e/t_crud_serve_parity.nim`.

### 8.5 Consumed by

- `ah-vm` — `GostiOrchestrator` becomes an available `VmOrchestrator`
  implementation alongside AH's native ones; callers select gosti for the
  Windows/macOS/Linux hypervisor cells this repo owns.
- Higher-level AH test-isolation harnesses compose that orchestrator's
  lifecycle with AH's own Tier-3 scripts (sync, test, harvest) unchanged.

### 8.6 Cross-invocation state (the crud store)

A subprocess or serve consumer runs one `vm-harness crud` process per verb. So
the façade's instance registry is persisted in a **crud store** on the host
that runs the verb, and the running instance is re-attached on every call.
The §8.1 envelope, verbs and exit codes are unchanged by this.

**Location.** The first *configured* location wins. The chain is never
"first writable", because separate processes must agree without probing.
It mirrors the label store that `ephemeral-label` uses:

1. `--state-dir <root>` on the `crud` command line, giving `<root>/crud`
2. `$VMH_CRUD_STATE_DIR`
3. `$VMH_EPHEMERAL_STATE_DIR/crud`
4. systemd's `$STATE_DIRECTORY/crud`. This is the serve unit's writable state
   directory, the same one that holds `ephemeral-labels`.
5. the user state dir: `%LOCALAPPDATA%\vm-harness\crud` on Windows,
   otherwise `$XDG_STATE_HOME/vm-harness/crud` or
   `$HOME/.local/state/vm-harness/crud`
6. `/var/lib/vm-harness/ephemeral/crud`

A serve daemon's worker re-runs the CLI with the daemon's environment. So
remote calls to one daemon share one store, and a `--state-dir` in the
forwarded argv names a path on the **daemon** host.

**Records.** There is one JSON file per VM,
`<store>/<backend-id>/<name>.json`, written with write-then-rename and mode
0600:

```jsonc
{"schema": "vm-harness/crud-vm/1",
 "name": "<logical name>", "backend": "<backend id>", "baseline": "<template>",
 "state": "running" | "stopped",          // last state the façade set
 "handle": <VmHandle as ephemeral_handle.nim serializes it> | null}
```

`handle` is exactly the record `run --ephemeral --keep` already persists for
`ephemeral-destroy`: instance name, IP, SSH port/user/auth, and the backend's
`extra` (pids, overlay paths, …). Backends therefore need no crud-specific
serialization. `handle` is `null` after `stop_vm`, which releases the
instance; `start_vm` re-materializes it from `baseline`.

Because the logical name becomes a filename, a crud-store name must match
`[A-Za-z0-9][A-Za-z0-9._-]{0,63}`. Anything else is `bad-args` (exit 2).
It is not silently sanitized, because two different names must never map to
one record.

**Deriving state from the hypervisor.** On every call, each loaded record
that holds a handle is reconciled against the backend with the base method
`instancePresence(vm)`:

| backend | how it answers |
|---|---|
| incus | `incus list <name> -c s` (`RUNNING`/`FROZEN` count as running; empty means gone) |
| libvirt | `virsh domstate <name>` (`running`/`paused` count as running; `shut off` is stopped; failure means gone) |
| tart | `tart list` row for the instance (a missing row means gone) |
| hyperv | `Get-VM -Name <name>` (`Off` is stopped; anything else counts as running; missing means gone) |
| mock | its own persisted fleet |
| others (noop, qemu-*, lima, utm, wsl) | `unknown`: the record is trusted |

The reported `VmState` then follows the hypervisor:

- **running**: `running`.
- **stopped**: `stopped`. The handle is kept, and `start_vm` calls
  `startAndAwaitReady` on it.
- **gone**: `error`, with `ssh: null`. The record is **kept**, not
  forgotten, so the consumer learns that the VM vanished outside gosti.
  Guest verbs (`exec`, `copy_*`, `ssh_endpoint`, `snapshot*`) fail with
  `backend-error` (5). `start_vm` re-materializes the VM from `baseline`.
  `delete_vm` runs the never-raising `stopAndCleanup(deleteVm=true)` and
  removes the record.
- **unknown**: the recorded state stands.

If the probe itself fails (the hypervisor cannot be asked), the answer is
`unknown`, never `gone`. Failing to ask must not look like proof of absence.
That is the same fail-closed rule `ephemeral-list` follows.

`list_vms` lists the records of the **resolved backend** only. A store
directory that exists but cannot be read is an error (`internal`, exit 1),
never an empty list.

**Concurrency.** Each verb that names a VM holds a per-VM lock while it runs.
The lock is the directory `<store>/<backend-id>/<name>.lock`, because
`mkdir` is atomic on every supported OS. It contains an `owner` file with the
holder's pid. A lock whose owner pid is no longer alive (POSIX) is broken.
Otherwise the caller waits up to `--lock-timeout-sec` (the existing flag:
default 10 s, at most 300) and then fails with `backend-error` (5) and a
"busy" message. A consumer that issues calls on one VM concurrently should
expect this and retry; the ah-vm binding serializes calls per VM. `list_vms` takes no
lock; it reads the atomically-replaced records.

**The file-backed mock, and the fixture for consumers.** The `mock` backend
(`--backend mock`) is the deterministic `MockBackend` (§9). When a
crud-store call drives it, its whole fleet (templates, instances, in-memory
guest filesystems, snapshots) is loaded from and saved to
`<store>/mock/.fleet.json`, under a backend-wide lock. So a multi-invocation
lifecycle behaves like a real hypervisor with no hypervisor present. `mock`
is **never registered** in the backend registry. It is not advertised by
`backends`-style listings, serve `/v1/info` or the capability manifest, and
it is never auto-selected. It exists only when a caller names it.

This is the **fixture mode for hermetic consumers** (the ah-vm
`GostiOrchestrator` tests). Point the binding at the real `vm-harness` binary
with `--backend mock --state-dir <tmp>`:

```sh
vm-harness crud create_vm vm1 --backend mock --state-dir "$T"   # → running
vm-harness crud exec vm1 --backend mock --state-dir "$T" -- echo hi
#   → {"ok":true,"verb":"exec","data":{"exit_code":0,"stdout":"mock-exec: echo hi\n",…}}
vm-harness crud delete_vm vm1 --backend mock --state-dir "$T"
```

Deterministic data: `ssh_endpoint` is `{"host":"10.0.2.15","port":22,
"user":"mock","auth":"keyfile"}`. `exec` returns exit 0 with stdout
`mock-exec: [K=V …] <argv>\n` and `elapsed_ms` 5. A snapshot id is
`mock-vm-<baseline>@<snapshot>`. Failures can be injected so a consumer can
test its error mapping:

- `VMH_MOCK_UNAVAILABLE=1` makes the backend unavailable (`backend-unavailable`, exit 4).
- `VMH_MOCK_FAIL=<op>[,<op>…]` makes the named backend operations raise
  (`backend-error`, exit 5). `<op>` is one of `provision`, `revert`, `start`,
  `exec`, `copy`, `snapshot`, `restore`.

`scripts/vm-harness-fixture.sh` wraps the binary with a per-test state dir.

**Gates.** `tests/e2e/t_crud_store_roundtrip.nim` drives every verb as a
**separate CLI process** against the file-backed mock. It also covers
reconciliation (a record whose instance vanished reports `error`, then
`delete_vm` clears it), name validation, fault injection, and lock-busy
behavior. `tests/e2e/t_crud_serve_parity.nim` adds a multi-invocation case:
a VM created by a local call is visible over serve `/v1/exec`, and the
reverse, with byte-identical envelopes.

## 9. Test methodology

### 9.1 Mock policy: almost nothing

**Default position: test against real backends.** vm-harness exists to coordinate real VMs; testing it against mocked VMs would just verify that the mocks are wired up correctly, not that the backends work.

What's allowed to be mocked:

- *Pure-logic helpers* that take a string and return a struct (e.g., parsing `virsh list --all` output into a domain list). Unit tests here are fine; record real output once, replay it.
- *Time*, in performance-budget regression tests, through deterministic-clock injection.

What is NOT allowed to be mocked:

- The VM backends themselves. `HyperVBackend::start` must actually start a Hyper-V VM. `TartBackend::clone` must actually run `tart clone`. No `MockBackend` substituted for `TartBackend` in any test that purports to verify Tart behavior.
- Process spawning. No mocking `osproc.startProcess`/`std::process::Command`. If a test wants to verify what arguments are passed to `tart`, it can use a shell shim (a real binary on PATH that records its argv and exits) — but that's still a real `osproc` call.
- File I/O. The output envelope is verified by *reading the actual files vm-harness wrote*, not by mocking the writer.
- SSH/PSDirect transports. Tests run actual `ssh` against actual `sshd` in the guest, or actual `Invoke-Command -VMName` against actual Hyper-V.

The exceptions to "no backend mocks" are two *deliberate test fixtures*. `NoopBackend` implements the trait but does nothing; it exists for testing the dispatcher, output envelope, and lifecycle orchestration in isolation from any real backend. `MockBackend` is the deterministic, file-backed fixture behind the crud store (§8.6). Tests that use either must be named and described to make clear they're testing the harness scaffolding or the contract, not backend behavior (e.g., `tests/e2e/t_vm_harness_finally_cleanup_on_panic.nim`).

### 9.2 Test types

Tests live in three directories, and every file in them is a `t_*.nim`
program:

| Directory | What it tests |
|---|---|
| `tests/unit/` | Pure-logic helpers (parsers, argv builders, path math) and contracts driven in-process through `noop` or `mock`. |
| `tests/integration/` | One backend and one primitive, e.g. `t_tart_lifecycle.nim`, `t_libvirt_backend.nim`. |
| `tests/e2e/` | A full session or a whole CLI process: one backend from provision to cleanup (`t_vm_harness_*_smoke.nim`), the serve daemon, or the crud store across separate invocations. |

### 9.3 CI layering

Every test file is registered in `scripts/test-catalog.txt`, with a tier and a
platform (`all`, `posix` or `linux`). `scripts/test_catalog.nim` refuses an
unregistered `t_*.nim`, so a new test cannot silently drop out of every run.

1. **Universal layer** (`test` tier): host-independent tests. `just test` runs
   them, and so does `repro test` through `repro.nim`. They need no hypervisor.
2. **Host layer** (`host` tier): gates that drive a real hypervisor. `just
   test-host` runs them, and each keeps an explicit platform and prerequisite
   guard. A missing prerequisite is reported as a skip and is never counted as
   coverage.
3. **Specialized** (`specialized` tier): gates with their own prerequisites,
   run by neither entry point.

### 9.4 What an integration test looks like

`tests/integration/t_tart_lifecycle.nim` is the shape: create a real backend,
require it to be available or skip, provision a baseline, revert, exec over
real SSH, and clean up in `defer`/`finally`. Real `tart clone`, real `tart
run`, real `ssh`.

### 9.5 What an e2e test looks like

`tests/e2e/t_vm_harness_tart_macos_smoke.nim` and its siblings run one backend
through the whole session lifecycle of §3.3. The serve gates
(`t_vmharness_serve_*.nim`) start a real daemon and drive it over HTTP, and the
crud gates (§8.6) run each verb as a separate CLI process.

### 9.6 Failure-mode tests

`tests/e2e/t_vm_harness_finally_cleanup_on_panic.nim` throws mid-run and
verifies the VM is still cleaned up. Backend-specific failure modes (stale
ephemerals, hung guests, unreachable SSH) are covered in each backend's own
integration file.

## 10. Repository layout

```
gosti/
├── README.md, AGENTS.md, LICENSE, NOTICE, REUSE.toml
├── flake.nix, Justfile         # dev shell, build and test entry points
├── repro.nim, repro.lock       # the reprobuild build and test graph
├── vm_harness.nimble
├── src/
│   ├── vm_harness.nim          # main module
│   └── vm_harness/
│       ├── types.nim           # VmBackend, VmHandle, ExecResult, …
│       ├── cli.nim             # CLI entry point
│       ├── crud.nim, crud_store.nim   # §8
│       ├── backends/           # hyperv, incus, libvirt, lima, mock, noop,
│       │                       #   qemu_boot, qemu_windows_arm, tart, utm, wsl
│       ├── serve/              # the serve daemon (docs/contributors/serve.md)
│       ├── repro/              # the reprobuild adapter (§13)
│       └── …                   # output envelope, pools, serial, firmware, …
├── guest-scripts/              # posix.sh, windows.ps1 (§5)
├── guest-recipes/              # golden-image recipes
├── repro_support/              # reprobuild tool recipes
├── nix/                        # Nix-built test guests
├── golden-outputs/             # recorded cross-backend gate outputs
├── scripts/                    # test runner and catalog, installers
├── tests/{unit,integration,e2e}/
├── tools/                      # benchmarks and Hyper-V pool scripts
└── docs/
    ├── contributors/           # this document and the other contributor notes
    └── site/                   # the published user guide
```

## 11. Implementation choices

1. **In-guest script delivery**: the scripts in `guest-scripts/` are embedded
   with `staticRead` at compile time (`src/vm_harness/guest_scripts.nim`).
2. **Logging**: human-readable on stderr by default. `--log-format json` emits
   structured events, also on stderr, so stdout stays reserved for command
   output.
3. **Sync API**: the Nim library's core API is synchronous, matching the shape
   of `osproc`.

## 12. References

- [`reprobuild/tools/hyperv-m69-system/README.md`](https://github.com/metacraft-labs/reprobuild/blob/dev/tools/hyperv-m69-system/README.md) — the Hyper-V harness pattern the Hyper-V backend wraps.
- [`reprobuild/tools/wsl-m69-posix/README.md`](https://github.com/metacraft-labs/reprobuild/blob/dev/tools/wsl-m69-posix/README.md) — the WSL harness pattern the WSL backend wraps.
- [`reprobuild/tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim`](https://github.com/metacraft-labs/reprobuild/blob/dev/tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim) — the gate-file shape reprobuild's VM gates follow.
- [libvirt domain XML reference](https://libvirt.org/formatdomain.html) — for libvirt backend.
- [Cuckoo Sandbox Machinery docs](https://cuckoo.readthedocs.io/) — abstract base class reference design.
- [cirruslabs/packer-plugin-tart](https://github.com/cirruslabs/packer-plugin-tart) — Tart driving reference.
- [naveenrajm7/packer-plugin-utm](https://github.com/naveenrajm7/packer-plugin-utm) — UTM driving reference.
- [naveenrajm7/vagrant_utm](https://github.com/naveenrajm7/vagrant_utm) — utmctl invocation patterns.

## 13. Reprobuild adapter

vm-harness is usable on its own — as the CLI of §6 and the Nim library of §7.
It is *also* a source of build-graph edges: reprobuild drives guest lifecycle
through typed wrappers, and every edge those wrappers create has to declare how
reproducible it is, because that declaration is what decides whether a cached
result may be reused, for how long, and on which machine.

**The typed model is reprobuild's edge-determinism model; reprobuild defines
it normatively, not this document.** This section only records vm-harness's
defaults against it. The four things worth restating before the table:

  * **Four determinism classes.** `strong` — same declared inputs give
    bytewise-identical outputs on every machine. `weak` — outputs that are
    identical after a documented mechanical normalizer is applied to both
    sides. `host-bound` — stable per host across runs, but different hosts
    produce different outputs that no normalizer bounds. `volatile` — two runs
    on the *same* host may differ, because the action consumes implicit state
    (wall clock, network, randomness, live guest state) that the declared
    inputs do not capture.
  * **Retention vocabulary.** A `volatile` edge MUST carry a
    `cacheRetention` clause; one without it is an error. The vocabulary is
    `max-age = N`, `no-cache`, `no-store`, `this-build`, and
    `stale-while-revalidate = N`. Non-volatile classes carry no clause — the model
    calls that "cache forever", and for `host-bound`, "cache forever, per
    host".
  * **Composition.** A composite edge inherits the **strictest** class
    on its path, under `strong < weak < host-bound < volatile`. Everything
    below is each edge's *own* declaration; an edge whose upstream is stricter
    is lifted to the upstream's class. A cold snapshot of a container the same
    graph just launched is `host-bound` by declaration and `volatile` in the
    graph.
  * **Cross-machine substitution.** `host-bound` and `volatile` entries
    are never substituted across machines. Reusing another machine's baseline
    or snapshot is an explicit, per-target, logged functional-reproducibility
    opt-in — never the default.

### 13.1 Default class and retention

The six resource types are declared in `src/vm_harness/repro/resources.nim`;
the two running-state operations are `LibvirtBackend.snapshotRunning` and
`LibvirtBackend.restoreSnapshot` in `src/vm_harness/backends/libvirt.nim`. The
cold libvirt snapshot is listed alongside the warm one because the contrast
between them is the whole point of the classification.

| Edge | Class | Retention |
|---|---|---|
| `vm_harness.container` — launch a container | `volatile` | `this-build` |
| `vm_harness.nic` — attach a container to a managed network | `volatile` | `this-build` |
| `vm_harness.exec` — run an argv in a guest | `volatile` | `no-cache` |
| `vm_harness.check` — run an argv and assert exit code / stdout | `volatile` | `no-cache` |
| `vm_harness.network` — managed network | `host-bound` | — (cache forever, per host) |
| `vm_harness.snapshot` — cold container snapshot, optional image publish | `host-bound` | — (cache forever, per host) |
| libvirt `snapshot` — cold, `--disk-only`; restore *boots* | `host-bound` | — (cache forever, per host) |
| libvirt `snapshotRunning` — warm; RAM + CPU + device state; restore *resumes* | `volatile` | `max-age = 86400` |
| libvirt `restoreSnapshot` — revert to a running domain | `volatile` | `this-build` |

**Why those retentions.** A launched container and the NIC attaching it are
state-transaction outputs, not artifacts; `this-build` keeps one realization
stable for the rest of the invocation, so ten downstream edges share one
container, while never handing a *later* invocation a guest that an earlier
build already mutated. The NIC takes its container's clause because it lives
and dies with the container — a NIC entry outliving its container would name a
device on something that no longer exists. `exec` and `check` are `no-cache`:
re-run on every operator invocation, but only once per invocation so downstream
stays stable during the build. That is not an aspiration bolted on top of the
drivers, it is what they already do — neither has a durable observable, so both
report "absent" from `observe` and are always-needs-apply. `network` and the
cold snapshots carry no clause at all: each is reusable *on the realizing host*
by name, so a re-reconcile of the same graph on the same host is a hit.

**Why a running-state snapshot is `volatile` and a cold one is not.** It is
tempting to file both next to each other as `host-bound` — both are "a saved
state on this host" — but they fail different tests. Apply the model's volatility test: pause
the wall clock and the network, and take the same snapshot twice on the same
host. A cold `--disk-only` snapshot freezes disk state, and two runs against
the same declared inputs agree; that is `host-bound`. `snapshotRunning`
captures RAM, CPU, and device state of a *live* guest — one whose page cache,
event log, entropy pool, and service timers keep moving while the capture
streams. Two captures of one domain are two different guests. That is
`volatile`, and being `volatile` it must carry a retention clause.

Two further consequences follow from the RAM image, and both are recorded in
the method's own docstring rather than inferred here. First, the capture
asserts that the domain is running: a snapshot taken while it is not carries no
RAM, would look like a success, and would then *boot* on restore — the exact
cost the primitive exists to remove. Second, **a warm state carries the guest's
machine name and DHCP lease with it**. That makes it identity-bearing, which is
strictly stronger than what the class alone forbids: the model already refuses to
substitute the entry onto another machine, but a warm state must also not be
restored into two domains on the *same* machine, because both would come up
with one hostname and one lease. A warm pool is therefore N distinct warm
states, never N readers of one — and the capture refuses up front when two
defined domains share a writable disk, so the problem surfaces as a refusal
instead of as a name collision on the network some days later.

`max-age = 86400` is one working day: capture streams the guest's entire RAM,
so it is far too expensive to repeat per build, but the frozen guest's clock,
leases, and cached credentials all age against wall-clock time, and past about
a day a fresh capture costs less than reasoning about a stale one.
`restoreSnapshot` is `this-build` because a revert does not rewrite the saved
state — the frozen disk and the memory image are *inputs*, and a fresh scratch
overlay is created above them, so the snapshot stays reusable. It is the
restored, running domain that is volatile, and it must not outlive the
invocation that produced it.

### 13.2 The CLI subcommands

The table is the reference; the paragraphs after it are the reasoning.

| Subcommand | Class | Retention |
|---|---|---|
| `provision` | `host-bound` | — (cache forever, per host) |
| `install` | `volatile` | `max-age = 604800` |
| `boot` | `volatile` | `no-cache` |
| `run` | `volatile` | `no-cache` |
| `instance exec` / `copy-to` / `copy-from` / `start` / `stop` | `volatile` | `no-cache` |
| `instance wait` | `volatile` | `no-cache` |
| `snapshot create` | `host-bound` | — (cache forever, per host) |
| `snapshot create --running` | `volatile` | `max-age = 86400` |
| `snapshot restore` | `volatile` | `this-build` |
| `baseline export` / `baseline import` | `host-bound` | — (cache forever, per host) |
| `ephemeral-destroy` | `volatile` | `no-store` |
| `probe`, `backends`, `shell`, `prune`, `layer` | *(not a graph edge — no class)* | — |

The subcommands dispatched in `src/vm_harness/cli.nim` map onto the same
classes. `provision` is `host-bound`: it realizes a baseline on this host and
is idempotent there, but its bytes are the host's. `install` is `volatile` with
`max-age = 604800` — an installer stamps run-unique identity (machine
identifiers, host keys) into the target disk, so two runs differ, and one week
is the point at which the guest OS's own patch cadence makes a fresh install
more honest than a cached one. `boot` is `volatile`, `no-cache`: a
serial-console assertion over a transient VM is a probe, the same posture as
`vm_harness.check`. `run` (revert, exec, harvest, clean up) and the mutating
`instance` verbs (`exec`, `copy-to`, `copy-from`, `start`, `stop`) are
`volatile`, `no-cache` — the `vm_harness.exec` posture; `instance wait` is a
readiness barrier with no output of its own. `snapshot create` is `host-bound`
cold and `volatile` with `max-age = 86400` under `--running`; `snapshot
restore` is `volatile`, `this-build`. `baseline export` and `baseline import`
are `host-bound`: the bundle is a host-bound baseline plus its snapshot tree,
and carrying one to another machine is exactly the model's logged cross-machine opt-in.
`ephemeral-destroy` is `volatile` with `no-store` — a reclaim has no artifact
worth caching, and a cached "already destroyed" would become a lie the moment
anything re-created the instance.

Five subcommands are **not graph edges and therefore carry no class at all**:
`probe` (capability detection — a pure query over the host), `backends` (a
listing), `shell` (an interactive operator session), `prune` (an operator
reclaim tool scoped by an ephemeral-instance prefix) and `layer` (the layer
in-use guard and stale-overlay sweep, §6). A determinism class describes an
edge's output in the cache, and none of these produce one, so labelling them
would be a category error rather than a conservative default.
`ephemeral-destroy` is the one that looks similar but is not: it is the destroy
action of a resource whose lifecycle the graph owns, so it belongs to an edge;
`prune` and `layer` deliberately sweep outside any graph.

### 13.3 Where the typed wrappers live

The wrappers are **reprobuild's, not vm-harness's**. A graph author writes
`package vm_harness:` from reprobuild's stdlib; vm-harness remains the
underlying CLI and library that those wrappers drive. This keeps the ownership
split intact — vm-harness ships generic lifecycle primitives, and gate
orchestration lives in the consumer above it.

The in-repo adapter that declares the resource types,
`src/vm_harness/repro/resources.nim`, is deliberately **outside vm-harness's
core build path**. It imports reprobuild libraries, and it is imported by
neither `src/vm_harness/cli.nim` nor anything `just build` compiles, so the
core build stays reprobuild-free and vm-harness acquires no dependency on its
own consumer. It is compiled only with reprobuild's `--path` set; the same
module built with `-d:reproProviderMode` serves the driver operations over
reprobuild's provider protocol from a separate process, so the engine can
reconcile a container without linking a backend into itself.
