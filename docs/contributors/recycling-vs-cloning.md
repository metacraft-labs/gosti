# Recycling vs cloning, per backend

An ephemeral-runner pool needs two different operations, and they are
routinely conflated:

- **Clone** — add a member. Changes pool CAPACITY. Rare, and nobody is
  waiting on it.
- **Recycle** — return a member to its baseline between jobs. Constant, and
  it is what determines both per-job latency and the isolation guarantee.

Which of the two is cheap is **not a property of the design, it is a
property of the backend's storage**. The answer differs per backend, so the
right pool architecture differs per backend too. This page records what was
measured or read, and what follows from it.

## Hyper-V — measured 2026-08-21 on win-ci-bare-001

Numbers and method in
[`per-backend-notes/hyperv-snapshot-benchmarks.md`](per-backend-notes/hyperv-snapshot-benchmarks.md).

| operation | cost |
| --------- | ---- |
| clone (`Export-VM` + `Import-VM`) | ~50 s |
| recycle (`Restore-VMCheckpoint` + resume) | 7-14 s |
| cold boot, for comparison | 36 s |

Cloning is a real file copy, so clone-per-job (35.9 s) is no better than
just cold-booting. Recycling restores a checkpoint that carries RAM, so a
member resumes in ~5 s instead of booting in 36 s.

**Verdict: warm pool.** N members, each hot-checkpointed with its OWN
identity, recycled after each job.

## libvirt / QEMU — the premise INVERTS

The Hyper-V conclusion does not transfer, and assuming it would be a
mistake.

**Cloning is already cheap here.** `provisionEphemeralClone` (in
`src/vm_harness/backends/libvirt.nim`) creates the per-job disk with

```
qemu-img create -f qcow2 -b <golden> -F qcow2 <overlay>
```

a copy-on-write overlay over the golden — O(1), no bytes copied. There is
no `Import-VM` equivalent to dominate the cost. So the thing that made
clone-per-job unattractive on Hyper-V simply does not exist here, and the
libvirt ephemeral path (a fresh CoW overlay per job) is already the right
shape for capacity.

**Recycling exists.** `snapshot`, `snapshotRunning`, `restoreSnapshot`,
`listSnapshots` and `removeSnapshot` are implemented as EXTERNAL `virsh`
snapshots; `exportBaseline` / `importBaseline` are not implemented.
`snapshotRunning` wraps `virsh snapshot-create-as --live` with an external
memspec, which is what captures RAM — and `--live` is *only* legal for
external snapshots, so an internal one would have quietly given up the
resume.

Two storage properties were measured on `high-mem-server` against real
libvirt 11.7 and both favour recycling:

- **A restore does not rewrite the saved state.** Consecutive restores left
  the frozen disk and the memory image byte-identical, mtime unchanged. So
  "prepare the warm state once, restore it many times" is the cheap
  direction.
- **One restore writes one disposable overlay**, then reads the memory
  image. Unlike Hyper-V, where recycle cost scales with how much the job
  wrote (6.67 s clean vs 13.59 s after a write-heavy job), the write side
  here does not scale with the guest.

**But it is not fast.** Measured 2026-09-05 against the 16 GiB Windows
golden: restore + resume → SSH-ready p50 35.9–46.9 s, against a cold boot of
p50 59.0–73.7 s — 1.26–1.57x, where the bar was p50 ≤ 10 s AND ≥ 4x. 96% of
the cycle is `snapshot-revert --running` re-reading the 2.61 GiB memory
image at ~81 MB/s; resume → SSH-ready is 1.7 s.

**Verdict: clone.** `defaultAlgorithmFor(biLibvirt)` is `clone-per-task`:
recycling is modestly faster but not by enough to pay for a member that
carries state across jobs. Numbers, host conditions and method are in
[`per-backend-notes/libvirt-snapshot-benchmarks.md`](per-backend-notes/libvirt-snapshot-benchmarks.md).

## incus — the answer depends entirely on the storage driver

Like libvirt, incus **has** the primitives: `snapshot`,
`snapshotRunning`, `restoreSnapshot`, `listSnapshots` and `removeSnapshot`
are all implemented (`src/vm_harness/backends/incus.nim`), wrapping
`incus snapshot create` / `incus snapshot restore`.

Two things qualify that, and the second is the important one.

**1. Recycling a container is not the same optimisation.** `snapshotRunning`
deliberately takes a *filesystem* snapshot rather than a CRIU stateful one,
noting that this "is what the per-gate reset model wants" — correct, because
a container has no boot to skip. A container starts in about a second, so
there is no 36 s -> 5 s prize here. **For containers, recycling buys
isolation, not speed.**

**2. The default storage pool is `dir`.** [`per-backend-notes/incus.md`](per-backend-notes/incus.md)
declares `driver = "dir"`, i.e. `incus admin init --minimal`'s default. On
the `dir` driver an instance is a plain directory tree, so
`incus snapshot create` and `incus snapshot restore` are **full recursive
copies**, not metadata operations. Cost scales with the size of the
instance's filesystem.

That is the crux:

> **On `dir`, restore-to-baseline may be a pessimisation** — copying a
> whole rootfs back can cost more than deleting the instance and launching
> a fresh one from the image, which incus already does cheaply.
>
> **On ZFS (or btrfs), the same two commands become O(1)** — a snapshot is
> a ZFS snapshot and a restore is a `zfs rollback`, both metadata-only and
> independent of instance size. `incus copy` also becomes a `zfs clone`,
> making capacity changes near-free as well.

So the storage driver is not a tuning detail for incus; it decides whether
the recycle model is worth using there at all. The incus backend takes a
named storage pool (`IncusBackend.storagePool`, default `default`) but does
not choose or detect its driver, and the pool algorithm does not consult it.

**Verdict: undecided, defaulted to clone.** `defaultAlgorithmFor(biIncus)` is
`clone-per-task`. A selection needs `incus snapshot restore` measured on both
drivers — and the comparison to beat is "delete and relaunch", not "cold
boot".

## Summary

| backend | clone (capacity) | recycle (per job) | selected |
| ------- | ---------------- | ----------------- | -------- |
| Hyper-V | ~50 s, real copy | **7-14 s, carries RAM** | warm pool + recycle (measured) |
| libvirt | **O(1) CoW overlay** + boot, p50 59–74 s | implemented, p50 36–47 s | clone-per-task (measured: recycling is 1.26–1.57x faster, short of the 4x bar) |
| incus | `incus copy` | implemented, cost = f(driver) | clone-per-task (default; **`dir` makes restore a full copy, ZFS makes it O(1)**) |

The general rule, stated once: **recycle when restoring is cheaper than
creating, clone when it is not** — by enough to pay for the state a recycled
member carries. Hyper-V sits clearly on one side of that line; libvirt has a
restore that is cheaper but not cheap enough; incus depends on its storage
driver.
