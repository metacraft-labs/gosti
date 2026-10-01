# macOS test build actions do not declare Clang

Status: open. Recorded 2026-09-28.

At Gosti `fc78d2ca0dc5ef9e6ed03c2f6b7fa43b4ea2898a`, [macOS job 109049684499](https://github.com/metacraft-labs/gosti/actions/runs/36457561906/job/109049684499) passes Reprobuild source setup, then test compilation fails with `clang: command not found`. The recipe attaches GCC only on Linux; the unittest adapter does not automatically declare Nim's C compiler.

[Dependency-Provisioning-In-Build-Graph](../../reprobuild-specs/Dependency-Provisioning-In-Build-Graph.md) requires each action to depend on its consumed tools. Declare the selected host compiler for every test build. Keep Linux's PCRE and uname references and the complete native test catalog.

The current branch already contains dev `850e9de`; searched current issues and deleted-issue history for compiler/tool declarations before recording.

At `442cd78`, the compiler declaration works: macOS Reprobuild job
`109094240913` compiles the catalog. Two execution edges still fail because
`qemu-img` is absent from their isolated PATH: golden-build and dead-guest.
They intentionally manipulate real disk images. Declare the QEMU image tool
for those two POSIX execution edges; do not replace disk operations with mocks.
The diagnostic collector also lacks `find` in the minimized macOS PATH; use
the preserved rooted Python interpreter to collect reports and nonempty logs.
Refreshed dev `850e9de` and searched current/deleted issues before this update.

The complete local macOS Reprobuild graph passes all 56 actions at `6a2ed63`
plus the repaired recipe and polling fixture. The two golden-guest programs
now declare qemu-img, sleep, sha256sum and Git; every original disk, manifest
and deadline assertion remains covered. The diagnostic collector uses rooted
Python on POSIX and retains its Windows shell path. A real temporary-tree
check preserves the report and nonempty action log while excluding empty logs.
Evidence: `/tmp/gosti-final-local-graph.json` and
the passing commit-hook lint at `b58e2d0` (the earlier lint log records a
missing-header failure, corrected before that commit). Native macOS and Linux ARM64 complete tests
already pass at `442cd78`; the final CI graph remains required.


At `b58e2d0`, macOS CI job `109114115647` still fails the two golden tests:
`qemu-img` is absent. The recipe defaults to PATH provisioning, whereas the
successful local graph explicitly selected Nix provisioning. Change the
POSIX default to Nix so a declared tool is realized on a clean runner. Keep
Windows's current PATH provisioning and validate without a CLI provisioning
override. The rooted Python collector now successfully uploads diagnostics.

The no-override macOS run at `b58e2d0` plus this default change passes all
56 actions; `/tmp/gosti-default-provisioning-graph.json` records the complete
graph. Windows keeps the already passing provisioning path.

## CI wrapper overrides the recipe default at `32b9175`

[macOS job 109427556345](https://github.com/metacraft-labs/gosti/actions/runs/36574789846/job/109427556345)
now bootstraps Reprobuild successfully, then both product builds fail on missing
`sys/types.h` and `string.h`. The shared `dev-exec` wrapper at `93de03f`
explicitly adds `--tool-provisioning=path` to bare `repro build` and `repro test`.
That command-line option overrides the recipe's POSIX Nix default, so the
host compiler is selected instead of the declared Nix compiler and SDK closure.
The local no-override test above invoked Reprobuild directly and did not test
this wrapper, which is why it passed.

Pass `--tool-provisioning=nix` explicitly in both POSIX CI commands; keep the
existing Windows PATH mode. This matches io-mon and RunQuota's explicit mode
selection and the documented dependency-provisioning contract. No compile or
test gate is removed. The catalog Clang at canonical nixpkgs `addf7cf5` compiles
and links a real C probe using system and CoreFoundation headers with a clean
environment, confirming it carries its SDK. Refreshed dev `af517b4` and searched
open and deleted compiler/SDK issues before extending this record.

## New disk-size fixtures omit the existing tool declarations

At `52d9140`, the complete native Linux ARM64 catalog passes, but
[Reprobuild job 110446412757](https://github.com/metacraft-labs/gosti/actions/runs/36885118114/job/110446412757)
fails `t_disk_size_honoured` and `t_qemu_windows_arm_disk_size` because their
isolated execution PATH has no `qemu-img`. Both fixtures intentionally use
real qcow2 images. `emitTestPair` attaches the image tool and golden-fixture
utilities only to the two older golden tests; the newly registered disk-size
tests were omitted from that list. The local macOS graph passed with the
development shell's ambient tools, which did not establish the isolated case.

Attach the same declared POSIX tools to these two new execution edges. Preserve
the real image operations and all disk-size assertions. Refreshed `agents` and
`dev`, searched open and archived `qemu-img` records, and extended this existing
dependency-provisioning issue rather than opening a duplicate.
