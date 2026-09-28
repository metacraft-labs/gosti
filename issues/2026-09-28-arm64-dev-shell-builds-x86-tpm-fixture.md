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
selection applies to the libvirt golden guest. On ARM64 the pinned Nixpkgs
cross packages produce these x86 binaries; the tests still boot the real guest
and exchange a real TPM command. Native ARM64 CI evidence is required before
closing this issue.
