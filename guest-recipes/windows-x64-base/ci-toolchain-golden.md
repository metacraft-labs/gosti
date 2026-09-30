# CI toolchain layer for the Windows x64 golden

`build-ci-toolchain-golden.sh` layers what a Windows CI job expects the
**machine** to provide onto the cloudbase-init golden
(`/storage/iso/golden-win11-cloudbase.qcow2`, see
[`cloudbase-init-golden.md`](cloudbase-init-golden.md)). It replaces the
by-hand re-stages of 2026-08 and 2026-09 (Git, pwsh, the Defender exclusion,
the actions runner, the time zone) with a script whose inputs are pinned in
[`ci-toolchain.pins`](ci-toolchain.pins).

It is the same boot-a-copy / modify / capture-cold procedure as the README's
retrofits and `build-sysprep-golden.sh`, with one addition: the gates run
**twice**, once in the work guest before capture and once on a fresh
copy-on-write clone of the captured image. A clone is what the fleet boots, so
the clone run is the one that counts.

```bash
# On the KVM host (needs sudo, /dev/kvm, qemu-img/qemu-nbd, virsh):
nix shell nixpkgs#sshpass nixpkgs#hivex nixpkgs#ntfs3g -c \
  guest-recipes/windows-x64-base/build-ci-toolchain-golden.sh
# -> /storage/iso/golden-win11-cloudbase-ci-<date>.qcow2  (+ .record.txt)
```

Wall clock on high-mem-server under normal CI load: about 1 to 1.5 h. The VS
Build Tools install is the long leg.

## What goes in, and why it is the machine's job

A job's tools come from a content-addressed store (reprobuild's `repro.nim`
`uses:`) wherever that is possible. The items below are what is left: things
Microsoft does not allow to be redistributed, kernel drivers, and machine-wide
OS settings.

