# ARM64 development shell tries to build an x86 TPM fixture

| | |
|---|---|
| Status | open |
| Recorded | 2026-09-28 |
| Observed in | gosti @ `9de39bc` |
| Area | `flake.nix`, `nix/guest-linux-tpm.nix` |

## Observed

Entering the default development shell on native Linux ARM64 fails while
building `guest-linux-tpm`: `cp: cannot stat '...-linux-6.18.26/bzImage'`.
The shell eagerly realises this fixture on every Linux system, but the fixture
and its QEMU test assume an x86 guest; the selected kernel follows the host.

## Expected

`AGENTS.md` describes a five-class development catalog including Linux ARM64,
and `flake.nix` declares its ARM64 shell. Shell entry must succeed there.
`docs/design.md` §4.5 describes the real vTPM guest check; building a different
kernel filename alone does not prove that this x86 guest test works on ARM64.

## Evidence

[Native ARM64 release job at 9de39bc](https://github.com/metacraft-labs/gosti/actions/runs/36377390197/job/108786794124).
Refreshed `origin/dev` (`5661fc1`) and `origin/agents` (`e28afa2`), and searched
open issues and their history for `bzImage` and `ARM64`. No prior record exists.

## Release scope

The release uses a dedicated pinned compiler/packaging shell, since packaging
the CLI does not require a host hypervisor or a guest boot. The default shell
and native ARM64 guest-test support still need a separate repair and real
guest execution evidence.

## Repair under validation

The repair keeps QEMU and archive tools native to the host, and selects explicit
x86 guest packages for the kernel, static BusyBox and OVMF firmware. The same
selection applies to the libvirt golden guest. The pinned Nixpkgs x86 Linux
outputs supply these guest binaries; the tests still boot the real guest
and exchange a real TPM command. Native ARM64 CI evidence is required before
closing this issue.

## Guest artifact selection

The ARM64 jobs at `fc78d2c` spend nearly two hours realizing the cross compiler,
kernel and firmware before the CLI/test steps can proceed. The fixture only
copies these x86 guest payloads; it does not execute their tools on the host.
All three native x86 outputs from the same pinned Nixpkgs revision are present
in `cache.nixos.org` (verified with `nix path-info --store`): kernel 6.18.26,
static BusyBox 1.37.0 and OVMF 202602. Select
`inputs.nixpkgs.legacyPackages.x86_64-linux` for those payloads and retain the
host's native packing tools and QEMU. Full real-guest validation remains required.

At `956cbf3` plus this selection change, the x64 guest derivation is unchanged.
A Linux ARM64 shell dry run needs five local derivations and fetches the
compiler-independent guest artifacts instead of rebuilding them.
