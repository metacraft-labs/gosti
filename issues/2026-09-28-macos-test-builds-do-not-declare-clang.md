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
