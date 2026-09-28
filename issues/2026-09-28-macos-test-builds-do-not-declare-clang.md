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
