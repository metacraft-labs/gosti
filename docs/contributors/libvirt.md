# libvirt + QEMU/KVM backend (Linux host)

The libvirt backend lets a Linux host manage Windows or Linux guests
through the same `VmBackend` contract every other backend implements. Its
reference deployment is a single libvirt-managed Win11 24H2 Pro guest
running a self-hosted GitHub Actions runner (`windows-runner-001` in the
examples below).

The implementation lives at
[`src/vm_harness/backends/libvirt.nim`](../../src/vm_harness/backends/libvirt.nim);
the consumer-facing recipe at
[`guest-recipes/windows-x64-base/`](../../guest-recipes/windows-x64-base/).

## What the backend implements

| Surface | Status | Notes |
|---|---|---|
| `probeAvailability` | implemented | Returns true when `virsh --version` AND `virsh list` against `qemu:///system` both succeed. |
| `provisionBaseline` (ISO + autounattend) | implemented | Shells out to `virt-install` with q35/UEFI/SMM + virtio-blk + virtio-net + virtio-win driver injection. Idempotent when the domain already exists. |
| `provisionBaseline` (`.qcow2` import) | implemented | A `.qcow2` `sourceImage` is imported as a CoW overlay (`qemu-img create -b`) instead of running Windows Setup. Needs `virt-install` on `PATH`. |
| `revertToBaseline` | implemented (long-lived domain only) | Starts the named domain, polls `virsh domifaddr` for an IP, returns a `VmHandle`. Does NOT itself do per-gate snapshot revert; `restoreSnapshot` is the primitive for that. |
| `startAndAwaitReady` | implemented | Polls SSH `hostname` until the guest accepts logins. |
| `execInGuest` | implemented | SSH via Windows OpenSSH; argv quoted for cmd.exe; env propagated via `set KEY=VAL && ...`. |
| `copyToGuest` / `copyFromGuest` | implemented | scp with `sshpass -e` (password never on argv). |
| `bootFromMedia` (qcow2/ISO) | implemented | Transient `virt-install --import` (qcow2) or `--cdrom` (ISO); domain name must start with `repro-test-boot-libvirt-` for the safety sweep. |
| `stopAndCleanup` | implemented | ACPI `virsh shutdown` then fall back to `destroy`; optional `undefine --remove-all-storage`. Never raises (finally-safe). |
| `snapshot` / `snapshotRunning` / `restoreSnapshot` / `listSnapshots` / `removeSnapshot` | implemented | EXTERNAL `virsh snapshot-create-as` (`--live` + an external memspec for the hot form) and `snapshot-revert --running`. See [`per-backend-notes/libvirt-snapshot-benchmarks.md`](per-backend-notes/libvirt-snapshot-benchmarks.md) for why external rather than internal, and for what is measured vs not. |
| `captureSerial` / `expectLine` | implemented (Linux host) | Poll the file-backed serial log the domain is created with. Available for ephemeral clones and `bootFromMedia` guests, not for long-lived baseline domains. |
| `serialSend` | not implemented | Raises: a file-backed serial log cannot carry input. |
| `installArgvTraceShim` | not implemented | Raises `BackendUnavailableError`. |
| `exportBaseline` / `importBaseline` | not implemented | Raise `BackendUnavailableError`; this backend implements the in-place snapshot/restore surface only. |
| GPU / SR-IOV / USB passthrough | not implemented | No device-passthrough wiring exists in the backend. |

Every unimplemented method raises `BackendUnavailableError` with a
message naming what is missing, so callers discover the gap loudly
instead of seeing a silent no-op.

## The reference flow

The narrow, load-bearing use case is:

1. An operator runs `vm-harness provision` on a Linux host with KVM +
   libvirtd.
2. The harness invokes `virt-install` against the Win11 ISO + the
   autounattend ISO + the virtio-win driver ISO and waits for the
   guest to finish installing.
3. The autounattend's FirstLogonCommands install OpenSSH, the
   virtio-win guest tools, and stage + run the operator-supplied
   first-boot.ps1 (which installs the GitHub Actions runner agent,
   registers with the org, and starts the service).
4. The harness marks the domain `virsh autostart` so the runner
   survives a host reboot.
5. `vm-harness run --backend libvirt --baseline windows-runner-001 --
   <cmd>` against the running domain executes `<cmd>` over SSH and
   harvests output the same way every other backend does.

Steps 1-4 are what `LibvirtBackend.provisionBaseline` does; step 5
is `revertToBaseline + execInGuest + copyFromGuest`.

## Operator command examples

### Provision the windows-runner-001 baseline

