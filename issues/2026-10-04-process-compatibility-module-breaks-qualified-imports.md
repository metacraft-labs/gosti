# Linux process compatibility module breaks qualified standard-library imports

| Field | Value |
| --- | --- |
| Status | Open; repair authorized by the current stabilization |
| Observed in | Gosti `ab48fefe2f5ab48cb927778165222fc9ae670165`, Linux x64 Repro CI `37195938345`, job `111417704777` |
| Expectation | `docs/serve.md` requires the compatibility module to preserve the standard process API; the supported Repro CI bootstrap must still compile |

The Linux job fails while building its pinned Repro dependency, before any
Gosti test executes. `ambient_execution.nim(21, 18)` cannot resolve `osproc`
in `osproc.Process`. Nim derives the imported module name from the replacement
file's basename: redirecting `std/osproc` to `atomic_osproc.nim` preserves its
unqualified exports but loses the ordinary `osproc` qualifier. Gosti's own CLI
static checks did not exercise that qualified API. Its root configuration is
also read while compiling the nested `.reprobuild-src` checkout in CI.

The downloaded job log is retained at
`/tmp/gosti-ab48-linux-x64-setup.log`. Its cache timeouts and later S3 mirror
failure are separate; the compiler error is the reason setup fails. The
superseded Repro run is cancelled after capturing its state. Ordinary native
CI results remain evidence for their own source only.

Fresh product refs, open issues and historical issue subjects were searched
before recording this defect. No existing issue covers qualified process API
compatibility.

## Required repair and controls

Keep the replacement module's basename `osproc.nim`. Retain its atomic pipe
constructor, identity-dup2 handling and selected-compiler implementation. The
regression must explicitly compile both `osproc.Process` and
`osproc.startProcess`, in addition to its real process ownership cases. Prove
that the former replacement name fails the qualified API and that the repair
passes on both Linux target architectures. Repeat complete local and platform
qualification before promotion; do not bypass dependency bootstrap or tests.

## Local repair evidence

At `93bbd1e` plus the basename repair, a minimal actual `osproc.Process` and
`osproc.startProcess` program fails with the former replacement path and passes
Linux x64 and ARM64 static checking with the corrected path. The complete CLI
also passes both Linux static checks. The production fixture explicitly uses
both qualified names; its x64 and ARM64 executables cross-build with Zig 0.15.2
and glibc 2.28 and have the expected ELF headers.

All four explicit macOS fork cases pass with the corrected module name and
real descriptor reuse. Removing close-on-exec fails only the overlapping-pipe
case; removing identity-dup2 handling fails only the closed-stdin case. Logs
and sources are retained under `/tmp/gosti-qualified-process-control`,
`/tmp/gosti-pipe-final-controls` and `/tmp/gosti-pipe-api-cross`. The runtime
constructor is unchanged. Full local and platform gates remain mandatory.
