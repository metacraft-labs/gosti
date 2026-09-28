# Linux recipe cannot import the QEMU image tool

| | |
| --- | --- |
| Status | open |
| Recorded | 2026-09-29 |
| Observed in | gosti @ def4272b75f40c039f1d11c2d89c67c46b79b1d4 |
| Area | repro.nim |

Linux ARM64 Reprobuild [job 109123565570](https://github.com/metacraft-labs/gosti/actions/runs/36479991379/job/109123565570)
fails before building: `redefinition of 'qemuImg'; previous declaration here: repro.nim(15, 26)`.
The POSIX import `qemu_img` collides with the Linux-only executable declaration
`qemuImg`; Nim ignores underscores when comparing these names.

The [release specification](../../metacraft-specs/infrastructure/gosti-io-mon-runquota-releases.md)
requires the complete Linux build and test graph. Give the imported module a
distinct alias while keeping the declared executable and its provisioning.

Refreshed dev `850e9de`, verified it is an ancestor, and searched current issues
and deleted-issue history before recording. macOS and Windows x64 CI pass at
`def4272`; neither compiles this Linux-only declaration.
