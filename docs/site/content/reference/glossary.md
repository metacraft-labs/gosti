---
title: Glossary
section: reference
order: 3
slug: glossary
---
# Glossary

This page lists the names Gosti uses, and the names it used before.

## Terms

| Term | Meaning |
| --- | --- |
| Gosti | The VM lifecycle library and the `gosti` command (CLI and serve daemon). |
| Backend | One hypervisor driver behind the common `VmBackend` interface (`tart`, `utm`, `qemu-windows-arm`, `lima`, `libvirt`, `hyperv`, `wsl`, `incus`, `noop`). |
| Baseline | A named guest a backend can revert to before each run. |
| Ephemeral instance | A throwaway clone of a baseline, destroyed after one job. |
| Golden | A guest image built once by a guest recipe and cloned from then on. |
| Guest recipe | A script under `guest-recipes/` that builds a golden. |
| Serve daemon | `gosti serve`, which accepts authenticated remote commands. |

## Former names

Gosti was called vm-harness. Every name below was renamed when the product
was, and none of them is accepted any more: an old command, variable or flag
fails as unknown. A state directory under the old name is moved to the new
one the first time Gosti resolves it.

| Former name | Current name |
| --- | --- |
| vm-harness (product and repository) | Gosti (`metacraft-labs/gosti`) |
| `vm-harness` command, `bin/vm-harness` symlink | `gosti` (no alias is installed) |
| `vm-harness-fixture`, `vm-harness-bench-snapshot-revert` | `gosti-fixture`, `gosti-bench-snapshot-revert` |
| Nim package `vm_harness`, `src/vm_harness/`, `vm_harness.nimble` | `gosti`, `src/gosti/`, `gosti.nimble` |
| `VmHarnessError`, `newVmHarnessError`, other `VmHarness*` / `vmHarness*` identifiers | `GostiError`, `newGostiError`, `Gosti*` / `gosti*` |
| `QwaVmHarnessVersion` | `QwaGostiVersion` |
| environment variables `VMH_<X>` and `VM_HARNESS_<X>` | `GOSTI_<X>` |
| state directories `…/vm-harness/` (`$XDG_STATE_HOME`, `~/.local/state`, `%LOCALAPPDATA%`, `/var/lib`) | `…/gosti/` |
| `share/vm-harness/` | `share/gosti/` |
| Nix package attribute `vm-harness` | `gosti` |
| serve enrollment keyId prefix `vmh1-` | `gosti1-` (same hash suffix) |
| Incus image aliases `vmh-base`, `vmh-linux-runner` (and its `-nested`, `-docker`, `-release` side aliases), `vmh-nixos-runner` | `gosti-base`, `gosti-linux-runner`, `gosti-nixos-runner` |
| Incus build containers `vmh-bld-<alias>` | `gosti-bld-<alias>` |
| libvirt durable-media domains `vmh-media-<id>` | `gosti-media-<id>` |
| guest and host scratch names with the `vmh-` prefix (temp directories, sockets, Windows firewall rule `vmh-sshd-in-tcp22`, guest log markers such as `vmh-git-provision-failed`) | the same names with `gosti-` |
| output markers `VMH:VIRTIO-DRIVERS:*`, `VMH-TPM-*`, `__VMH_RC__` | `GOSTI:VIRTIO-DRIVERS:*`, `GOSTI-TPM-*`, `__GOSTI_RC__` |
| tests `t_vm_harness_*`, `t_vmharness_*` | `t_gosti_*` |
