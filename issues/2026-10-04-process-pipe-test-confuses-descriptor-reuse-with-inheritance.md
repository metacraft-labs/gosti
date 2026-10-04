# Process-pipe regression must distinguish reuse from inheritance

| Field | Value |
| --- | --- |
| Status | Open; correction authorized by the current stabilization |
| Observed in | `ab48fefe2f5ab48cb927778165222fc9ae670165`, explicit macOS fork adaptation of the Linux regression |
| Expectation | `docs/serve.md` requires workers not to inherit another launch's pipes; the local release follow-up LOCAL-4 requires meaningful unchanged ownership coverage |

The new regression records parent pipe descriptor numbers, then treats any
open descriptor at those numbers in an executed child as an inherited pipe.
Exec can close every pipe correctly and the child can legitimately reuse those
numbers. Descriptor numbers alone do not identify the pipe being tested.

A real control opens `/dev/null` in each child after exec, before inspection.
The fixed launcher returns promptly and all other three cases pass, but the
ownership case fails for all eight children because their new files occupy the
old numbers. Source and logs are retained under
`/tmp/gosti-pipe-fd-reuse-control`. The unmodified control also passes under the
actual local io-mon monitor; no monitor failure is claimed by this finding.

Fresh refs still identify `agents` and the dated promotion head as `ab48fef`.
Open issues and issue history were searched for pipe, descriptor and reuse.
The existing capability-probe issue concerns a runtime double close; this
finding concerns the new regression's evidence identity.

## Required correction

Record each actual pipe's device and inode with its descriptor, then inspect
that identity in the executed child. Deliberately open real child-owned files
at the freed descriptor numbers, and prove they differ from the original pipes.
Keep all eight overlapping children, parent close-on-exec checks, launch and
cleanup bounds, child exit results and the existing stdio/error cases. Removing
close-on-exec must still expose inherited original pipes and fail the control;
removing identity-dup2 handling must still fail the closed-stdin case.

This corrects a false failure without removing the inherited-pipe requirement.
Repeat the explicit local controls, Linux x64/ARM cross-builds, complete local
qualification and the full platform matrix before promoting the new source.

## Control evidence

At `e4de5ec` plus this correction, all four explicit macOS fork controls pass
while every child deliberately reoccupies the freed descriptor numbers with
real `/dev/null` files. Removing close-on-exec fails the original overlapping
launch case; removing identity-dup2 handling fails the original closed-stdin
case. Each negative control leaves the other three cases passing. The exact
Linux fixture cross-compiles for x64 and ARM64 with Zig 0.15.2 and glibc 2.28;
ELF headers match. Logs are under `/tmp/gosti-pipe-identity-controls` and
`/tmp/gosti-pipe-identity-cross`. Full qualification follows the separate
qualified-import repair recorded alongside this correction.

## Remaining assumption about child startup files

At `f5a68109855007d15f6035559d8d0adb3dab38c2`, the fixture compares original
pipe identities correctly, but its other branch requires every different
object to be one of the `/dev/null` files opened by that specific loop. An
executed child or its loader can have opened another legitimate file earlier.
A real regular-file open before the loop reproduces a false failure in all
eight children at `fd in childFiles`; the other three cases still pass. The
source and logs are retained under `/tmp/gosti-pipe-startup-file-control`.

Permit other objects whose device/inode differs from the original pipe.
Continue to verify the identity of files the null-file loop itself opens.
Include the real earlier startup file in the fixture so this case remains
covered. No inherited original pipe is allowed, and all parent close-on-exec,
concurrency, deadline, child-exit and stdio/error requirements remain. Repeat
the missing-close-on-exec and missing-identity-dup2 controls, complete local
gates and the platform matrix before promoting the corrected source.

Fresh `agents` still points to `f5a6810`; open and historical descriptor issues
were searched. This is a continuation of this fixture-identity defect, not a
new product ownership failure. Its preceding ordinary CI passes all thirteen
checks; the focused real-file control establishes the missing fixture case.

## Startup lifetime controls

At `270f359` plus the fixture correction, each executed child opens one real
startup file and another that it closes before inspection. The original pipe
identity remains forbidden whether its number is closed, reused by these
startup files or reused by the null-file loop. An invalid `fstat` result is
accepted only for `EBADF` on a descriptor that the loop does not own; the
loop's own live files still require their exact `/dev/null` identity.

The four positive cases pass. Removing close-on-exec still fails only the
overlapping launch case; removing identity-dup2 handling still fails only the
closed-stdin case. Restoring the requirement that every number remain open
fails on the legitimately closed startup descriptor, leaving the other three
cases passing. Both exact Linux fixture cross-builds pass with the expected
x64/ARM64 ELF headers. Records are under `/tmp/gosti-pipe-lifecycle-controls`,
`/tmp/gosti-pipe-closed-file-control` and `/tmp/gosti-pipe-lifecycle-cross`.

This changes only fixture evidence handling. The production compatibility
module, child counts, startup bounds and inherited-pipe failure condition are
unchanged. Full local and platform qualification remains required.
