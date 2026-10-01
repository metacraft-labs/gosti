# Disk-sizing fixture assumes libvirt operations run on macOS

- Status: open
- Observed: Gosti `295af89249f66b8b05920d2d2febc0cd124412a2`, macOS ARM64

`nix develop --command just test` fails nine cases in
`tests/unit/t_disk_size_honoured.nim`. Both libvirt suites unconditionally
invoke Linux-only backend operations. On macOS each operation raises
`BackendUnavailableError` before the fixture's command stand-ins run.
The sizing, guest-growth, qemu-boot, UTM and Hyper-V suites pass.

The [design's libvirt host contract](../docs/design.md#45-libvirtqemu-hostplatform-hplinux-guests-golinux-gowindows)
specifies a Linux host. [AGENTS.md](../AGENTS.md) requires the deterministic
catalog on the supported hosts. The fixture must respect the host contract:
retain all Linux disk and guest-growth assertions, and verify refusal before
side effects on other POSIX hosts. Do not remove the mixed-backend file from
macOS or alter the backend's production host guard.

Evidence: `/tmp/gosti-agents-local-tests.log`; the nine exceptions originate
in `provisionEphemeralClone`, `provisionBaseline`, `startAndAwaitReady` and
`bootFromMedia`. Fetched current agents `295af89` and searched open issues and
their Git history before filing. The older
`2026-09-28-libvirt-tests-assume-posix-paths-and-executables.md` concerns
different Windows fixtures and assertions.

The test repair needs its own rationale and review under the branching
policy's prohibition on weakening tests during stabilization. Passing the
host's refusal contract is additional coverage; the Linux assertions must
remain intact and be validated on Linux during promotion.