| Item | Layer | Why the image carries it |
| ---- | ----- | ------------------------ |
| VS 2022 Build Tools: `Microsoft.VisualStudio.Workload.VCTools`, `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`, `Microsoft.VisualStudio.Component.Windows11SDK.26100`, plus recommended | **base** | MSVC and the SDK cannot be redistributed, so no store can provide them. Any Windows Rust or C++ project needs them. The set is exactly what agent-harbor's "Install required Visual Studio components" step requests, installed with `--includeRecommended` as that step does, so the step's `vs_installer modify` finds nothing to add. |
| `LongPathsEnabled=1` + Git `core.longpaths=true` (system) | **base** | Deep `node_modules` and Cargo target paths exceed `MAX_PATH`. |
| actions runner at `C:\actions-runner`, version = infra `lib/actions-runner.json` | **base** | GARM's server-rendered Windows bootstrap reuses a staged runner when the directory exists. A stale copy is a runner GitHub rejects. |
| Clock contract (`RealTimeIsUniversal=1`, zone UTC) | **base** | See [Clock](#clock). |
| Antivirus real-time scanning off | **base** | See [Antivirus](#antivirus). |
| Windows Update and Windows Search off | **base** | See [Background services](#background-services). |
| C: grown by `VMH_GROW_DISK_GB` (default +80 GiB) | **base** | Rust target directories are large. Growth only happens if no partition sits after C:. The build log records the outcome. |
| WinFsp (`WINFSP_VERSION`) | **project: agent-harbor. Move to an AH5 starting point.** | A kernel-mode driver, so it cannot come from a store. Only agent-harbor's AgentHarborFS tests need it. It is in the base for now because agent-harbor's workflow has no install step for it and fails loudly without it. |

The base and project split follows AH5 in reprobuild-specs
`Sovereign-CI-Fleet-And-GOSTI-Substrate.milestones.org`. The golden is the
shared base for every org's Windows runners. Anything only one project needs
belongs in that project's starting point, a snapshot over the shared base. To
build a base without WinFsp, drop the WinFsp step once the AH5 starting point
carries it.

**Not** in the image: Rust toolchains and targets, Node, LLVM, just, Python,
nextest and so on. The job's reprobuild dev environment provisions them.

### Why the VS bootstrapper is signature-checked, not digest-pinned

`VS_BUILDTOOLS_URL` is Microsoft's evergreen channel link for VS 2022 (major
17). Its bytes change with every servicing release, so a digest pin would
break every rebuild. Trust comes from its Microsoft Authenticode signature,
which the guest verifies before running it. The bootstrapper's digest and the
installed product version are written to the build record, so every golden
states exactly what it carries. Consumers do not need a specific MSVC patch
level: agent-harbor's `repro.nim` accepts its pinned `WINDOWS_VCTOOLS_VERSION`
or, failing that, the newest installed toolset.

## Clock

The ephemeral libvirt domain (gosti `buildEphemeralDomainXml`) renders the RTC
as `<clock offset='utc'>`, and the golden sets `RealTimeIsUniversal=1` with
zone UTC. The guest clock is then correct whatever the host's zone and the
guest's zone are.

It used to be `offset='localtime'`. hms runs Europe/Sofia, so a UTC-zoned
golden booted 3 h fast and GitHub rejected the runner's OAuth token ("not
valid until ..."). The 2026-09-27 stop-gap set the golden's zone to
`FLE Standard Time`, which is correct only on a Europe/Sofia host.

**Rollout order matters.** `-ClockMode utc` is correct only under
`offset='utc'`, and the old zone-matched golden is correct only under
`offset='localtime'`. So:

1. Deploy a gosti with the `offset='utc'` domain XML to the serve host.
2. Then promote a golden built with `VMH_CLOCK_MODE=utc` (the default).

Until step 1 is deployed, build with `VMH_CLOCK_MODE=keep`, which leaves the
image's clock settings unchanged. Both modes finish with the same check: guest
UTC is compared to host UTC on the verification clone, and the build fails if
they differ by more than 120 s.

## CPU topology

The recipe's work and verification domains use
`<topology sockets='1' dies='1' cores='N' threads='1'/>`, matching gosti's
ephemeral XML and `virt-install --vcpus N,sockets=1,cores=N,threads=1`.
libvirt's default is one socket per vCPU, and Windows 11 Pro uses at most 2
sockets, so a 4-vCPU guest used only 2. The gate asserts
`NumberOfLogicalProcessors == VMH_VCPUS` on both the work VM and the clone.

## Antivirus

`VMH_DISABLE_DEFENDER=1` (the default for this CI recipe) applies the
`defender-off` payload with
[`../lib/apply-offline-service-payloads.sh`](../lib/apply-offline-service-payloads.sh)
to the cold work image before capture. It uses the same registry payload and the
same rationale as the Hyper-V pool's `harden-defender.ps1`
([`../lib/harden-defender.README.md`](../lib/harden-defender.README.md)): a
running guest cannot turn its own real-time scanning off, so the services are
disabled offline.

**The trade-off.** These are single-use VMs: each job gets a fresh clone and
the clone is destroyed afterwards. Nothing a job writes outlives it, and
nothing on the machine belongs to anyone but that job. On-access scanning
therefore protects almost nothing here, while it costs a lot: it taxes every
file a build opens (a Cargo or MSVC build opens tens of thousands), it
quarantines legitimate toolchain binaries (`pwsh.exe` as
`PUA:Win32/PowerShellCore`), and it makes build times noisy.

Exclusions for the work directory are the weaker alternative. The job's
toolchains, caches and temp directories live outside the work directory, and
a list of exclusions is exactly what went stale here before (see the README's
Defender retrofit). What contains pull-request code is the ephemeral
lifecycle and the network isolation, not the scanner. A golden meant for
anything other than ephemeral CI should be built with `VMH_DISABLE_DEFENDER=0`.

## Background services

`VMH_DISABLE_BACKGROUND_SERVICES=1` (the default) applies the
`ci-background-off` payload in the same offline pass. It sets `Start=4` on the
services in [`../lib/ci-background-off.targets`](../lib/ci-background-off.targets)
and sets the `WindowsUpdate\AU NoAutoUpdate=1` policy:

| Service | What it is |
| ------- | ---------- |
| `wuauserv` | Windows Update. It spawns `wuaucltcore` and, through servicing, `TiWorker`. |
| `UsoSvc` | Update Orchestrator. Every `\Microsoft\Windows\UpdateOrchestrator\` scheduled task goes through it. |
| `WaaSMedicSvc` | Windows Update Medic. It re-enables the two above if only they are disabled. |
| `DoSvc` | Delivery Optimization (peer-to-peer update downloads). |
| `WSearch` | Windows Search (`SearchIndexer`). |

**Why.** A clone of this golden runs one job on 4 vCPUs and is then
destroyed. Updates that a clone installs are thrown away with it, and an index
of its files is never queried. Both only compete with the job. On
2026-09-30, one `Rust tests | windows-x64` VM (agent-harbor run 36564749720)
had spent about 2 h in provisioning. Over that time `TiWorker` used 39
CPU-minutes, `wuaucltcore` 20 and `SearchIndexer` 15. The job's own
extraction process used 14.

**Why offline.** `UsoSvc` and `WaaSMedicSvc` refuse `Set-Service` and
`sc config`, even from an elevated administrator. The same offline hive edit
that disables Defender is not subject to those ACLs.

**Scheduled tasks are left alone.** The `UpdateOrchestrator` and
`WindowsUpdate` tasks only start `usoclient` or `wuauserv`, so with the
services disabled they cannot do any work. Several of them refuse changes even
from SYSTEM. The gate lists them for information.

**What stays on.** `TrustedInstaller` (Windows Modules Installer, the owner of
`TiWorker`) stays on demand-start, because `Add-WindowsCapability` and feature
installs in a job need it. Without Windows Update it has nothing to service
in the background.

**The gate.** On the clone, `assert-ci-toolchain.ps1
-ExpectBackgroundServicesOff` requires the following. Every targeted service
exists, is `Disabled` in the SCM with `Start=4` in the registry, and is
`Stopped`. The policy value is set. `wuaucltcore`, `MoUsoCoreWorker` and
`SearchIndexer` are not running.

Security posture: the image is patched at build time and each clone lives for
one job. Patch currency comes from rebuilding the golden from a current
source, not from clones updating themselves. A golden for anything other than
ephemeral CI should be built with `VMH_DISABLE_BACKGROUND_SERVICES=0`.

### Retrofit onto an existing golden

Both payloads are offline edits, so a golden that already carries the
toolchain does not need the multi-hour provisioning pass. Copy it to the work
path and resume the recipe at its offline step. That step applies the
payloads, captures, runs every gate on a fresh CoW clone, and writes the
record:

```bash
sudo qemu-img convert -O qcow2 /storage/iso/golden-win11-cloudbase.qcow2 /storage/scratch/ci-toolchain-work.qcow2
VMH_RESUME_FROM=offline ./build-ci-toolchain-golden.sh
# -> /storage/iso/golden-win11-cloudbase-ci-<date>.qcow2 (+ .record.txt); then Promote
```

## Promote

Promotion is deliberately NOT part of the build. Every step below is a rename
on the same filesystem, so each one is atomic, and rollback is one `mv`.

```bash
cd /storage/iso
NEW=golden-win11-cloudbase-ci-<date>.qcow2
# 1. No domain may still be backed by the live golden when the file is renamed
#    over. Running clones keep their open handle on the old inode and are not
#    affected, but a clone that REBOOTS reopens the path. Check and wait:
sudo virsh list --name | grep '^garm-' || echo "no ephemeral domains"
# 2. Keep the previous golden as a dated backup (a hard link, so it is instant),
#    then swap the new one in with a single rename:
sudo ln golden-win11-cloudbase.qcow2 golden-win11-cloudbase-pre-ci-<date>.qcow2
sudo mv -f "$NEW" golden-win11-cloudbase.qcow2
sudo sha256sum golden-win11-cloudbase.qcow2   # must equal the .record.txt sha256
```

GARM clones every new instance from `golden-win11-cloudbase.qcow2`, so the next
job gets the new image.