```bash
# On any host with libvirtd + KVM:
vm-harness provision \
    --backend libvirt \
    --recipe windows-x64-base \
    --name windows-runner-001 \
    --vcpu 4 --memory-gb 8 --disk-gb 80 \
    --network-bridge virbr0 \
    --first-boot-script ./bootstrap-windows-runner-001.ps1
```

Wall-clock: 25-50 minutes on first run (mostly Win11 Setup).

Before it launches `virt-install`, `provisionBaseline` validates that the
Windows install ISO carries a UEFI (EFI) El Torito boot record
(`LibvirtBackend.validateWindowsIsoBootable`, via `xorriso`). A BIOS-only
ISO can't boot the UEFI q35 domain — OVMF drops to the UEFI shell and
`--wait` would stall ~90 minutes — so the CLI fails fast with guidance to
supply a UEFI-bootable Win11 ISO. This protects the one-command flow above
even when the operator skipped the recipe's `fetch-iso.sh` prep (which runs
the identical check). Missing `xorriso` ⇒ the check is skipped with a
warning, never a hard failure.

When the host's storage lives outside the default libvirt image pool
(`/var/lib/libvirt/images`) — e.g. a large ZFS pool mounted at
`/storage` — add `--image-pool-dir /storage/libvirt`; the domain's
qcow2 then lands at `/storage/libvirt/<name>.qcow2` instead. Omit it to
keep the default byte-for-byte. This threads through
`BaselineSpec.imagePoolDir` into `LibvirtBackend.imagePoolDir` and is
honoured by both the ISO-install and the `.qcow2`-import provision
paths.

The flags `--recipe`, `--name`, `--vcpu`, `--memory-gb`,
`--network-bridge`, and `--first-boot-script` are the canonical
libvirt surface — `parseCliOpts` resolves them at parse time
(see `src/vm_harness/cli.nim`) and threads them through into
`BaselineSpec.recipeDir / firstBootScript / networkBridge`. The
`LibvirtBackend.provisionBaseline` method then invokes the recipe's
`build-autounattend-iso.sh --first-boot-script <path>` before
`virt-install`, so a single invocation produces the per-VM
autounattend ISO and starts the install in one step.

Aliases preserved for compatibility with the historical vm-harness
surface: `--vcpu` ≡ `--cpus`, `--memory-gb` ≡ `--memory-mb` (× 1024),
`--name` ≡ `--baseline` (must agree if both are passed).

### Run a one-shot command in the guest

```bash
vm-harness run \
    --backend libvirt \
    --baseline windows-runner-001 \
    --output-dir /tmp/vmh-run-$(date +%s) \
    -- powershell.exe -NoProfile -Command "Get-Service actions.runner.*"
```

### Probe what's available on this host

```bash
vm-harness probe
# Expected on a libvirt host:
#   {"id":"libvirt","available":true,"host":"linux", ...}
```

### Manual virsh — same operations as the harness

```bash
virsh --connect qemu:///system list --all
virsh --connect qemu:///system domifaddr windows-runner-001
virsh --connect qemu:///system shutdown windows-runner-001
```

## Known issues and rough edges

1. **`virsh domifaddr` against the DHCP lease table can race with the
   guest's first DHCP lease renewal.** The harness retries for
   `sshReadyTimeoutSec` (default 300s) which is plenty for a normal
   boot, but if the lease times out exactly during the poll window
   you'll see a transient "no IP" error. Re-running the gate is
   safe.
2. **The virtio-win driver path baked into autounattend.xml assumes
   the operator did not reorder the sata CD attach order.** The
   recipe attaches Win11 ISO -> virtio-win.iso -> autounattend.iso,
   which gives `D:` to virtio-win under WindowsPE. Changing the
   bus/order in `buildVirtInstallArgs` requires updating
   `<DriverPaths>` in `autounattend.xml` to match.
3. **No serial capture on long-lived baseline domains.** Operators
   debugging a stuck install must use `virt-viewer` / VNC on
   `127.0.0.1:5900` (or whatever `--graphics vnc,listen=...` opened).
4. **`installArgvTraceShim` raises immediately**, so argv-trace gates
   cannot run against the libvirt backend; use `HyperVBackend` on a
   Windows host for those.

## Related files

- [`src/vm_harness/backends/libvirt.nim`](../../src/vm_harness/backends/libvirt.nim) — the backend implementation.
- [`tests/integration/t_libvirt_backend.nim`](../../tests/integration/t_libvirt_backend.nim) — no-live-virsh smoke test.
- [`guest-recipes/windows-x64-base/`](../../guest-recipes/windows-x64-base/) — the autounattend + helper scripts that produce the Win11 x64 baseline.
