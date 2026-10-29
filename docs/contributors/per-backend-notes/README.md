# Per-backend implementation notes

Notes on how a particular backend is implemented and measured:

- [`incus.md`](incus.md) — Linux system-container guests on Linux hosts
  (ephemeral per-job containers; the container analog of the libvirt VM
  path): host prerequisites, the CLI command map, cloud-init injection, and
  the Linux runner image.
- [`hyperv-snapshot-benchmarks.md`](hyperv-snapshot-benchmarks.md) — Hyper-V
  checkpoint, restore and clone costs, and the identity-collision finding
  behind the recycle pool.
- [`libvirt-snapshot-benchmarks.md`](libvirt-snapshot-benchmarks.md) —
  libvirt external snapshots: why external rather than internal, and what
  restore costs against a cold boot.

The libvirt backend's operator guide is [`../libvirt.md`](../libvirt.md).
The other backends (Hyper-V, WSL, Tart, UTM, Lima, QEMU Windows-ARM) have no
separate note; their source in `src/gosti/backends/` and
[`../architecture.md`](../architecture.md) are the reference.
