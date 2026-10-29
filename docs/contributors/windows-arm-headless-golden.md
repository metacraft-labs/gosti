# Headless Windows ARM64 golden build

## Overview

`qemu-windows-arm` consumes a Windows ARM64 golden — a directory containing
`windows.qcow2` and `golden-manifest.json` — and can also *produce* one:
`buildWindowsArmGolden` (in
[`qemu_windows_arm.nim`](../../src/gosti/backends/qemu_windows_arm.nim))
drives the Windows ARM64 unattended install through QEMU with no GUI and no
UTM, so a golden is reproducible from the ISO plus the checked-in answer files
under [`guest-recipes/windows-arm-base/`](../../guest-recipes/windows-arm-base/).
The build runs unattended on a macOS ARM host with no `utmctl` and no console
session, so CI and a remote operator over SSH can both run it.

This page describes how that build works, how a finished golden is consumed
per job, and what the host runs found along the way.

`buildWindowsArmGolden` is a library entry point. It is driven by the gates
below; there is no `gosti` CLI verb for it, and nothing in this
repository promotes a built golden (see "Promotion is not implemented here,
and that is on purpose").

## What is implemented

| Component | Where | Notes |
|---|---|---|
| Admit an existing golden | `requireWindowsArmGolden` | Requires `windows.qcow2` **and** `golden-manifest.json`; see "Two traps the runs left behind". |
| Headless install boot — argument vector | `buildQemuWindowsArmInstallArgs` | |
| Headless install boot — orchestration | `buildWindowsArmGolden` | UEFI staged by `stageGoldenFirmware`. |
| Install-completion detection | `waitForInstallSentinelWatched` | Polls the `repro-install-done` sentinel, with the freeze watchdog around it. |
| Frozen-guest recovery | `GuestProgressWatch` | A power cycle of QEMU **and** swtpm. See "Closed: the guest freeze on a firmware boot". |
| Per-job instance from a generalized golden | `buildQemuWindowsArmArgs` + `revertToBaseline` | Starts with `-action reboot=reset` plus a QMP socket; `revertToBaseline` restores one-shot semantics with `set-action reboot=shutdown` once SSH is first reached. See "Closed: the per-job boot could not boot a generalized golden". |
| A dead per-job guest is reported as one | `waitForFirstBootSshReady` | Takes the QEMU pid; see "The run path knows when there is no guest". |
| Rebuild safety guard (never build in place) | `prepareGoldenBuildDir` | |
| Overlay backing-path symlink resolution | instance creation | Overlays record the resolved versioned path. |
| Golden disk allocation | `createGoldenDisk` | |
| Free-space precondition | `checkGoldenBuildSpace` | Floor refuses, comfort band warns. |
| Sysprep + generalize | `runGuestSysprep` + `waitForGuestPowerOff` | Power-off observed on the monitor socket. |
| Golden finalize | `finalizeGoldenDir` | Drops build leftovers, refuses a golden whose per-job boot would still reference the install media, then `validateWindowsArmVmDir`. |
| Build manifest | `writeGoldenManifest` | ISO SHA-256, recipe commit + dirty flag, answer-file digests, timestamp, gosti version. |

A golden built this way on m3 on 2026-09-15
(`win-arm-runner-20260915T154742Z`) took 35.1 min wall clock, is 13.81 GiB,
and passes `requireWindowsArmGolden`. Booted per job, it reached SSH in
47–67 s with distinct machine SIDs on independent overlays.

## How the install boot differs from the per-job boot

The per-job run path is fully headless. `qwaMachineArgs` launches with
`-accel hvf`, `-display none`, UEFI pflash firmware, an `swtpm` TPM 2.0
device, `-serial file:`, a monitor socket, and user-mode networking with
`hostfwd` for SSH. The golden build reuses that machine shape with these
changes:

1. a freshly created empty `windows.qcow2` instead of a CoW overlay;
2. the Windows ISO and the autounattend ISO attached as CD-ROMs — on
   *different* controllers, for measured reasons: see "Where the install
   media lives, and why";
3. the guest stays rebootable throughout, because a Windows install reboots
   several times;
4. a `usb-kbd` plus a bounded keypress injected on the monitor, because the
   install media's boot loader waits for a key (see "Implementation notes").

The recipe inputs are checked in and independent of UTM: `autounattend.xml`,
`repro-sysprep.xml`, `provision-openssh.ps1`, and the
`build-autounattend-iso.sh` that packages them together with the staged
OpenSSH and VirtIO NetKVM payloads.

The Linux libvirt backend performs the equivalent install headlessly through
`virt-install` (see [`libvirt.md`](libvirt.md)). This build is that same
shape for the macOS/ARM host, minus libvirt, which does not exist on Darwin.

What the build does **not** do: build the Windows ISO itself (it stays an
operator-supplied input, pinned by hash in the manifest, because Microsoft's
download is manual and unversioned), or produce bit-identical output (a
Windows install is not deterministic; the procedure is reproducible, not the
hash).

## Golden lifecycle: a read-only base under live overlays

The golden is not a template that gets copied. In the default disk mode
(`overlay`, see `qwaDiskMode`) `createEphemeralOverlay` creates a thin
`overlay.qcow2` whose **qcow2 backing file is the golden's
`windows.qcow2`**. The golden is never copied; it is shared read-only by
every concurrent instance, and only the overlay records guest writes. Clone
mode — a full per-instance copy — is a fallback behind
`GOSTI_QEMU_WINDOWS_ARM_DISK_MODE=clone`.

That makes one thing a hard constraint:

> **A golden must never be rebuilt in place.** qcow2 does not validate that a
> backing file still holds the content an overlay was created against. Writing
> a new `windows.qcow2` at a path some overlay still references does not fail
> — the guest silently reads a different disk underneath its own writes.
> Every live instance, and every orphaned instance directory, is exposed.

So a rebuild is an *addition*, not a replacement. The build writes into a
**new versioned directory**, `golden/win-arm-runner-<build-id>/`, which is
inert until anything points at it, and `prepareGoldenBuildDir` refuses to
write into an existing golden directory at all. Selecting which build
subsequent instances get is a pointer (`golden/win-arm-runner`, a symlink),
and it must not disturb existing overlays. The per-instance advisory lock
(`qwaInstanceLockPath`, which `prune` uses to distinguish a live instance from
an orphan) is the signal for when an older golden no longer backs anything.

**Overlays must record the resolved versioned path, not the symlink.**
`validateWindowsArmVmDir` returns `absolutePath(dir)`, which does not resolve
symlinks, so an overlay created through the pointer would record the pointer —
and flipping it would corrupt exactly the instances this scheme exists to
protect. Instance creation resolves the symlink before handing a backing path
to `qemu-img create`.

## The build sequence

1. `qemu-img create -f qcow2 <golden-dir>/windows.qcow2 <size>`, where
   `<golden-dir>` is a fresh versioned directory — never an existing golden.
2. Stage a UEFI code/vars pair into it (`stageGoldenFirmware`).
3. Start `swtpm`, then QEMU with the install argument vector: both ISOs
   attached, `bootindex` ordering the install ISO ahead of the NVMe disk, the
   keyboard attached and the key prompt answered.
4. Wait for install completion: the `C:\Windows\Temp\repro-install-done`
   sentinel that `autounattend.xml` writes from its last `FirstLogonCommand`,
   once `sshd` is confirmed running, with the freeze watchdog around the wait.
5. Invoke
   `sysprep /generalize /oobe /shutdown /mode:vm /unattend:C:\repro-sysprep.xml`
   over SSH, detached from the session (`buildSysprepRemoteCommand`).
6. Wait for the guest to power off, observed on the monitor socket rather
   than SSH, since SSH dies with the guest.
7. Kill `swtpm`, drop the CD-ROM drives, and finalize: `finalizeGoldenDir`,
   then `writeGoldenManifest` last, so the manifest is a completion marker.

The overall deadline defaults to 90 minutes. The answer file does all the
real Windows-side work.

Sysprep `/generalize` is load-bearing and must not be skipped: without it
every ephemeral clone shares one machine SID.

## Verification

| Gate | Layer | Runs where |
|---|---|---|
| Argument-vector unit test: install boot attaches both ISOs, on the controllers each has to be on, orders bootindex, and omits `-no-reboot` | unit | anywhere |
| `qemu-img`/`swtpm` invocation shape | unit | anywhere |
| Golden shape accepted by `validateWindowsArmVmDir` | unit | anywhere |
| A frozen guest is power-cycled — QEMU **and** swtpm — and the install finishes; the allowance runs out and the build fails | unit | anywhere |
| Per-job argv allows the first boot's reboot **and** carries the QMP socket that revokes it; the install argv carries neither | unit | anywhere |
| Firmware boots counted off the serial console; a reboot loop is named rather than waited out | unit | anywhere |
| `revertToBaseline` survives a guest that reboots before sshd exists, and refuses the instance when `set-action` cannot be applied | unit (fake QEMU that performs the reboot and obeys the argv) | anywhere |
| Full install → sysprep → golden | host e2e, opt-in | macOS ARM host with the ISO |
| Two clones of the golden have distinct machine SIDs | host e2e, opt-in | macOS ARM host with a golden |
| **The per-job path boots a real golden, reaches SSH and runs a command** (`t_qemu_windows_arm_per_job_boot`) | host e2e | macOS ARM host with a golden; ~2 min |
| A per-job boot whose QEMU exits is reported as a dead **process**, with its exit status, in seconds rather than at the SSH deadline (`t_qemu_windows_arm_dead_guest_is_named`) | unit (fake QEMU with a death clock) | anywhere |
| **The same, on the real reproducer**: the old `-no-reboot` vector against a real golden fails in ~34 s of a 300 s deadline (`t_qemu_windows_arm_dead_guest_is_named`, host) | host e2e | macOS ARM host with a golden; ~2 min |

The unit layer must not claim coverage of the e2e layer. Following this
repo's existing convention, a missing ISO or a non-macOS host **skips with an
explicit message** rather than passing quietly.

### Implementation notes

Both tiers carry the same greppable gate name, `t_qemu_windows_arm_golden_build`:

| Tier | File | Wired into |
|---|---|---|
| unit (runs anywhere) | `tests/unit/t_qemu_windows_arm_golden_build.nim` | `scripts/run-tests.sh`, `repro.nim` |
| host (opt-in) | `tests/e2e/t_qemu_windows_arm_golden_build_host.nim` | `scripts/run-host-tests.sh` |

The *consuming* side has its own gate, `t_qemu_windows_arm_per_job_boot`, in
`tests/e2e/t_qemu_windows_arm_per_job_boot_host.nim` (also wired into
`scripts/run-host-tests.sh`). It boots an existing golden through
`provisionBaseline` → `revertToBaseline` → `execInGuest` → `stopAndCleanup`,
costs ~2 minutes rather than an hour, and needs no opt-in flag — only a
finished golden, whose absence it names. See "Closed: the per-job boot could
not boot a generalized golden" for why it exists.

The unit tier drives the *whole* orchestration — install wait, sysprep,
power-off, finalize, manifest — against a fake QEMU that binds the real
forwarded SSH port and serves a real unix monitor socket, so the port-claim
handshake and the monitor conversation under test are genuine and only the
guest is absent. It deliberately does not claim the host tier's coverage: no
unit test can say that Windows Setup accepted the answer file, that HVF
tolerated the reboot sequence, or that `/generalize` re-minted the SID.

The host tier requires `GOSTI_WINDOWS_ARM_GOLDEN_HOST_TEST=1`,
`GOSTI_WINDOWS_ARM_ISO` and `GOSTI_WINDOWS_ARM_AUTOUNATTEND_ISO`, and names each
missing one in the skip message.

Points worth knowing before changing the build, each deliberate:

- **The build watches the monitor socket, not QMP.** `qwaMachineArgs`
  publishes `-monitor unix:…` (the human monitor), and the install argv
  carries no `-qmp`. Power-off is therefore read from an `info status` reply
  rather than a QMP event. The property that matters — *observed off-band
  from SSH, because SSH dies with the guest* — is the same either way. The fallback arm
  is also part of the contract: QEMU's default action on a guest power-off is
  to **exit**, so a vanished socket plus a gone process is the same event seen
  from outside, and `guestPoweredOff` treats it as such.
- **Sysprep is launched so as to outlive the SSH session, and carries
  `/mode:vm`.** `/shutdown` powers the guest off underneath the SSH session
  that issued it, and a generalize runs 10–20 minutes, so a session-bound
  invocation is one hangup away from a half-generalized disk that still looks
  like a golden. `buildSysprepRemoteCommand` creates it through
  `Win32_Process.Create` and lets go — *not* `Start-Process`, which does not
  escape Windows OpenSSH's per-session job object; see "What the first real
  host run found", item 3.
  `/mode:vm` matches the invocation the recipe README documents as the one
  that produced a working golden; it is sound here precisely because every
  instance boots the identical machine shape this backend builds.
- **UEFI firmware is staged, not assumed.** A fresh golden directory has no
  firmware, and `qemuFirmwareArgs` resolves it from the VM directory, so
  `stageGoldenFirmware` copies a code/vars pair in — giving the build its own
  writable variable store, since Windows Setup writes its boot entry there.
  `GOSTI_QEMU_FIRMWARE_DIR` *replaces* the well-known search list rather than
  being prepended to it.
- **The install wait does not reuse `waitForSshReady`.** OpenSSH comes up *partway
  through* the `FirstLogonCommands` chain, so a guest that answers SSH may
  still be installing Git, PowerShell 7 and the NetKVM driver. Waiting on SSH
  would therefore declare an unfinished install finished, and sysprep would
  generalize a half-provisioned disk. `waitForInstallSentinel` waits for the
  sentinel the *last* FirstLogonCommand writes, and only once `sshd` is
  confirmed running — the one signal that means "finished".
- **The install boot needs a keyboard, and a keypress.** Found by the
  first real host run on m3, 2026-09-15. `\EFI\BOOT\BOOTAA64.EFI` on a Windows install
  ISO is `cdboot.efi`, which prints *"Press any key to boot from CD or
  DVD"*, waits about five seconds and returns `EFI_TIMEOUT` if no key
  arrives. The machine shape here has **no input device at all** —
  `-display none`, and `-serial file:` is output-only — so the prompt could
  never be answered. Measured symptom, with nothing else wrong anywhere:

  ```
  BdsDxe: starting Boot0001 "UEFI QEMU QEMU USB HARDDRIVE 1-…"
  Error: Image at 0023C314000 start failed: Time out
  BdsDxe: failed to start Boot0001 …: Time out
  BdsDxe: loading Boot0004 "EFI Internal Shell"
  Shell>
  ```

  Windows Setup never ran; the build then sat out its whole deadline and
  blamed the answer file. `buildQemuWindowsArmInstallArgs` now attaches a
  `usb-kbd` to the xHCI controller it already creates, and
  `answerInstallMediaKeyPrompt` injects `sendkey ret` on the **monitor
  socket** — the same socket power-off is read from.

  Stopping is as load-bearing as starting. That same prompt timing out is
  what makes Setup's *own* reboots fall past the still-first install media
  and onto the disk it is installing to (measured: the media is still ahead
  of the disk in `BootOrder` after Setup's first reboot). A keyer that never
  stopped would trade "the install never starts" for "Setup restarts from
  the ISO forever". So the window ends at the first of: the target qcow2
  growing past `QwaInstallProgressBytes` (Setup is writing, so the prompt is
  answered), `GoldenBuildSpec.keyPressWindowSec` (180 s by default; the
  prompt appears 20–25 s in), and the overall build deadline.

  The per-job argument vector is deliberately untouched — it is already
  deployed on m3, it boots an installed disk with no prompt to answer, and
  the unit gate asserts it gains neither the keyboard nor the xHCI.

- **The install wait has a freeze watchdog.** The plain
  `waitForInstallSentinel` cannot tell a long Windows Setup phase from a
  guest that has stopped executing, and on m3 it spent the whole 90-minute
  deadline twice on installs that were already dead in the firmware.
  `waitForInstallSentinelWatched` keeps the same "only the sentinel is
  success" contract and adds one recovery: when the serial console **and**
  the target qcow2 have both been byte-for-byte unchanged for
  `GoldenBuildSpec.freezeSec`, power-cycle QEMU and swtpm and start the
  stall clock again, up to `maxPowerCycles` times. See "Closed: the guest
  freeze on a firmware boot" for why a power cycle and not a
  `system_reset`, and why swtpm has to come back with it.

- **The harness does not copy `repro-sysprep.xml` to `C:\`.** `autounattend.xml`
  already does it from the answer-file ISO (`FirstLogonCommands`, Order 6),
  so the harness copying it again would be a second source of truth for a
  path that must match `/unattend:`. The gate asserts instead that the two
  sides agree: the constant the harness names is the destination the recipe
  copies to.

### Promotion is not implemented here, and that is on purpose

`buildWindowsArmGolden` returns the path of a **validated, inert, versioned
directory**. It never writes `golden/win-arm-runner`, and there is no
"promote" verb in this repository.

Promotion is a pointer flip plus a retention decision about the previous
golden, and both are configuration of the host that consumes the golden, not
something the build does. The build directory is `GoldenBuildSpec.buildDir`
(the host gate reads it from `GOSTI_WINDOWS_ARM_GOLDEN_OUT`), so whatever
provisions the host can point it at
`/private/var/lib/gosti/qemu-windows-arm/golden/win-arm-runner-<build-id>`
and own the symlink declaratively. Nothing in the build path requires an
operator to copy, rename or `install -d` anything.

The one step that cannot be declared away is the **ISO**: it stays an
operator-supplied input, pinned by hash in the manifest, because Microsoft's
download is manual and unversioned.

## What the first real host run found (m3, 2026-09-15)

Three defects, none of which any unit tier could have caught, and one missing
diagnostic. Recorded here because every one of them reads
from the outside exactly like "the answer file is wrong", and each cost a
deadline to diagnose the first time. They surfaced strictly in sequence —
each one had to be fixed before the next became visible — which is the honest
shape of a first host run and worth expecting on the next platform.

1. **`cdboot.efi` waits for a keypress, and the machine had no keyboard.**
   Covered in full under "Implementation notes". Symptom:
   `failed to start Boot0001 …: Time out` and an EFI shell prompt, with
   Windows Setup never running at all.

2. **The OpenSSH firewall rule is `Private`-profile only.** With the
   keypress fixed, the install ran to completion: Windows installed, NetKVM
   came up on 10.0.2.15, `Add-WindowsCapability OpenSSH.Server` succeeded,
   Git and PowerShell 7 provisioned, and `C:\Windows\Temp\repro-install-done`
   — the sentinel this harness polls for — was written. The harness still
   could not reach the guest, and waited out its deadline against a finished
   install.

   The cause: the capability's own inbound rule (`OpenSSH-Server-In-TCP`) is
   scoped to the **Private** profile. QEMU's user-mode network is
   unidentified, so Windows classifies it **Public**, whose policy is
   `BlockInbound`. `sshd` was Running, `netstat` showed `0.0.0.0:22
   LISTENING`, and every SYN forwarded by `hostfwd` was dropped inside the
   guest. `provision-openssh.ps1` only created a rule *when none existed*, so
   on exactly this path it was a no-op. It now widens whatever rule is there
   to `Profile Any`, owns a rule of its own (`gosti-sshd-in-tcp22`), and
   **asserts** the result — an unreachable sshd must fail the provisioning
   step loudly rather than produce a golden nothing can log into.

3. **`Start-Process` does not detach sysprep from the SSH session.** With
   the firewall fixed, the install ran through, the harness logged in and
   launched `sysprep /generalize /oobe /shutdown /mode:vm`, and sysprep wrote
   four lines to `C:\Windows\System32\Sysprep\Panther\setupact.log` —
   `Sysprep mode [vm]`, then *"Beginning action execution from
   Cleanup.xml"* — and **died one second later**, generalizing nothing. The
   build then waited 20 minutes for a power-off from a process that no longer
   existed, with a perfectly installed guest sitting at its desktop.

   Windows OpenSSH puts every process of a session into a **job object** and
   terminates that job when the session ends. A `Start-Process` child stays
   inside the job, so "launched detached" was never true. Measured directly
   on the same guest, with a harmless long-running process instead of a
   20-minute generalize:

   | launch | survivors 2 s after the session closed |
   |---|---|
   | `Start-Process` | **0** |
   | `Invoke-CimMethod Win32_Process Create` | 1, still running 25 s later |

   `Win32_Process.Create` works because the WMI provider host creates the
   process, so it is in no session job at all. `buildSysprepRemoteCommand`
   now uses it and exits non-zero on a refused creation.

   The second half of the fix matters as much: a launch reporting success and
   a sysprep actually running are different facts, and only the first was
   ever checked. `sysprepTookHold` now confirms sysprep is still there
   (`QwaSysprepTakeHoldSec`, default 180 s) or that the guest has already
   powered off, so this failure costs ten seconds and names itself instead of
   consuming the whole deadline in silence.

4. **The framebuffer was not actually captured.** Earlier notes
   claimed it was. It could not have been: `-display none` renders nowhere,
   and nothing dumped it. A Windows guest writes nothing to the serial port
   once the firmware hands over, so on both failures above the serial log
   simply stopped and said nothing more. `captureGuestScreen` now dumps it
   through the monitor's `screendump` on every failure, into
   `<golden-dir>/screen.ppm`, and the failure message names it as the thing
   to read first. It is what turned the second diagnosis from a blind
   90-minute wait into a ten-second look at a desktop.

### Closed: the guest freeze on a firmware boot, and what it actually was

This blocked the first host builds. Two of five runs stopped dead on a firmware boot
after Windows Setup's first reboot, on inputs identical to the runs that
sailed past it; serial log still for 23 minutes, target qcow2 for 30, and
the build sat out its 90-minute deadline. **It reproduced a third time**, on
2026-09-15's successful run, on the boot after Setup's *second* reboot — so
it is not attached to any particular boot.

**The earlier reading was wrong, and it sent both of its suggested fixes in
the wrong direction.** It said: a polling loop in a DXE driver with no
timeout, "most likely the USB/xHCI stack re-enumerating the two CD-ROMs",
evidenced by the PC parked at `0x23fd5de04` and cycling in an eight-byte
window. Two measurements retire that:

- `0x23fd5de04` is where this firmware waits for **anything**. The same
  address was sampled on a guest sitting harmlessly at the `Shell>` prompt
  of the EFI internal shell. It is the DXE core's event-wait loop, so
  "the PC is parked there" says the firmware is blocked, not what on.
- The freeze survived taking the answer-file CD-ROM off the xHCI entirely.
  One USB mass-storage device instead of two, one `UsbBootExecCmd` line per
  boot instead of two — and the guest still froze.

**What it is, from the framebuffer.** `captureGuestScreen` — added for
exactly this — shows the TianoCore splash with the caption
**`Start boot option`** and a progress bar at **0%**. That caption belongs to
`PlatformBootManagerWaitCallback`, and `BdsDxe`'s `BdsWait` calls it once per
loop iteration off a **one-second DXE timer event**. One call and no more
means the timer never fired again: the firmware is blocked in
`gBS->WaitForEvent` on a timer that has stopped.

**How far that evidence actually reaches.** What is *measured* is that the
firmware is blocked in a timer wait that never completes again, and that only
a power cycle clears it. The step from there to "the guest's virtual timer
interrupt stops being delivered, below the firmware, in QEMU/HVF" is the best
available *inference*, not a measurement: no QEMU-side or HVF-side
instrumentation was run, and the observed rate is only three times in six real
installs. Read this section as "the timer is dead and a power cycle revives
it", and do not read the QEMU/HVF attribution as established. Anything that
would stop timer interrupts reaching EL1 — the GIC, the vtimer, HVF's exit
handling — fits the same evidence equally well.

Three recoveries were tried on real frozen guests:

| Attempt | Result |
|---|---|
| `system_reset` on the monitor | **No.** The boot after it stalls at the same point. |
| 12 × `sendkey ret` on the monitor | **No.** Moved the PC once, changed nothing else — EDK2 polls the USB keyboard from the same dead timer, so keys are never seen. |
| Power cycle: stop QEMU **and swtpm**, start both again on the same disk | **Yes.** Verified twice — once against a copy of a frozen run's disk, once against a live frozen build, which resumed, booted Windows Boot Manager and went on to finish the install. |

So the watchdog is the only recovery available to the harness — it is a
*mitigation* for a cause that has been narrowed but not proven, and it is the
right one whatever the cause turns out to be, because nothing inside a guest
whose timer has stopped can restart it. `QwaInstallFreezeSec` (600 s of
the serial console **and** the target qcow2 both byte-for-byte unchanged) and
`QwaInstallMaxPowerCycles` (2). Both signals are needed — Windows is mute on
the serial port once the firmware hands over, and `Add-WindowsCapability
OpenSSH.Server` takes ~8 minutes with no disk growth at all — and exhausting
the allowance still **fails** the build rather than finalizing a
half-installed disk.

`swtpm` is not an afterthought in that recovery. `swtpm socket` exits when
its client disconnects, so the first hand-run power cycle on m3 brought QEMU
back against a TPM socket that no longer existed and died on
`Failed to connect to /tmp/gosti-qwa-tpm-....sock`. A Windows 11 guest will not
boot without a TPM, so the power cycle restarts both.

### Where the install media lives, and why

`buildQemuWindowsArmInstallArgs` puts the **Windows ISO on `usb-storage`** on
the xHCI and the **answer-file ISO on `ide-cd`** on an `ich9-ahci`. Both ends
of that split are measured, and the first one closes off the `virtio-scsi`
idea the earlier notes led with:

- The install ISO **cannot** move. The firmware has to boot
  `\EFI\BOOT\BOOTAA64.EFI` off it, and this EDK2 (`edk2-stable202408`, the
  ArmVirtQemu build QEMU ships) has **no ATA/AHCI driver at all** — measured:
  with the install ISO on `ich9-ahci`, `BdsDxe` created no boot option for it
  and went straight from the empty NVMe disk to the EFI shell. And it cannot
  go on `virtio-scsi`, which the firmware *can* boot, because Windows Setup
  must read `install.wim` off it in WinPE: `sources/boot.wim` on
  `Win11_25H2_English_Arm64_v2.iso` carries `storahci.sys`, `stornvme.sys`,
  `USBSTOR.SYS` and `uaspstor.sys` and **neither `vioscsi.sys` nor
  `viostor.sys`**.
- The answer-file ISO **can** move, because nothing boots it — Windows reads
  it by drive letter in the specialize and oobeSystem passes, and
  `storahci.sys` is in `boot.wim` and `install.wim` both. Its invisibility to
  this firmware is the point: the firmware's USB mass-storage work per boot
  halves, from two `UsbBootExecCmd` lines to one.

This was originally made as a fix for the freeze, on the hypothesis the
evidence above overturned. It is kept because it is a real reduction in
per-boot firmware work, because it is what the 2026-09-15 golden was actually
built with, and because Windows Setup was verified end to end against it —
including finding `autounattend.xml` on an AHCI CD-ROM. It is **not** the fix
for the freeze.

**Measured, for the estimates this document carries.** Install peak on m3:
**16.4 GiB** of build-directory growth, not the estimated 50 GB — see the
free-space Decision below. The 2026-09-15 golden's finished directory is
**13.81 GiB** (`du -sk`, after `/generalize` trimmed). Phase timings: media
boot to first Setup write ~60 s; image applied and first reboot at ~4 min;
second reboot at ~6 min; desktop at ~16 min; NetKVM installed at ~7.5 min
after that reboot; `Add-WindowsCapability OpenSSH.Server` took **8 minutes**
on its own; sentinel written by ~16 min after boot. The successful run took
**35.1 minutes** wall clock end to end, of which ~20 were lost to one freeze
and its recovery.

### Closed: the per-job boot could not boot a generalized golden

**Found in review 2026-09-15, on the first attempt to consume the golden
through the path a CI job uses. It was not a defect in the golden, and it was
not new — `-no-reboot` was in `buildQemuWindowsArmArgs` at HEAD and in the
vector deployed on m3. It was a LATENT incompatibility, not a regression:
the fleet's Windows goldens were historically not sysprepped (their clones
shared the base SID), and a non-generalized image boots straight through with
no specialize pass and no reboot. The headless build's golden is properly
generalized — which is correct and strictly better — and
that is what exposed it.**

`buildQemuWindowsArmArgs` added `-no-reboot`, which turns a guest-initiated
reboot into a QEMU exit. That is the right shape for a one-shot job *once the
guest is up*. It was fatal on the **first** boot of every instance, because
the golden is `/generalize`d: `repro-sysprep.xml` drives a fresh specialize +
oobeSystem pass on every clone — that is the whole point of generalizing, and
the recipe's README §7 says so explicitly ("first-boot of any clone uses the
post-SysPrep `oobeSystem` pass; admin user is recreated at first boot of every
clone"). Windows reboots between those two passes. `sshd` is started by
`FirstLogonCommands`, which run *after* that reboot. So QEMU exited before
OpenSSH had ever existed, on every instance, every time.

Measured on m3 against `win-arm-runner-20260915T154742Z`, same golden, same
fresh overlay, same firmware pair, same swtpm, argv taken straight from
`buildQemuWindowsArmArgs`:

| Arm | Argv | Runtime action | Result |
|---|---|---|---|
| A | exactly as emitted (`-no-reboot`) | — | QEMU **exits rc=0 after 38 s**. `serial.log` ends at `BdsDxe: starting Boot0003 "Windows Boot Manager"`. No SSH, ever. |
| B | `-action reboot=reset`, nothing else changed | none | **SSH ready in 52 s**, two firmware banners in `serial.log`. Then `shutdown /r /t 0` in the guest: QEMU **still alive 84 s later**, third firmware banner — the one-shot guarantee genuinely gone. |
| C | same as B | `set-action reboot=shutdown` over QMP | same `shutdown /r /t 0`: QEMU **exits in 6 s**, no new firmware boot. |

Arm C is what shipped. The fix is a **lifecycle**, not a flag removal:

1. The argv starts the guest with `-action reboot=reset` — QEMU's default,
   stated explicitly so the intent is an argument you can assert on rather
   than the absence of one — plus a **QMP socket** (`qwaQmpSocketPath`).
2. `waitForFirstBootSshReady` waits for the first SSH while counting
   `UEFI firmware (version ` banners on the serial console. A healthy first
   boot shows exactly **two**. Past `QwaFirstBootMaxFirmwareBoots` (4) the
   guest is reboot-looping, and the instance fails by name in seconds rather
   than sitting out `sshReadyTimeoutSec` in silence.
3. The moment SSH answers — and **before** the handle is returned to anything
   that could run a job — `revertToBaseline` sends
   `set-action reboot=shutdown` over QMP. A refusal **fails the instance**:
   handing back a guest that can silently reboot and carry a job's state into
   a second life is exactly the property `-no-reboot` existed to prevent, and
   "we could not restore it" is not a state a CI job may run in.

So the window in which a reboot is tolerated is bounded twice — by the first
successful SSH probe and by the firmware-boot allowance — and nothing has run
in the guest while it is open, because the runner has not registered yet.

**Why it has to be QMP.** `-no-reboot` and `-action` are start-time only.
HMP — the `-monitor` socket this backend has always had — has no `set-action`;
checked against the QEMU on m3 (10.1.5), whose HMP command list carries
`watchdog_action` and nothing else of the sort, while QMP's `query-commands`
lists `set-action`. The QMP socket is on the **per-job vector only**. The
install boot never stops being rebootable, so it needs no way to revoke that
— and leaving its argv alone keeps the golden on disk reproducible from this
source.

**Measured through the real harness**, `provisionBaseline` →
`revertToBaseline` → `execInGuest` → `stopAndCleanup`, twice against the
2026-09-15 golden: SSH ready at **53 s** and **47 s**, **2 firmware boots**
each, `echo` answered verbatim, `set /a 6*7` answered `42`, machine SIDs
`S-1-5-21-4141119040-1327074746-2687477893` and
`S-1-5-21-3248826874-1080048203-430612151` — distinct, so `/generalize` took.
The golden's `windows.qcow2` was sha256-identical before and after, and
`instances/` was empty afterwards with no stray `qemu-system-aarch64` or
`swtpm socket`.

**Why no test caught it, which is the part worth keeping.** The unit tier
asserted the *argv*, and one of its tests (`the per-job boot keeps -no-reboot
and its own boot order`) asserted `-no-reboot` was present — so the gate
actively pinned the defect. Three review passes also treated "the per-job
argv is byte-identical to HEAD" as a safety property; it was, and the vector
it was protecting had never booted a generalized golden. Two things changed:

- The unit tier's fake QEMU now **performs** the mandatory reboot and takes
  QEMU's own decision on it *from the argv it was handed*, so restoring
  `-no-reboot` to production code makes the end-to-end unit tests fail. It
  can now tell a bootable vector from an unbootable one in that one modelled
  sense.
- A host gate exists that actually boots one:
  `tests/e2e/t_qemu_windows_arm_per_job_boot_host.nim`, wired into
  `scripts/run-host-tests.sh`. It consumes a golden that already exists, so
  it costs about two minutes rather than the ~60-minute install, and it
  skips loudly — naming the golden path it looked at and the environment
  variable that overrides it — when there is no golden or the host is wrong.
  It is the gate that should have caught this, and the one to run after any
  change to `buildQemuWindowsArmArgs`, `waitForFirstBootSshReady` or
  `revertToBaseline`.

### The run path knows when there is no guest

The run path used to have **no liveness check on the QEMU process at all**.
`waitForFirstBootSshReady` polled SSH and counted firmware banners and never
consulted the pid it had just been handed, so a QEMU that exited kept a port
nobody was listening on being polled until the whole `sshReadyTimeoutSec` ran
out. Measured twice on m3, both times against a real golden:

| When | What happened | What the harness said, and after how long |
|---|---|---|
| 2026-09-15 | `-no-reboot` on the per-job argv; QEMU exits rc=0 at **38 s** | `SSH did not become ready … within 300s`, at **301 s** |
| 2026-09-16 | the same reproducer, restored in review to falsify its host gate | the gate failed correctly, but took **5 m 38 s** and still *led* with SSH |
| 2026-09-16, after the fix | the same reproducer, `t_qemu_windows_arm_dead_guest_is_named` host tier | `fbQemuExited` after **34 s**, `exit status 0`, 1 firmware boot |

The asymmetry was the tell. The *install* path grew exactly this capability
(`qemuProcessGone`, consulted by `answerInstallMediaKeyPrompt` and the freeze
watchdog); the *run* path simply never called it. So `waitForFirstBootSshReady`
now takes the pid and has **three independent bounds**, none of which
substitutes for another:

- **the process is gone** — checked every poll, answers in seconds. Checked
  *after* the readiness probe, so a guest that answers and dies in the same
  instant is still reported ready: the check is "the process we started is
  gone", never "SSH is slow", and so it cannot turn a working boot into a
  failing one.
- **the firmware-boot allowance** — a guest that restarts *forever*. Not a
  substitute for the first: a process that **exits** leaves the banner count
  **frozen**, not growing, so this bound never trips on a dead QEMU.
- **the deadline** — the residual case, a live guest that simply never
  reaches sshd. The only one for which waiting it out is the right answer.

`qemuProcessGone` reaps the child (`childExitInfo`) rather than probing with
`kill(pid, 0)`, which matters here: nothing waits on the per-job QEMU until
teardown, so a QEMU that exits mid-boot sits as a **zombie** and a naive
liveness probe reports the dead guest alive. The reap also keeps the exit
status — `waitpid` may only succeed once per child, and the message needs what
it said — so the failure reads *"the guest's QEMU process (pid N) EXITED after
34s … exit status 0. This is not an SSH problem: there is no guest."*

**The diagnostics it names now exist.** The old message pointed at
`<vmDir>/serial.log`, a path `stopAndCleanup` had just deleted. A failed
per-job boot cannot keep its whole directory the way a failed *build* does —
that directory holds a qcow2 overlay, and ~3.5 create→fail→reap
cycles an hour against the broken argv — so `serial.log`, `qemu.log` and the
`screendump` are copied to `<state dir>/failed-boots/<instance>/` before the
instance is reaped, newest `QwaRetainedFailedBoots` kept. `captureGuestScreen`,
the single highest-value diagnostic, is fired on the per-job failure path
too; a guest whose QEMU has *already* gone has no framebuffer to dump, and
that is not a second failure.

Gates: `tests/unit/t_qemu_windows_arm_dead_guest_is_named.nim` (unit, shares
the golden build's fake QEMU via `tests/unit/qwa_fake_qemu.nim`) and
`tests/e2e/t_qemu_windows_arm_dead_guest_is_named_host.nim` (host, rebuilds
the old `-no-reboot` vector *from the shipped one* so the reproducer stays honest and
production code stays untouched).

**The `tart` backends do not have this check.** `revertToBaseline` records
the `tart run` child's pid in `ephemeralPids` and then calls
`waitForSshReady(ip, sshReadyTimeoutSec)`, which never looks at it, so a
`tart run` that exits is reported at the SSH deadline. The same fix does not
transfer directly: `tart run` is deliberately never reaped, so it needs its
own exit-status plumbing.

### Two traps the runs left behind, and what now stops them

Neither is a defect in the run; both are ways the *next* build could produce
an artifact that lies about itself.

- **A failed build looks exactly like a golden.** The build deliberately
  retains a failed build's directory and logs for diagnosis, and five runs on
  m3 left **six** of them under
  `/private/var/lib/gosti/qemu-windows-arm/golden/`, 12–15 GB each
  (~68 GB total). Every one holds a `windows.qcow2`, because the build
  creates that empty as its *first* act — and `validateWindowsArmVmDir`, the
  check the consuming path used, asked for nothing else. All six would have
  been accepted as a baseline to boot CI jobs from.

  The disk is not an identification. `requireWindowsArmGolden` is now the
  admission check, and it additionally requires `golden-manifest.json`, which
  the build writes *last* and which is therefore a genuine completion marker.
  `provisionBaseline`, `revertToBaseline` and `buildWindowsArmGolden`'s own
  return value all go through it. `validateWindowsArmVmDir` survives as the
  purely structural "is there a disk here" question the overlay and clone
  paths ask of a directory something else already admitted.

- **A stale answer-file ISO would have poisoned the manifest.** Found before
  the first host run: `guest-recipes/windows-arm-base/build/autounattend.iso`
  was 7.6 MiB dated 2026-07-06, while `autounattend.xml`, `repro-sysprep.xml`
  and `provision-openssh.ps1` were from 2026-09-08 — it predated the
  Git-for-Windows, PowerShell-7 and credential-expiry changes entirely.

  That gap is structural, not a one-off: the manifest digests *both* the ISO
  it consumed and the *recipe files on disk*, and nothing regenerates the ISO
  when a recipe file changes, because `build/` is a gitignored artifact built
  by hand. A build from a stale ISO installs July's recipe and records
  September's. `staleAnswerIsoRecipeFiles` now refuses such a build **before**
  it spends an hour, naming the files and the rebuild command.

  It is a staleness *heuristic* — it compares modification times and cannot
  prove that an ISO rebuilt after an edit actually carries it. Proving that
  means reading the ISO's contents, which needs ISO tooling this path does
  not otherwise want.

## Failure modes to keep in mind

- **Windows setup is opaque when it fails.** A wrong answer file leaves a
  guest sitting at an OOBE prompt with no SSH and no console. The serial log
  is captured, the `ramfb` framebuffer is dumped through the monitor on
  failure (`captureGuestScreen`), and the overall deadline bounds the
  failure.
- **Silent corruption if the versioning is got wrong.** Rebuilding over a
  golden that still backs an overlay does not error — it produces guests
  reading a disk that no longer matches their writes. This is the highest
  severity failure mode of this path and the reason the build refuses to
  write into an existing golden directory at all.
- **Long feedback loop.** A full host cycle is 30–60 minutes, so changes to
  the argument construction belong behind the unit tier before any host run.

## Goldens are rebuilt, never published

A golden is rebuilt by applying the recipe to a base ISO; the built golden is
never published or pulled. The build path is therefore the *only* path, which
is why it is re-runnable — each run writes a fresh versioned directory, and a
failed run leaves one that nothing points at — and why each golden carries a
**manifest** (ISO SHA-256, recipe commit, answer-file digests, build
timestamp, gosti version): not for reproducibility, which the recipe
provides, but so that a golden of unknown provenance is identifiable as one.
The ISO itself remains the one operator-supplied input, pinned by hash.

## The free-space precondition

`checkGoldenBuildSpace` separates two questions, because a single threshold
would have to choose between blocking builds that would have succeeded and
permitting ones that cannot:

| Threshold | Default | Behaviour |
|---|---|---|
| Floor — the build cannot finish | `min(diskGB, 50) + 10` = **60 GB** | Refuse |
| Comfortable — a saturated fleet also fits | floor + **116 GB** = **176 GB** | Warn, proceed |

Derivation, biased pessimistic throughout:

- **50 GB install peak.** A Windows 11 ARM64 install lands around 25 GB, plus
  the component store before `/ResetBase`, a pagefile sized to guest RAM, the
  staged toolchain, and sysprep's working set. This was an *estimate*.

  **MEASURED on m3, 2026-09-15: 16.4 GiB**, sampled every 20 s over a full
  install through to the sentinel (`du -sk` of the whole build directory, so
  it includes the 128 MiB firmware pair and the TPM state; the qcow2 itself
  peaked at 16.3 GiB and then *shrank* as Setup trimmed). The estimate is
  pessimistic by 3x, which is the safe direction and is why it is left alone:
  the floor it produces (60 GB) still refuses only builds that genuinely
  cannot fit, and a `/ResetBase`-less component store on a future Windows
  release could close the gap. Anyone tempted to lower it should note this
  figure does not yet include `sysprep /generalize`'s own working set.
- **116 GB fleet peak**, from live scale-set limits and measured instance
  footprints: 2 macOS at ~36 GB, 3 Linux at ~8 GB, 2 Windows overlays at
  ~10 GB.
- The floor scales down with a smaller requested image, since a qcow2 cannot
  outgrow its requested size, and stops scaling up past the install peak,
  since the image stays sparse.

`GOSTI_QEMU_WINDOWS_ARM_MIN_FREE_GB` overrides the floor for an operator who
knows better than the estimate. An undeterminable free figure warns and
proceeds — refusing to build because a `statvfs` call failed would be worse
than the risk it guards.

For calibration: m3 measured 231 GB free with an idle fleet and 156 GB an
hour later with five instances running, which lands in the warn band. Free
space on that host moves by roughly the fleet peak over a day, which is the
reason the second threshold exists at all.

## Prerequisites

`swtpm`, `qemu-system-aarch64`, and `sshpass` come from the Nix-provided
environment. The Windows ARM64 ISO is operator-supplied and validated by
hash, never downloaded by the harness.
