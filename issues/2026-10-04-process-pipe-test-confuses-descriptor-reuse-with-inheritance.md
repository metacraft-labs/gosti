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
